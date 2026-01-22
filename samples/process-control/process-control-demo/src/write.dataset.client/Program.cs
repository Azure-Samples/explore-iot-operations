namespace Aio.Connectors.OpcUa.Demo;

using System.Buffers;
using System.Text;
using Azure.Iot.Operations.Mqtt.Session;
using Azure.Iot.Operations.Protocol;
using Azure.Iot.Operations.Protocol.Connection;
using Azure.Iot.Operations.Protocol.Models;
using Azure.Iot.Operations.Protocol.RPC;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;
using OpcUaMqttRpc;
using OpcUaMqttRpc.Write;
using Terminal.Gui;

/// <summary>
/// Entry point.
/// </summary>
public class Program
{
    /// <summary>
    /// Main program.
    /// </summary>
    /// <returns>A <see cref="Task"/> representing the result of the asynchronous operation.</returns>
    public static async Task Main(string[] args)
    {
        // setup logging
        using var loggerFactory = LoggerFactory.Create(builder => builder.AddConsole());
        var logger = loggerFactory.CreateLogger("ProcessControlDemo");

        // load configuration
        IConfiguration configuration = new ConfigurationBuilder()
            .AddJsonFile("appsettings.json", optional: true, reloadOnChange: true)
            .AddEnvironmentVariables()
            .AddCommandLine(args)
            .Build();

        using var cts = new CancellationTokenSource();
        Console.CancelKeyPress += (_, _) => {
            logger.LogInformation("SIGINT detected - closing application");
            cts.Cancel();
        };

        var sessionClientOptions = new MqttSessionClientOptions
        {
            EnableMqttLogging = true,
        };

        var connectionString = configuration.GetConnectionString("Default");
        if (string.IsNullOrWhiteSpace(connectionString))
        {
            logger.LogError("Please provide connection string via appsettings.json, environment variable or command line argument");
            Environment.FailFast(null);
        }

        var mqttConnectionSettings = MqttConnectionSettings.FromConnectionString(connectionString);
        
        // Read AIO settings from configuration
        var aioNamespace = configuration["AioSettings:Namespace"];
        var assetName = configuration["AioSettings:AssetName"];
        var datasetName = configuration["AioSettings:DatasetName"];
        
        if (string.IsNullOrWhiteSpace(aioNamespace) || string.IsNullOrWhiteSpace(assetName) || string.IsNullOrWhiteSpace(datasetName))
        {
            logger.LogError("Please provide AioSettings (Namespace, AssetName, DatasetName) via appsettings.json, environment variables or command line arguments");
            Environment.FailFast(null);
        }
        
        MqttSessionClient? mqttClient = default;
        ApplicationContext? applicationContext = default;
        WriteDatasetClient? mrpcWriteDatasetClient = default;
        try
        {
            mqttClient = new MqttSessionClient(new MqttSessionClientOptions { EnableMqttLogging = true });
            var connectionResult = await mqttClient.ConnectAsync(mqttConnectionSettings, cts.Token).ConfigureAwait(true);
            if (connectionResult.ResultCode != MqttClientConnectResultCode.Success)
            {
                logger.LogError($"Error while connecting to MQTT Broker {connectionResult.ReasonString} {connectionResult.ResultCode}");
                Environment.FailFast(null);
            }

            logger.LogInformation("Successful connected to MQTT Broker");

            applicationContext = new ApplicationContext();
            mrpcWriteDatasetClient = new WriteDatasetClient(
                applicationContext,
                mqttClient,
                aioNamespace,
                assetName,
                datasetName);

            Application.Init();
            var top = Application.Top;
            var win = new Window("Process Control Demo")
            {
                X = 0,
                Y = 1,
                Width = Dim.Fill(),
                Height = Dim.Fill() - 1,
            };
            top.Add(win);

            var baseTempLabel = new Label("Base Temperature:") { X = 3, Y = 2 };
            var baseTempText = new TextField("42") { X = 40, Y = 2, Width = 40 };
            baseTempText.Enter += (_) => baseTempText.CursorPosition = baseTempText.Text.Length;
            var targetTempLabel = new Label("Target Temperature:") { X = 3, Y = 4 };
            var targetTempText = new TextField("176") { X = 40, Y = 4, Width = 40 };
            targetTempText.Enter += (_) => targetTempText.CursorPosition = targetTempText.Text.Length;
            var tempChangeSpeedLabel = new Label("Temperature Change Speed:") { X = 3, Y = 6 };
            var tempChangeSpeedText = new TextField("6") { X = 40, Y = 6, Width = 40 };
            tempChangeSpeedText.Enter += (_) => tempChangeSpeedText.CursorPosition = tempChangeSpeedText.Text.Length;
            var overheatedThresholdTempLabel = new Label("Overheated Threshold Temperature:") { X = 3, Y = 8 };
            var overheatedThresholdTempText = new TextField("199") { X = 40, Y = 8, Width = 40 };
            overheatedThresholdTempText.Enter += (_) => overheatedThresholdTempText.CursorPosition = overheatedThresholdTempText.Text.Length;
            var maintenanceIntervalLabel = new Label("Maintenance Interval:") { X = 3, Y = 10 };
            var maintenanceIntervalText = new TextField("360") { X = 40, Y = 10, Width = 40 };
            maintenanceIntervalText.Enter += (_) => maintenanceIntervalText.CursorPosition = maintenanceIntervalText.Text.Length;
            var overheatIntervalLabel = new Label("Overheat Interval:") { X = 3, Y = 12 };
            var overheatIntervalText = new TextField("45") { X = 40, Y = 12, Width = 40 };
            overheatIntervalText.Enter += (_) => overheatIntervalText.CursorPosition = overheatIntervalText.Text.Length;

            var sendButton = new Button("Send") { X = 3, Y = 14 };
            var closeButton = new Button("Close") { X = 25, Y = 14 };

            sendButton.Clicked += async () =>
            {
                var request = $@"
                {{
                    ""BaseTemperature"" : {baseTempText.Text},
                    ""TargetTemperature"" : {targetTempText.Text},
                    ""TemperatureChangeSpeed"" : {tempChangeSpeedText.Text},
                    ""OverheatedThresholdTemperature"" : {overheatedThresholdTempText.Text},
                    ""MaintenanceInterval"" : {maintenanceIntervalText.Text},
                    ""OverheatInterval"": {overheatIntervalText.Text}
                }}";

                ReadOnlySequence<byte> buffer = new ReadOnlySequence<byte>(Encoding.UTF8.GetBytes(request));
                var reqPayload = new CustomPayload(buffer, "application/json", MqttPayloadFormatIndicator.CharacterData);

                try
                {
                    var commandRequestMetadata = new CommandRequestMetadata();
                    commandRequestMetadata.UserData.Add("mqtt-property", "value");

                    mrpcWriteDatasetClient.WriteDatasetCommandInvoker.ResponseTopicPattern = "responseTopic/" + Guid.NewGuid().ToString();
                    var rpcCall = await mrpcWriteDatasetClient.WriteDatasetAsync(
                        request: reqPayload,
                        requestMetadata: commandRequestMetadata,
                        commandTimeout: TimeSpan.FromMinutes(1),
                        cancellationToken: cts.Token)
                        .WithMetadata();
                    MessageBox.Query("Success", "Request sent successfully!", "Ok");
                    var responseMetadata = rpcCall.ResponseMetadata;
                }
                catch (Exception e)
                {
                    MessageBox.ErrorQuery("Error", $"Failed to send request: {e.Message}", "Ok");
                }
            };

            closeButton.Clicked += () =>
            {
                cts.Cancel();
                Application.Shutdown();
            };

            win.Add(
                baseTempLabel,
                baseTempText,
                targetTempLabel,
                targetTempText,
                tempChangeSpeedLabel,
                tempChangeSpeedText,
                overheatedThresholdTempLabel,
                overheatedThresholdTempText,
                maintenanceIntervalLabel,
                maintenanceIntervalText,
                overheatIntervalLabel,
                overheatIntervalText,
                sendButton,
                closeButton);

            Application.Run();
        }
        catch (Exception e)
        {
            logger.LogError(e.ToString());
        }
        finally
        {
            await (mrpcWriteDatasetClient?.DisposeAsync() ?? ValueTask.CompletedTask).ConfigureAwait(false);
            await (applicationContext?.DisposeAsync() ?? ValueTask.CompletedTask).ConfigureAwait(false);
            await (mqttClient?.DisposeAsync() ?? ValueTask.CompletedTask).ConfigureAwait(false);
        }

        logger.LogInformation("OPC UA Process Control Demo - Stopped!");
    }
}