using System.CommandLine;
using Aio.Onvif.Connector.Ptz.Demo;
using Azure.Iot.Operations.Mqtt.Session;
using Azure.Iot.Operations.Protocol;
using Azure.Iot.Operations.Protocol.Models;
using MediaClient.Media;
using PtzClient.Ptz;

var hostOption = new Option<string>("--mqtt-host", "-h") { Description = "The Hostname or IP of the MQTT Listener the demo connects to", DefaultValueFactory = _ => "localhost" };
var portOption = new Option<int>("--mqtt-port", "-p") { Description = "The port of the MQTT Listener the demo connects to", DefaultValueFactory = _ => 1883 };
var namespaceOption = new Option<string>("--namespace", "-n") { Description = "The Kubernetes namespace AIO is deployed to", DefaultValueFactory = _ => "azure-iot-operations" };
var assetOption = new Option<string>("--asset", "-a") { Description = "The name of the asset", Required = true };
var modeOption = new Option<string>("--mode", "-m") { Description = "The method that should be used to move the camera", DefaultValueFactory = _ => "relative", }.AcceptOnlyFromAmong("relative", "continuous");

var rootCommand = new RootCommand("AIO ONVIF Connector Demo")
{
    hostOption,
    portOption,
    namespaceOption,
    assetOption,
    modeOption
};

rootCommand.SetAction(async parseResult =>
{
    var host = parseResult.GetValue(hostOption) ?? throw new ArgumentNullException(nameof(hostOption), "MQTT host cannot be null");
    var port = parseResult.GetValue(portOption);
    var @namespace = parseResult.GetValue(namespaceOption) ?? throw new ArgumentNullException(nameof(namespaceOption), "Namespace cannot be null");
    var asset = parseResult.GetValue(assetOption) ?? throw new ArgumentNullException(nameof(assetOption), "Asset cannot be null");
    var mode = parseResult.GetValue(modeOption) ?? throw new ArgumentNullException(nameof(modeOption), "Mode cannot be null");

    Console.WriteLine($"MQTT Host: {host}");
    Console.WriteLine($"MQTT Port: {port}");
    Console.WriteLine($"Namespace: {@namespace}");
    Console.WriteLine($"Asset: {asset}");
    Console.WriteLine($"Mode: {mode}");

    var mqttClientTcpOptions = new MqttClientTcpOptions(host, port);

    var mqttClientOptions = new MqttClientOptions(mqttClientTcpOptions) { SessionExpiryInterval = 60 };

    var mqttSessionClient = new MqttSessionClient(new MqttSessionClientOptions());
    await mqttSessionClient.ConnectAsync(mqttClientOptions);
    var applicationContext = new ApplicationContext();
    var ptzClient = new OnvifPtzClient(applicationContext, mqttSessionClient, new Dictionary<string, string>
    {
        { "namespace", @namespace },
        { "asset", asset }
    });
    var mediaClient = new OnvifMediaClient(applicationContext, mqttSessionClient, new Dictionary<string, string>
    {
        { "namespace", @namespace },
        { "asset", asset }
    });

    var profiles = await mediaClient.GetProfilesAsync();
    var profile = profiles.Result.Profiles.First();

    Console.WriteLine("Use arrow keys or WASD to move camera, Q to quit");

    if (mode == "relative")
    {
        await StartRelativeMoveAsync(ptzClient, profile, @namespace, asset);
    }
    else if (mode == "continuous")
    {
        await StartContinuousMoveAsync(ptzClient, profile, @namespace, asset);
    }

    await StartRelativeMoveAsync(ptzClient, profile, @namespace, asset);
});

await new CommandLineConfiguration(rootCommand).InvokeAsync(args);

async Task StartRelativeMoveAsync(OnvifPtzClient ptzClient, Profile profile, string @namespace, string ptzAssetName)
{
    while (true)
    {
        var key = Console.ReadKey(true).Key;
        if (key == ConsoleKey.Q)
        {
            return;
        }

        (float x, float y)? delta = key switch
        {
            ConsoleKey.UpArrow => (0, 0.2f),
            ConsoleKey.DownArrow => (0, -0.2f),
            ConsoleKey.LeftArrow => (0.2f, 0),
            ConsoleKey.RightArrow => (-0.2f, 0),
            ConsoleKey.W => (0, 0.2f),
            ConsoleKey.S => (0, -0.2f),
            ConsoleKey.A => (0.2f, 0),
            ConsoleKey.D => (-0.2f, 0),
            _ => null
        };

        if (delta == null)
        {
            continue;
        }

        try
        {
            var request = new RelativeMoveRequestPayload
            {
                RelativeMove = new RelativeMove
                {
                    ProfileToken = profile.Token,
                    Translation = new Ptzvector
                    {
                        PanTilt = new PtzClient.Ptz.Vector2d
                        {
                            X = delta.Value.x,
                            Y = delta.Value.y,
                        }
                    }
                }
            };

            await ptzClient.RelativeMoveAsync(request);
        }
        catch (Exception e)
        {
            Console.WriteLine($"Error: {e.Message}");
            // Bad request is expected if the camera reaches the limit
        }

        await Task.Delay(1000).ConfigureAwait(true);
    }
}

async Task StartContinuousMoveAsync(OnvifPtzClient ptzClient, Profile profile, string @namespace, string ptzAssetName)
{
    while (true)
    {
        var key = Console.ReadKey(true).Key;
        if (key == ConsoleKey.Q)
        {
            return;
        }

        (float x, float y)? delta = key switch
        {
            ConsoleKey.UpArrow => (0, 0.2f),
            ConsoleKey.DownArrow => (0, -0.2f),
            ConsoleKey.LeftArrow => (-0.2f, 0),
            ConsoleKey.RightArrow => (0.2f, 0),
            ConsoleKey.W => (0, 0.2f),
            ConsoleKey.S => (0, -0.2f),
            ConsoleKey.A => (-0.2f, 0),
            ConsoleKey.D => (0.2f, 0),
            _ => null
        };

        if (delta == null)
        {
            continue;
        }

        try
        {
            var request = new ContinuousMoveRequestPayload
            {
                ContinuousMove = new ContinuousMove
                {
                    ProfileToken = profile.Token,
                    Velocity = new PtzClient.Ptz.Ptzspeed
                    {
                        PanTilt = new PtzClient.Ptz.Vector2d
                        {
                            X = delta.Value.x,
                            Y = delta.Value.y,
                        }
                    }
                }
            };

            await ptzClient.ContinuousMoveAsync(request);
            await Task.Delay(1000).ConfigureAwait(true);
            await ptzClient.StopAsync(new StopRequestPayload { Stop = new Stop { ProfileToken = profile.Token, PanTilt = true } });
        }
        catch (Exception e)
        {
            Console.WriteLine($"Error: {e.Message}");
            // Bad request is expected if the camera reaches the limit
        }
    }
}

