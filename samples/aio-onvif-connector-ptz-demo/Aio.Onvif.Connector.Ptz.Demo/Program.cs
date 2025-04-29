using System.CommandLine;
using Aio.Onvif.Connector.Ptz.Demo;
using Azure.Iot.Operations.Mqtt.Session;
using Azure.Iot.Operations.Protocol;
using Azure.Iot.Operations.Protocol.Models;
using MediaClient.Media;
using PtzClient.Ptz;

var hostOption = new Option<string>(["--mqtt-host", "-h"], description: "The Hostname or IP of the MQTT Listener the demo connects to", getDefaultValue: () => "localhost");
var portOption = new Option<int>(["--mqtt-port", "-p"], description: "The port of the MQTT Listener the demo connects to", getDefaultValue: () => 1883);
var namespaceOption = new Option<string>(["--namespace", "-n"], description: "The Kubernetes namespace AIO is deployed to", getDefaultValue: () => "azure-iot-operations");
var ptzAssetOption = new Option<string>(["--ptz-asset", "-pa"], description: "The name of the PTZ asset") { IsRequired = true };
var mediaAssetOption = new Option<string>(["--media-asset", "-ma"], description: "The name of the media asset") { IsRequired = true };
var modeOption = new Option<string>(["--mode", "-m"], description: "The method that should be used to move the camera", getDefaultValue: () => "relative").FromAmong("relative", "continuous");

var rootCommand = new RootCommand("AIO ONVIF Connector Demo");
rootCommand.AddOption(hostOption);
rootCommand.AddOption(portOption);
rootCommand.AddOption(namespaceOption);
rootCommand.AddOption(ptzAssetOption);
rootCommand.AddOption(mediaAssetOption);
rootCommand.AddOption(modeOption);

rootCommand.SetHandler(async (host, port, @namespace, ptzAsset, mediaAsset, mode) =>
{
    Console.WriteLine($"MQTT Host: {host}");
    Console.WriteLine($"MQTT Port: {port}");
    Console.WriteLine($"Namespace: {@namespace}");
    Console.WriteLine($"PTZ Asset: {ptzAsset}");
    Console.WriteLine($"Media Asset: {mediaAsset}");
    Console.WriteLine($"Mode: {mode}");

    var mqttClientTcpOptions = new MqttClientTcpOptions(host, port);

    var mqttClientOptions = new MqttClientOptions(mqttClientTcpOptions) { SessionExpiryInterval = 60 };

    var mqttSessionClient = new MqttSessionClient(new MqttSessionClientOptions());
    await mqttSessionClient.ConnectAsync(mqttClientOptions);
    var applicationContext = new ApplicationContext();
    var ptzClient = new OnvifPtzClient(applicationContext, mqttSessionClient);
    var mediaClient = new OnvifMediaClient(applicationContext, mqttSessionClient);

    var profiles = await mediaClient.GetProfilesAsync(new Dictionary<string, string>
    {
        { "ex:namespace", @namespace },
        { "ex:asset", mediaAsset }
    });
    var profile = profiles.GetProfilesCommandResponse.Profiles.First();

    Console.WriteLine("Use arrow keys or WASD to move camera, Q to quit");

    if (mode == "relative")
    {
        await StartRelativeMoveAsync(ptzClient, profile, @namespace, ptzAsset);
    }
    else if (mode == "continuous")
    {
        await StartContinuousMoveAsync(ptzClient, profile, @namespace, ptzAsset);
    }

    await StartRelativeMoveAsync(ptzClient, profile, @namespace, ptzAsset);
}, hostOption, portOption, namespaceOption, ptzAssetOption, mediaAssetOption, modeOption);

await rootCommand.InvokeAsync(args);

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

            await ptzClient.RelativeMoveAsync(request, new Dictionary<string, string>
            {
                { "ex:namespace", @namespace },
                { "ex:asset", ptzAssetName }
            });
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

            await ptzClient.ContinuousMoveAsync(request, new Dictionary<string, string>
            {
                { "ex:namespace", @namespace },
                { "ex:asset", ptzAssetName }
            });
            await Task.Delay(1000).ConfigureAwait(true);
            await ptzClient.StopAsync(new StopRequestPayload { Stop = new Stop { ProfileToken = profile.Token, PanTilt = true } }, new Dictionary<string, string>
            {
                { "ex:namespace", @namespace },
                { "ex:asset", ptzAssetName }
            });
        }
        catch (Exception e)
        {
            Console.WriteLine($"Error: {e.Message}");
            // Bad request is expected if the camera reaches the limit
        }
    }
}

