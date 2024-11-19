using Aio.Onvif.Connector.Ptz.Demo;
using Azure.Iot.Operations.Mqtt.Session;
using Azure.Iot.Operations.Protocol.Models;
using PTZ.dtmi_onvif_ptz__1;

Console.Write("Mqtt Broker Host: ");
var host = Console.ReadLine();
if (string.IsNullOrWhiteSpace(host))
{
    Console.Error.WriteLine("Invalid host");
    Environment.Exit(1);
}

Console.Write("Mqtt Broker Port: ");
if (!int.TryParse(Console.ReadLine(), out var port))
{
    Console.Error.WriteLine("Invalid port number");
    Environment.Exit(1);
}

Console.Write("AIO Namespace: ");
var aioNamespace = Console.ReadLine();
if (string.IsNullOrWhiteSpace(aioNamespace))
{
    Console.Error.WriteLine("Invalid AIO namespace");
    Environment.Exit(1);
}

Console.Write("Asset Name: ");
var assetName = Console.ReadLine();
if (string.IsNullOrWhiteSpace(assetName))
{
    Console.Error.WriteLine("Invalid asset name");
    Environment.Exit(1);
}

Console.Write("Profile Token: ");
var profileToken = Console.ReadLine();
if (string.IsNullOrWhiteSpace(profileToken))
{
    Console.Error.WriteLine("Invalid profile token");
    Environment.Exit(1);
}

Console.Clear();

var mqttClientTcpOptions = new MqttClientTcpOptions(host, port);

var mqttClientOptions = new MqttClientOptions(mqttClientTcpOptions) { SessionExpiryInterval = 60 };

var mqttSessionClient = new MqttSessionClient(new MqttSessionClientOptions());

await mqttSessionClient.ConnectAsync(mqttClientOptions).ConfigureAwait(true);
var client = new PtzClient(mqttSessionClient);
client.CustomTopicTokenMap.Add("asset", assetName);
client.CustomTopicTokenMap.Add("namespace", aioNamespace);

Console.WriteLine("Use arrow keys or WASD to move camera, Q to quit");

while (true)
{
    var key = Console.ReadKey(true).Key;
    if (key == ConsoleKey.Q)
    {
        break;
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
            RelativeMove = new Object_Onvif_Ptz_RelativeMove__1
            {
                ProfileToken = profileToken,
                Translation = new Object_Onvif_Ptz_PTZVector__1
                {
                    PanTilt = new Object_Onvif_Ptz_Vector2D__1
                    {
                        X = delta.Value.x,
                        Y = delta.Value.y,
                    }
                }
            }
        };

        await client.RelativeMoveAsync(request);
    }
    catch (System.Exception)
    {
        // Bad request is expected if the camera reaches the limit
    }

    await Task.Delay(200).ConfigureAwait(true);
}

