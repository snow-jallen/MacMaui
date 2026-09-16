using System.Globalization;
using System.Net.Http.Json;

namespace MacMaui.ClientLogic;

/// <summary>
/// Abstraction over the weather endpoint so view models can be unit tested with a
/// substitute instead of a real HttpClient.
/// </summary>
public interface IWeatherApiClient
{
	/// <summary>
	/// Asks the API for <paramref name="days"/> days of forecast. The server decides what to
	/// return and caches it briefly, so two calls a few seconds apart give the same answer.
	/// </summary>
	Task<WeatherForecast[]> GetWeatherAsync(int days = DefaultDays, CancellationToken cancellationToken = default);

	/// <summary>Days requested when the caller does not say.</summary>
	const int DefaultDays = 5;

	/// <summary>Matches the API's own limit, so the UI can stop out-of-range values early.</summary>
	const int MaxDays = 90;
}

public class WeatherApiClient(HttpClient httpClient) : IWeatherApiClient
{
	public async Task<WeatherForecast[]> GetWeatherAsync(
		int days = IWeatherApiClient.DefaultDays,
		CancellationToken cancellationToken = default)
	{
		ArgumentOutOfRangeException.ThrowIfLessThan(days, 1);

		// The count is the server's business now: it caches whole days and hands back exactly
		// what was asked for, so there is nothing left to trim on this side.
		var url = "/weatherforecast?days=" + days.ToString(CultureInfo.InvariantCulture);
		var forecasts = await httpClient.GetFromJsonAsync<WeatherForecast[]>(url, cancellationToken);

		return forecasts ?? [];
	}
}

public record WeatherForecast(DateOnly Date, int TemperatureC, string? Summary)
{
	public int TemperatureF => 32 + (int)(TemperatureC / 0.5556);
}
