# Dapr Workflow sample

## Overview

This sample uses Dapr to execute a workflow that listens to the topic `sensor/in`, does a simple conversion from Farenheit to Celsius and then writes to topic `sensor/out`.

## Prerequisites

1. An [AIO deployment](https://learn.microsoft.com/azure/iot-operations/get-started/quickstart-deploy)
1. An [Azure Service Bus queue](https://learn.microsoft.com/en-us/azure/service-bus-messaging/service-bus-quickstart-portal)
1. [Dapr CLI](https://docs.dapr.io/getting-started/install-dapr-cli/)
1. mosquitto_pub from the [Mosquitto](https://mosquitto.org/download/) installer

> [!WARNING]
> If installing Mosquitto for Windows, deselect the `Service` component as you may have conflicts with the IoT Operations MQTT broker.

## Setup

The application can be deployed into the Kubernetes cluster, or it can be run locally.

> [!NOTE]
> To run **locally** the MQTT Broker must be available to the host machine. This is the default if running this sample in Codespaces.

### Kubernetes

1. Build the container:

    ```bash
    docker build . -t dapr-workflow-sample
    ```

1. Import to the CodeSpaces cluster:

    ```bash
    k3d image import dapr-workflow-sample
    ```

1. Install Dapr to the cluster:

    ```bash
    dapr init -k
    ```

1. Deploy the yaml:

    ```bash
    kubectl apply -f app.yaml
    ```
### Local

1. Configure the cluster with [No TLS and no authentications](https://learn.microsoft.com/azure/iot-operations/manage-mqtt-connectivity/howto-test-connection#no-tls-and-no-authentication) to simply publishing from the host machine.

1. Install the IoT Operations pluggable component:
    
    ```bash
    mkdir /tmp/dapr-components-sockets
    docker run --name aio-dapr --network host --restart unless-stopped -v /tmp/dapr-components-sockets:/tmp/dapr-components-sockets -d ghcr.io/azure/iot-mq-dapr-components:latest
    ```

1. Initialize the local Dapr environment:

    ```bash
    dapr init
    ```

1. Run the workflow sample:

    ```bash
    dapr run --app-port 6001 --app-protocol grpc --resources-path resources -- go run .
    ```

## Testing

1. Configure the cluster with [No TLS and no authentications](https://learn.microsoft.com/azure/iot-operations/manage-mqtt-connectivity/howto-test-connection#no-tls-and-no-authentication) to simplify publishing from the host machine.

1. Subscribe to the workflow output:

    ```bash
    mosquitto_sub -L mqtt://localhost/sensor/out
    ```

1. In another terminal, publish a message to the broker using Mosquitto:

    ```bash
    mosquitto_pub -L mqtt://localhost/sensor/in -m '{ "name":"mysensor", "temperature_f":100 }'
    ```

1. Confirm the resulting output from the subscribe containing the Celsius conversion:

    ```json
    {"name":"mysensor","temperature_f":100,"temperature_c":37.77778}
    ```
