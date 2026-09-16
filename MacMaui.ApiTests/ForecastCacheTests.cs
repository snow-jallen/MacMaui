using MacMaui.ApiService;
using Microsoft.Extensions.Time.Testing;

namespace MacMaui.ApiTests;

/// <summary>
/// The cache has one rule that is easy to state and easy to get wrong: a forecast, once
/// produced, does not change for ten seconds, and asking for more days extends the list without
/// extending that deadline. These tests pin both halves down.
/// </summary>
public class ForecastCacheTests
{
    private static readonly DateTimeOffset Start = new(2026, 9, 16, 8, 0, 0, TimeSpan.Zero);

    private static (ForecastCache Cache, FakeTimeProvider Time) Create()
    {
        var time = new FakeTimeProvider(Start);
        return (new ForecastCache(time), time);
    }

    [Fact]
    public void Returns_the_number_of_days_asked_for()
    {
        var (cache, _) = Create();

        cache.GetForecast(5).Count.ShouldBe(5);
    }

    [Fact]
    public void Dates_run_consecutively_from_tomorrow()
    {
        var (cache, time) = Create();

        var forecast = cache.GetForecast(3);

        var tomorrow = DateOnly.FromDateTime(time.GetUtcNow().Date).AddDays(1);
        forecast.Select(f => f.Date).ShouldBe([tomorrow, tomorrow.AddDays(1), tomorrow.AddDays(2)]);
    }

    [Fact]
    public void Asking_again_inside_the_window_gives_the_same_forecast()
    {
        var (cache, time) = Create();

        var first = cache.GetForecast(4);
        time.Advance(TimeSpan.FromSeconds(9));
        var second = cache.GetForecast(4);

        second.ShouldBe(first);
    }

    [Fact]
    public void Asking_for_more_days_keeps_the_days_already_cached()
    {
        var (cache, time) = Create();

        var ten = cache.GetForecast(10);
        time.Advance(TimeSpan.FromSeconds(3));
        var fifteen = cache.GetForecast(15);

        fifteen.Count.ShouldBe(15);
        // The original ten are untouched; only the extra five are new.
        fifteen.Take(10).ShouldBe(ten);
    }

    [Fact]
    public void Asking_for_more_days_does_not_extend_the_deadline()
    {
        var (cache, time) = Create();

        var ten = cache.GetForecast(10);

        // Nine seconds in, ask for more. The five new days join the cache but the whole lot
        // still expires ten seconds after the *first* request, one second from now.
        time.Advance(TimeSpan.FromSeconds(9));
        var fifteen = cache.GetForecast(15);
        fifteen.Take(10).ShouldBe(ten);

        time.Advance(TimeSpan.FromSeconds(2));
        var afterExpiry = cache.GetForecast(15);
        afterExpiry.ShouldNotBe(fifteen);
    }

    [Fact]
    public void Everything_is_regenerated_once_the_window_passes()
    {
        var (cache, time) = Create();

        var first = cache.GetForecast(5);
        time.Advance(ForecastCache.Lifetime);
        var second = cache.GetForecast(5);

        second.ShouldNotBe(first);
    }

    [Fact]
    public void Asking_for_fewer_days_returns_the_front_of_the_cache()
    {
        var (cache, time) = Create();

        var ten = cache.GetForecast(10);
        time.Advance(TimeSpan.FromSeconds(1));
        var three = cache.GetForecast(3);

        three.ShouldBe(ten.Take(3));
    }

    [Fact]
    public void Shrinking_then_growing_still_does_not_regenerate()
    {
        var (cache, time) = Create();

        var ten = cache.GetForecast(10);
        cache.GetForecast(2);
        time.Advance(TimeSpan.FromSeconds(1));
        var back = cache.GetForecast(10);

        // Asking for fewer days must not discard the rest of the cache.
        back.ShouldBe(ten);
    }

    [Fact]
    public void Concurrent_callers_see_one_consistent_forecast()
    {
        var (cache, _) = Create();

        var results = new IReadOnlyList<WeatherForecast>[64];
        Parallel.For(0, results.Length, i => results[i] = cache.GetForecast(1 + (i % 20)));

        // Every caller's day one came from the same generation.
        results.Select(r => r[0]).Distinct().Count().ShouldBe(1);
    }
}
