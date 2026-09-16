using System.Reflection;
using Microsoft.Extensions.Logging;
#if WINDOWS
using Velopack;
using Velopack.Sources;
#endif

namespace MacMaui.Mobile.Services;

/// <summary>
/// Desktop auto-update, backed by Velopack on Windows and a no-op everywhere else.
///
/// .NET MAUI has nothing like ClickOnce, so an unpackaged Windows build cannot update itself.
/// Velopack fills that gap: the release pipeline publishes an installer and update packages to
/// the project's GitHub releases, and this checks that feed. iOS updates through TestFlight and
/// Android through a new APK, so neither needs any of this.
///
/// The Velopack types only exist in the Windows build, so they stay behind #if WINDOWS and the
/// surface here is deliberately plain: a version string rather than a Velopack type, so shared
/// code and the other platforms never see the dependency.
/// </summary>
public sealed class AppUpdateService(ILogger<AppUpdateService> logger)
{
    /// <summary>
    /// How often the app looks for a new version while it is running.
    ///
    /// Six hours is deliberately unhurried. Velopack reads the feed through the GitHub releases
    /// API, which allows 60 requests an hour per IP address to anonymous callers. A classroom
    /// shares one address, so a class of thirty checking every fifteen minutes would be 120
    /// requests an hour and updates would start failing for everyone. At this interval a full
    /// class uses a small fraction of the budget.
    /// </summary>
    public static readonly TimeSpan CheckInterval = TimeSpan.FromHours(6);

#if WINDOWS
    private UpdateManager? _manager;
    private UpdateInfo? _pending;
    private int _watching;
#endif

    /// <summary>True when this build can update itself in place.</summary>
    public bool IsSupported =>
#if WINDOWS
        true;
#else
        false;
#endif

    /// <summary>
    /// The version waiting to be installed, or null when the app is current, cannot update, or
    /// the check failed. A failed check is deliberately not an error: an app that cannot reach
    /// GitHub should still start and work.
    /// </summary>
    public async Task<string?> CheckForUpdateAsync(CancellationToken cancellationToken = default)
    {
#if WINDOWS
        var feedUrl = typeof(AppUpdateService).Assembly
            .GetCustomAttributes<AssemblyMetadataAttribute>()
            .FirstOrDefault(a => a.Key == "UpdateFeedUrl")?.Value;

        if (string.IsNullOrWhiteSpace(feedUrl))
        {
            logger.LogDebug("No UpdateFeedUrl was baked into this build; updates are disabled.");
            return null;
        }

        try
        {
            _manager ??= new UpdateManager(new GithubSource(feedUrl, accessToken: null, prerelease: false));

            // False when running from the build output rather than an installed copy, which is
            // the normal case during development.
            if (!_manager.IsInstalled)
            {
                logger.LogDebug("Not an installed build, so there is nothing to update.");
                return null;
            }

            _pending = await _manager.CheckForUpdatesAsync().WaitAsync(cancellationToken);
            var version = _pending?.TargetFullRelease.Version.ToString();
            logger.LogInformation("Update check complete. Available version: {Version}",
                version ?? "none, already current");
            return version;
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            logger.LogWarning(ex, "Checking for updates failed; carrying on with this version.");
            return null;
        }
#else
        await Task.CompletedTask;
        return null;
#endif
    }

    /// <summary>
    /// Checks for a new version every <see cref="CheckInterval"/> until cancelled, calling
    /// <paramref name="onUpdateAvailable"/> with the version whenever one appears. Safe to call
    /// more than once; only the first call starts a loop.
    /// </summary>
    public Task WatchForUpdatesAsync(
        Func<string, Task> onUpdateAvailable, CancellationToken cancellationToken = default)
    {
#if WINDOWS
        if (Interlocked.Exchange(ref _watching, 1) == 1)
        {
            return Task.CompletedTask;
        }

        return Task.Run(async () =>
        {
            // Spread clients out. Without this every copy started by a lab login script would
            // hit the feed in the same second, which is exactly the burst the rate limit
            // punishes. Up to ten minutes is small against a six hour period and plenty to
            // break up the convoy.
            var jitter = TimeSpan.FromSeconds(Random.Shared.Next(0, 600));
            using var timer = new PeriodicTimer(CheckInterval + jitter);

            while (await timer.WaitForNextTickAsync(cancellationToken))
            {
                var available = await CheckForUpdateAsync(cancellationToken);
                if (available is not null)
                {
                    await onUpdateAvailable(available);
                }
            }
        }, cancellationToken);
#else
        _ = onUpdateAvailable;
        _ = cancellationToken;
        return Task.CompletedTask;
#endif
    }

    /// <summary>
    /// Downloads the update found by <see cref="CheckForUpdateAsync"/> and restarts into it.
    /// Returns false if the download failed, leaving the running version untouched.
    /// </summary>
    public async Task<bool> DownloadAndRestartAsync(CancellationToken cancellationToken = default)
    {
#if WINDOWS
        if (_manager is null || _pending is null)
        {
            return false;
        }

        try
        {
            await _manager.DownloadUpdatesAsync(_pending).WaitAsync(cancellationToken);
            logger.LogInformation("Update downloaded; restarting into {Version}.",
                _pending.TargetFullRelease.Version);

            // Does not return: it hands off to the Velopack helper and ends this process.
            _manager.ApplyUpdatesAndRestart(_pending);
            return true;
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            logger.LogWarning(ex, "Downloading the update failed; staying on this version.");
            return false;
        }
#else
        await Task.CompletedTask;
        return false;
#endif
    }
}
