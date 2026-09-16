using System.ComponentModel;
using MacMaui.ClientLogic;
using MacMaui.Mobile.Services;

namespace MacMaui.Mobile;

public partial class MainPage : ContentPage
{
	private readonly WeatherViewModel _viewModel;
	private readonly AppUpdateService _updates;
	private bool _startedWatching;

	public MainPage(WeatherViewModel viewModel, AppUpdateService updates)
	{
		InitializeComponent();

		_viewModel = viewModel;
		_updates = updates;
		BindingContext = viewModel;

		// Only the desktop build can replace itself; the other platforms update through their
		// stores, so the button would be a dead end there.
		CheckUpdatesButton.IsVisible = updates.IsSupported;

		// Keep the screen reader in step with the status line the view model publishes.
		_viewModel.PropertyChanged += OnViewModelPropertyChanged;
	}

	protected override async void OnAppearing()
	{
		base.OnAppearing();

		if (!_updates.IsSupported || _startedWatching)
		{
			return;
		}

		_startedWatching = true;

		// Once at startup, then every few hours in the background. Failures are swallowed inside
		// the service: not being able to reach GitHub is no reason to interrupt someone who just
		// wants the weather.
		_ = _updates.WatchForUpdatesAsync(OfferUpdateAsync);

		var available = await _updates.CheckForUpdateAsync();
		if (available is not null)
		{
			await OfferUpdateAsync(available);
		}
	}

	private async void OnCheckUpdatesClicked(object? sender, EventArgs e)
	{
		CheckUpdatesButton.IsEnabled = false;
		try
		{
			var available = await _updates.CheckForUpdateAsync();
			if (available is null)
			{
				// Unlike the background check, an explicit ask deserves an answer either way.
				await DisplayAlertAsync("No update", "This is the latest version.", "OK");
				return;
			}

			await OfferUpdateAsync(available);
		}
		finally
		{
			CheckUpdatesButton.IsEnabled = true;
		}
	}

	private async Task OfferUpdateAsync(string version)
	{
		// The background watcher runs off the UI thread, so hop back before touching the page.
		await MainThread.InvokeOnMainThreadAsync(async () =>
		{
			var install = await DisplayAlertAsync(
				"Update available",
				$"Version {version} is ready to install. The app will restart.",
				"Update now",
				"Later");

			if (install)
			{
				await _updates.DownloadAndRestartAsync();
			}
		});
	}

	private void OnViewModelPropertyChanged(object? sender, PropertyChangedEventArgs e)
	{
		if (e.PropertyName == nameof(WeatherViewModel.Status))
		{
			SemanticScreenReader.Announce(_viewModel.Status);
		}
	}
}
