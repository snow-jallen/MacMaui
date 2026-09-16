using System.Collections.ObjectModel;
using System.Diagnostics;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace MacMaui.ClientLogic;

/// <summary>
/// Drives the weather page. Deliberately free of any MAUI types so it can be exercised
/// directly from tests with a substituted <see cref="IWeatherApiClient"/>.
/// </summary>
public partial class WeatherViewModel(IWeatherApiClient weatherApi, Telemetry telemetry) : ObservableObject
{
	[ObservableProperty]
	public partial string Status { get; set; } = "Press the button to call the API.";

	[ObservableProperty]
	public partial bool IsBusy { get; set; }

	/// <summary>
	/// How many days of forecast to ask for. The API caches whole days for a few seconds, so
	/// raising this shortly after a request adds the extra days and leaves the earlier ones
	/// alone; the page will look like it grew rather than changed.
	/// </summary>
	[ObservableProperty]
	public partial int Days { get; set; } = IWeatherApiClient.DefaultDays;

	public ObservableCollection<WeatherForecast> Forecasts { get; } = [];

	[RelayCommand]
	private async Task LoadWeatherAsync(CancellationToken cancellationToken)
	{
		// Parent of the outgoing HTTP span, so the dashboard shows the mobile app and the
		// API service as a single distributed trace.
		using var activity = telemetry.ActivitySource.StartActivity("GetWeather", ActivityKind.Client);

		// Captured before the call, not after it. Set inside the success branch this would be
		// missing from exactly the traces worth investigating, and the day count is the first
		// thing you would ask about a request that failed or was slow.
		var days = Days;
		var daysTag = new KeyValuePair<string, object?>("days", days);
		activity?.SetTag("weather.days_requested", days);

		IsBusy = true;
		Status = $"Asking apiservice for {days} days...";
		Forecasts.Clear();

		var stopwatch = Stopwatch.StartNew();
		try
		{
			var forecasts = await weatherApi.GetWeatherAsync(days, cancellationToken);

			foreach (var forecast in forecasts)
			{
				Forecasts.Add(forecast);
			}

			activity?.SetTag("weather.forecast_count", forecasts.Length);
			telemetry.WeatherRequests.Add(1, daysTag,
				new KeyValuePair<string, object?>("outcome", "success"));

			Status = $"{forecasts.Length} forecasts at {DateTime.Now:T}";
		}
		catch (Exception ex)
		{
			activity?.SetStatus(ActivityStatusCode.Error, ex.Message);
			activity?.SetTag("error.type", ex.GetType().FullName);
			telemetry.WeatherRequests.Add(1, daysTag,
				new KeyValuePair<string, object?>("outcome", "failure"));

			Status = $"Request failed: {ex.Message}";
		}
		finally
		{
			stopwatch.Stop();
			// Tagged so latency can be read against request size. Cardinality is bounded by the
			// stepper's range, so this stays a handful of series rather than one per value seen.
			telemetry.WeatherRequestDuration.Record(stopwatch.Elapsed.TotalMilliseconds, daysTag);
			IsBusy = false;
		}
	}
}
