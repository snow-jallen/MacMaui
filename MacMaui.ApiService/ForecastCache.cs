namespace MacMaui.ApiService;

/// <summary>
/// Holds the forecast steady for a short window so repeated calls agree with each other.
///
/// The rule worth stating precisely: the window opens when a forecast is first generated and
/// closes <see cref="Lifetime"/> later, regardless of what happens in between. Asking for more
/// days than are cached appends the missing ones and leaves the days already cached alone, so a
/// client that asks for ten days and then fifteen sees its original ten unchanged. Crucially,
/// those extra days do not restart the clock: everything still expires together, on the
/// original deadline. Without that, a client polling for one more day each time would hold the
/// forecast frozen forever.
/// </summary>
public sealed class ForecastCache(TimeProvider timeProvider)
{
    /// <summary>How long a generated forecast stays valid.</summary>
    public static readonly TimeSpan Lifetime = TimeSpan.FromSeconds(10);

    private static readonly string[] Summaries =
    [
        "Freezing", "Bracing", "Chilly", "Cool", "Mild",
        "Warm", "Balmy", "Hot", "Sweltering", "Scorching"
    ];

    // One lock guards both fields; they only make sense read together.
    private readonly Lock _gate = new();
    private readonly List<WeatherForecast> _forecasts = [];
    private DateTimeOffset _expiresAt = DateTimeOffset.MinValue;

    /// <summary>
    /// The next <paramref name="days"/> days of forecast, generating only what is missing.
    /// </summary>
    public IReadOnlyList<WeatherForecast> GetForecast(int days)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(days, 1);

        var now = timeProvider.GetUtcNow();

        lock (_gate)
        {
            if (now >= _expiresAt)
            {
                // The window has closed, so this request opens a new one.
                _forecasts.Clear();
                _expiresAt = now + Lifetime;
            }

            // Extend, never rebuild: days already handed out must keep their values. Note this
            // does not touch _expiresAt, which is what keeps the deadline tied to the first
            // request rather than the most recent one.
            var firstDate = DateOnly.FromDateTime(now.UtcDateTime.Date);
            while (_forecasts.Count < days)
            {
                _forecasts.Add(new WeatherForecast(
                    firstDate.AddDays(_forecasts.Count + 1),
                    Random.Shared.Next(-20, 55),
                    Summaries[Random.Shared.Next(Summaries.Length)]));
            }

            // A copy, so a caller cannot observe the list growing underneath it.
            return _forecasts.Take(days).ToArray();
        }
    }
}
