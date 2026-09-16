using Azure.Monitor.OpenTelemetry.Exporter;
using System.Reflection;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using OpenTelemetry;
using OpenTelemetry.Logs;
using OpenTelemetry.Metrics;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;
using System.Text.RegularExpressions;

namespace Microsoft.Extensions.Hosting;

// Adds common Aspire services: service discovery, resilience, health checks, and OpenTelemetry.
// This project should be referenced by each service project in your solution.
// To learn more about using this project, see https://aka.ms/dotnet/aspire/service-defaults
public static class Extensions
{
    public static TBuilder AddServiceDefaults<TBuilder>(this TBuilder builder) where TBuilder : IHostApplicationBuilder
    {
        // MauiApp.CreateBuilder() starts with an empty ConfigurationManager, unlike the ASP.NET Core
        // host. Without this, neither the OTLP endpoint nor the service discovery keys that Aspire
        // injects as environment variables are visible to the app.
        builder.Configuration.AddEnvironmentVariables();

        builder.ConfigureOpenTelemetry();

        builder.Services.AddServiceDiscovery();

        builder.Services.ConfigureHttpClientDefaults(http =>
        {
            // Turn on resilience by default
            http.AddStandardResilienceHandler();

            // Turn on service discovery by default
            http.AddServiceDiscovery();
        });

        builder.Services.TryAddEnumerable(
            ServiceDescriptor.Transient<IMauiInitializeService, OpenTelemetryInitializer>(_ => new OpenTelemetryInitializer()));

        // Uncomment the following to restrict the allowed schemes for service discovery.
        // builder.Services.Configure<ServiceDiscoveryOptions>(options =>
        // {
        //     options.AllowedSchemes = ["https"];
        // });

        return builder;
    }

    public static TBuilder ConfigureOpenTelemetry<TBuilder>(this TBuilder builder) where TBuilder : IHostApplicationBuilder
    {
        builder.Logging.AddOpenTelemetry(logging =>
        {
            logging.IncludeFormattedMessage = true;
            logging.IncludeScopes = true;
        });

        builder.Services.AddOpenTelemetry()
            // Name the client. Without this every signal arrives labelled "unknown_service:dotnet",
            // which is unhelpful next to the API, whose name App Service supplies. The version
            // comes along too, so telemetry can be grouped by which release someone is running.
            .ConfigureResource(resource => resource.AddService(
                serviceName: Assembly.GetEntryAssembly()?.GetName().Name ?? "MacMaui.Mobile",
                serviceVersion: Assembly.GetEntryAssembly()?.GetName().Version?.ToString()))
            .WithMetrics(metrics =>
            {
                // Uncomment the following line to enable reporting metrics coming from the .NET MAUI SDK, this might cause a lot of added telemetry
                //metrics.AddMeter("Microsoft.Maui");
                
                metrics.AddHttpClientInstrumentation()
                    .AddRuntimeInstrumentation();
            })
            .WithTracing(tracing =>
            {
                // Uncomment the following line to enable reporting tracing coming from the .NET MAUI SDK, this might cause a lot of added telemetry
                //tracing.AddSource("Microsoft.Maui");
                
                tracing.AddSource(builder.Environment.ApplicationName)
                    // Uncomment the following line to enable gRPC instrumentation (requires the OpenTelemetry.Instrumentation.GrpcNetClient package)
                    //.AddGrpcClientInstrumentation()
                    .AddHttpClientInstrumentation();
            });

        builder.AddOpenTelemetryExporters();

        return builder;
    }

    private class OpenTelemetryInitializer : IMauiInitializeService
    {
        public void Initialize(IServiceProvider services)
        {
            services.GetService<MeterProvider>();
            services.GetService<TracerProvider>();
            services.GetService<LoggerProvider>();
        }
    }

    private static TBuilder AddOpenTelemetryExporters<TBuilder>(this TBuilder builder) where TBuilder : IHostApplicationBuilder
    {
        var useOtlpExporter = !string.IsNullOrWhiteSpace(builder.Configuration["OTEL_EXPORTER_OTLP_ENDPOINT"]);

        if (useOtlpExporter)
        {
            builder.Services.AddOpenTelemetry().UseOtlpExporter();
        }

        // Released builds are not launched by Aspire, so there is no dashboard listening and the
        // OTLP endpoint above is unset. The connection string is baked in at build time instead
        // (see ApplicationInsightsConnectionString in MacMaui.Mobile.csproj), which is how a
        // shipped app reports at all. Left unset, the app simply reports nothing.
        var applicationInsights = builder.Configuration["APPLICATIONINSIGHTS_CONNECTION_STRING"];
        if (!string.IsNullOrWhiteSpace(applicationInsights))
        {
            builder.Services.AddOpenTelemetry()
                .WithTracing(tracing => tracing.AddAzureMonitorTraceExporter(
                    options => options.ConnectionString = applicationInsights))
                .WithMetrics(metrics => metrics.AddAzureMonitorMetricExporter(
                    options => options.ConnectionString = applicationInsights));

            builder.Logging.AddOpenTelemetry(logging => logging.AddAzureMonitorLogExporter(
                options => options.ConnectionString = applicationInsights));
        }

        return builder;
    }
}
