using System.Diagnostics;
using System.Diagnostics.Metrics;
using MacMaui.ClientLogic;

namespace MacMaui.ClientTests;

/// <summary>
/// Telemetry is only worth emitting if it can be sliced afterwards. These tests hold the view
/// model to that: every press records how many days were asked for, on the span and on both
/// instruments, and a failed request records it too. A failure that loses the day count is
/// exactly the one you would want to investigate.
/// </summary>
public class WeatherTelemetryTests : IDisposable
{
    // One Telemetry per test, with both listeners bound to *these* instruments by reference.
    // Matching on the meter or source name instead would pick up measurements from tests running
    // in parallel, since every instance shares the same names.
    private readonly Telemetry _telemetry = new();
    private readonly MeterListener _meterListener = new();
    private readonly ActivityListener _activityListener;
    private readonly List<(string Instrument, double Value, Dictionary<string, object?> Tags)> _measurements = [];
    private readonly List<Activity> _activities = [];

    public WeatherTelemetryTests()
    {
        _meterListener.InstrumentPublished = (instrument, listener) =>
        {
            if (ReferenceEquals(instrument, _telemetry.WeatherRequests)
                || ReferenceEquals(instrument, _telemetry.WeatherRequestDuration))
            {
                listener.EnableMeasurementEvents(instrument);
            }
        };
        _meterListener.SetMeasurementEventCallback<long>(Record);
        _meterListener.SetMeasurementEventCallback<double>(Record);
        _meterListener.Start();

        // Without a listener returning AllData, Activity objects are never created at all and the
        // view model's span tags would quietly go nowhere.
        _activityListener = new ActivityListener
        {
            ShouldListenTo = source => ReferenceEquals(source, _telemetry.ActivitySource),
            Sample = (ref ActivityCreationOptions<ActivityContext> _) => ActivitySamplingResult.AllData,
            ActivityStopped = _activities.Add,
        };
        ActivitySource.AddActivityListener(_activityListener);
    }

    private void Record<T>(Instrument instrument, T value, ReadOnlySpan<KeyValuePair<string, object?>> tags, object? _)
        where T : struct
    {
        var copied = new Dictionary<string, object?>();
        foreach (var tag in tags)
        {
            copied[tag.Key] = tag.Value;
        }

        _measurements.Add((instrument.Name, Convert.ToDouble(value), copied));
    }

    public void Dispose()
    {
        _meterListener.Dispose();
        _activityListener.Dispose();
        _telemetry.Dispose();
    }

    private Dictionary<string, object?> TagsFor(string instrument) =>
        _measurements.Single(m => m.Instrument == instrument).Tags;

    private static IWeatherApiClient ApiReturning(int count)
    {
        var api = Substitute.For<IWeatherApiClient>();
        api.GetWeatherAsync(Arg.Any<int>(), Arg.Any<CancellationToken>())
           .Returns(Enumerable.Range(1, count)
               .Select(d => new WeatherForecast(DateOnly.FromDateTime(DateTime.Today).AddDays(d), 20, "Mild"))
               .ToArray());
        return api;
    }

    private static IWeatherApiClient ApiThrowing()
    {
        var api = Substitute.For<IWeatherApiClient>();
        api.GetWeatherAsync(Arg.Any<int>(), Arg.Any<CancellationToken>())
           .Returns<WeatherForecast[]>(_ => throw new HttpRequestException("apiservice unreachable"));
        return api;
    }

    [Fact]
    public async Task Counts_the_request_with_the_day_count_attached()
    {
        var viewModel = new WeatherViewModel(ApiReturning(9), _telemetry) { Days = 9 };

        await viewModel.LoadWeatherCommand.ExecuteAsync(null);

        var tags = TagsFor("macmaui.mobile.weather_requests");
        tags["outcome"].ShouldBe("success");
        tags["days"].ShouldBe(9);
    }

    [Fact]
    public async Task Records_duration_with_the_day_count_attached()
    {
        var viewModel = new WeatherViewModel(ApiReturning(4), _telemetry) { Days = 4 };

        await viewModel.LoadWeatherCommand.ExecuteAsync(null);

        TagsFor("macmaui.mobile.weather_request.duration")["days"].ShouldBe(4);
    }

    [Fact]
    public async Task A_failed_request_still_records_the_day_count()
    {
        var viewModel = new WeatherViewModel(ApiThrowing(), _telemetry) { Days = 21 };

        await viewModel.LoadWeatherCommand.ExecuteAsync(null);

        var tags = TagsFor("macmaui.mobile.weather_requests");
        tags["outcome"].ShouldBe("failure");
        tags["days"].ShouldBe(21);

        var span = _activities.Single(a => a.OperationName == "GetWeather");
        span.GetTagItem("weather.days_requested").ShouldBe(21);
        span.Status.ShouldBe(ActivityStatusCode.Error);
    }

    [Fact]
    public async Task The_span_carries_the_day_count_and_the_result_size()
    {
        var viewModel = new WeatherViewModel(ApiReturning(6), _telemetry) { Days = 6 };

        await viewModel.LoadWeatherCommand.ExecuteAsync(null);

        var span = _activities.Single(a => a.OperationName == "GetWeather");
        span.GetTagItem("weather.days_requested").ShouldBe(6);
        span.GetTagItem("weather.forecast_count").ShouldBe(6);
    }
}
