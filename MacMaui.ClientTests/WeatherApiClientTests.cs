using System.Net;
using System.Net.Http.Json;
using MacMaui.ClientLogic;

namespace MacMaui.ClientTests;

/// <summary>
/// The API client's job is now more than deserialising: it has to ask the server for the right
/// number of days. Asking for the wrong number would be invisible in the UI, since the server
/// happily returns its default, so the request itself is what these tests assert on.
/// </summary>
public class WeatherApiClientTests
{
    private sealed class CapturingHandler(params WeatherForecast[] forecasts) : HttpMessageHandler
    {
        public Uri? LastRequestUri { get; private set; }

        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request, CancellationToken cancellationToken)
        {
            LastRequestUri = request.RequestUri;
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = JsonContent.Create(forecasts)
            });
        }
    }

    private static WeatherForecast Forecast(int day) =>
        new(DateOnly.FromDateTime(DateTime.Today).AddDays(day), 20, "Mild");

    private static (WeatherApiClient Client, CapturingHandler Handler) Create(int returning)
    {
        var handler = new CapturingHandler(Enumerable.Range(1, returning).Select(Forecast).ToArray());
        var http = new HttpClient(handler) { BaseAddress = new Uri("https://apiservice.test") };
        return (new WeatherApiClient(http), handler);
    }

    [Fact]
    public async Task Asks_the_server_for_the_requested_number_of_days()
    {
        var (client, handler) = Create(returning: 12);

        await client.GetWeatherAsync(12, TestContext.Current.CancellationToken);

        handler.LastRequestUri!.Query.ShouldContain("days=12");
    }

    [Fact]
    public async Task Returns_every_forecast_the_server_sent()
    {
        var (client, _) = Create(returning: 12);

        var forecasts = await client.GetWeatherAsync(12, TestContext.Current.CancellationToken);

        forecasts.Length.ShouldBe(12);
    }

    [Fact]
    public async Task Defaults_to_a_sensible_number_of_days()
    {
        var (client, handler) = Create(returning: 5);

        await client.GetWeatherAsync(cancellationToken: TestContext.Current.CancellationToken);

        handler.LastRequestUri!.Query.ShouldContain("days=");
    }
}
