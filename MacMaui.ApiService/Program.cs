using System.Diagnostics;
using MacMaui.ApiService;

var builder = WebApplication.CreateBuilder(args);

// Add service defaults & Aspire client integrations.
builder.AddServiceDefaults();

// Add services to the container.
builder.Services.AddProblemDetails();

// Singleton: the whole point is that every request sees the same cached forecast.
builder.Services.AddSingleton(TimeProvider.System);
builder.Services.AddSingleton<ForecastCache>();

// Learn more about configuring OpenAPI at https://aka.ms/aspnet/openapi
builder.Services.AddOpenApi();

var app = builder.Build();

// Configure the HTTP request pipeline.
app.UseExceptionHandler();

if (app.Environment.IsDevelopment())
{
    app.MapOpenApi();
}

app.MapGet("/", () => "API service is running. Navigate to /weatherforecast to see sample data.");

// days is optional so existing callers keep working. The upper bound is arbitrary but stops a
// single request from asking for a decade of weather.
const int MaxDays = 90;

app.MapGet("/weatherforecast", (ForecastCache cache, int days = 5) =>
{
    if (days < 1 || days > MaxDays)
    {
        return Results.ValidationProblem(new Dictionary<string, string[]>
        {
            ["days"] = [$"days must be between 1 and {MaxDays}."]
        });
    }

    // On the server the day count only exists inside the query string, which means parsing URLs
    // to chart it and no way at all to group the built-in duration metrics by it. Recording it on
    // the current request span puts it in customDimensions, where it can be grouped directly.
    Activity.Current?.SetTag("weather.days_requested", days);

    return Results.Ok(cache.GetForecast(days));
})
.WithName("GetWeatherForecast");

app.MapDefaultEndpoints();

app.Run();
