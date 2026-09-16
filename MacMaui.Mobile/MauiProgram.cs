using System.Reflection;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Hosting;
using MacMaui.ClientLogic;
using MacMaui.Mobile.Services;
using Microsoft.Extensions.Logging;
using OpenTelemetry.Metrics;
using OpenTelemetry.Trace;

namespace MacMaui.Mobile;

public static class MauiProgram
{
	public static MauiApp CreateMauiApp()
	{
		var builder = MauiApp.CreateBuilder();
		builder
			.UseMauiApp<App>()
			.ConfigureFonts(fonts =>
			{
				fonts.AddFont("OpenSans-Regular.ttf", "OpenSansRegular");
				fonts.AddFont("OpenSans-Semibold.ttf", "OpenSansSemibold");
			});

		// Outside Aspire (a TestFlight, APK, or zip build) nothing in the environment says where the
		// API lives, so the build bakes the address in: -p:ApiBaseUrl=https://... becomes an assembly
		// metadata attribute (see the csproj). Registering it as the service discovery entry for
		// "apiservice" keeps a single code path below. AddServiceDefaults adds Aspire's environment
		// variables after this, so when the app is launched from the AppHost those still win.
		var metadata = typeof(MauiProgram).Assembly
			.GetCustomAttributes<AssemblyMetadataAttribute>()
			.ToDictionary(a => a.Key, a => a.Value);

		var apiBaseUrl = metadata.GetValueOrDefault("ApiBaseUrl");
		if (Uri.TryCreate(apiBaseUrl, UriKind.Absolute, out var apiUri))
		{
			builder.Configuration.AddInMemoryCollection(new Dictionary<string, string?>
			{
				[$"services:apiservice:{apiUri.Scheme}:0"] = apiUri.GetLeftPart(UriPartial.Authority),
			});
		}

		// Telemetry destination for a released build, read the same way. AddServiceDefaults
		// below picks this up out of configuration and attaches the Azure Monitor exporters.
		var applicationInsights = metadata.GetValueOrDefault("ApplicationInsightsConnectionString");
		if (!string.IsNullOrWhiteSpace(applicationInsights))
		{
			builder.Configuration.AddInMemoryCollection(new Dictionary<string, string?>
			{
				["APPLICATIONINSIGHTS_CONNECTION_STRING"] = applicationInsights,
			});
		}

		builder.AddServiceDefaults();

		// Register the app's own ActivitySource and Meter with OpenTelemetry. Without these two
		// lines the spans and instruments from Telemetry.cs are created but never exported.
		builder.Services.AddOpenTelemetry()
			.WithTracing(tracing => tracing.AddSource(Telemetry.ActivitySourceName))
			.WithMetrics(metrics => metrics.AddMeter(Telemetry.MeterName));

		builder.Services.AddSingleton<Telemetry>();
		builder.Services.AddSingleton<AppUpdateService>();

		builder.Services.AddHttpClient<IWeatherApiClient, WeatherApiClient>(client =>
		{
			// "https+http://" prefers HTTPS. "apiservice" is the resource name from AppHost.cs,
			// resolved by service discovery from the environment Aspire injects.
			client.BaseAddress = new Uri("https+http://apiservice");
		});

		builder.Services.AddTransient<WeatherViewModel>();
		builder.Services.AddSingleton<AppShell>();
		builder.Services.AddTransient<MainPage>();


		return builder.Build();
	}
}
