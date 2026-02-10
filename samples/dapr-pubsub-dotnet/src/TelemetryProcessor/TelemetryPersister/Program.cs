using TelemetryPersister.Infrastructure;

namespace TelemetryPersister
{
    public class Program
    {
        public static void Main(string[] args)
        {
            var builder = WebApplication.CreateBuilder(args);

            // Add services to the container.

            builder.Services.AddControllers(options => options.InputFormatters.Add(new DaprRawPayloadInputFormatter()))
                            .AddDapr();
            builder.Services.AddDaprClient();
            // Learn more about configuring Swagger/OpenAPI at https://aka.ms/aspnetcore/swashbuckle
            builder.Services.AddEndpointsApiExplorer();
            builder.Services.AddSwaggerGen();

            builder.Services.AddLogging(logBuilder =>
            {
                logBuilder.SetMinimumLevel(LogLevel.Information);
                logBuilder.AddSystemdConsole(options =>
                {
                    options.UseUtcTimestamp = true;
                    options.TimestampFormat = "yyyy-MM-dd HH:mm:ss.fff zzz ";
                });
            });

            var app = builder.Build();

            // Configure the HTTP request pipeline.
            if (app.Environment.IsDevelopment())
            {
                app.UseSwagger();
                app.UseSwaggerUI();
            }

            app.UseAuthorization();

            app.UseCloudEvents();

            app.MapControllers();

            app.MapSubscribeHandler();

            app.Run();
        }
    }
}