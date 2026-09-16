using System.ComponentModel;
using MacMaui.ClientLogic;
using MacMaui.Mobile.Services;

namespace MacMaui.Mobile;

public partial class MainPage : ContentPage
{
	private readonly WeatherViewModel _viewModel;
	private readonly AppUpdateService _updates;

	public MainPage(WeatherViewModel viewModel, AppUpdateService updates)
	{
		InitializeComponent();

		_viewModel = viewModel;
		_updates = updates;
		BindingContext = viewModel;

		// Keep the screen reader in step with the status line the view model publishes.
		_viewModel.PropertyChanged += OnViewModelPropertyChanged;
	}

	protected override async void OnAppearing()
	{
		base.OnAppearing();

		// Windows only, and only for an installed copy. Everywhere else this returns null and
		// costs nothing. Failures are swallowed inside the service: not being able to reach
		// GitHub is no reason to interrupt someone who just wants the weather.
		var available = await _updates.CheckForUpdateAsync();
		if (available is null)
		{
			return;
		}

		var install = await DisplayAlertAsync(
			"Update available",
			$"Version {available} is ready to install. The app will restart.",
			"Update now",
			"Later");

		if (install)
		{
			await _updates.DownloadAndRestartAsync();
		}
	}

	private void OnViewModelPropertyChanged(object? sender, PropertyChangedEventArgs e)
	{
		if (e.PropertyName == nameof(WeatherViewModel.Status))
		{
			SemanticScreenReader.Announce(_viewModel.Status);
		}
	}
}
