namespace MacMaui.ApiService;

/// <summary>
/// One day's forecast. Public and in its own file rather than tucked under Program.cs so the
/// cache and its tests can both see it.
/// </summary>
public record WeatherForecast(DateOnly Date, int TemperatureC, string? Summary)
{
    public int TemperatureF => 32 + (int)(TemperatureC / 0.5556);
}
