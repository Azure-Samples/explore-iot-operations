# Dapr Service Bus Dotnet sample

## Overview

This sample uses Dapr to subscribe to a topic on IoT MQ and then publish this data to an Azure Service Bus Queue.

## Prerequisites

1. An [AIO deployment](https://learn.microsoft.com/azure/iot-operations/get-started/quickstart-deploy)
1. An [Azure Service Bus queue](https://learn.microsoft.com/en-us/azure/service-bus-messaging/service-bus-quickstart-portal)
1. [Dapr CLI](https://docs.dapr.io/getting-started/install-dapr-cli/)
1. mosquitto_pub from the [Mosquitto](https://mosquitto.org/download/) installer

> [!WARNING]
> If installing Mosquitto for Windows, deselect the `Service` component as you may have conflicts with the Mosquitto broker and IoT MQ.

## Setup

1. Build the container:

    ```bash
    dotnet publish --os linux --arch x64 -p:PublishProfile=DefaultContainer
    ```

1. Import to the CodeSpaces cluster:

    ```bash
    k3d image import dapr-service-bus-dotnet
    ```

1. Edit `app.yaml` with the following changes:

    1. Update the Service Bus components `connectionString` using a policy with the Manage access
    1. Update the Service Bus components `queueName` with the Service Bus queues name

1. Install Dapr to the cluster:

    ```bash
    dapr init -k
    ```

1. Deploy the yaml:

    ```bash
    kubectl apply -f app.yaml
    ```

## Testing

1. Configure the cluster with [No TLS and no authentications](https://learn.microsoft.com/azure/iot-operations/manage-mqtt-connectivity/howto-test-connection#no-tls-and-no-authentication) to IoT MQ for debugging purposes.

1. Publish a message to the broker using Mosquitto:

    ```bash
    mosquitto_pub -L mqtt://localhost/servicebus -m helloworld
    ```

1. View the log of the deployment to confirm the message was received and sent to ServiceBus:

    ```bash
    kubectl logs -l app=dapr-workload-service-bus-dotnet -n azure-iot-operations
    ```

    output:

    ```output
    Defaulted container "dapr-workload-service-bus-dotnet" out of: dapr-workload-service-bus-dotnet, daprd, aio-mq-components
    info: dapr-service-bus-dotnet[0]
          event: data:helloworld
    info: dapr-service-bus-dotnet[0]
          event: Sent message to service bus
    info: Microsoft.AspNetCore.Http.Result.OkObjectResult[1]
          Setting HTTP status code 200.
    info: Microsoft.AspNetCore.Routing.EndpointMiddleware[1]
          Executed endpoint 'HTTP: POST /servicebus'
    info: Microsoft.AspNetCore.Hosting.Diagnostics[2]
          Request finished HTTP/1.1 POST http://127.0.0.1:6001/servicebus - 200 0 - 52.9646ms
    ```

1. View the output in the Azure Portal using [Service Bus Explorer](https://learn.microsoft.com/azure/service-bus-messaging/explorer)
