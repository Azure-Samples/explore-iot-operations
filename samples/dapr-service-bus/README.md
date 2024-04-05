# Dapr Service Bus sample

## Overview

This sample uses Dapr to subscribe to a topic on IoT MQ and then publish this data to an Azure Service Bus Queue.

## Prerequisites

1. An [AIO deployment](https://learn.microsoft.com/azure/iot-operations/get-started/quickstart-deploy)
1. An [Azure Service Bus queue](https://learn.microsoft.com/en-us/azure/service-bus-messaging/service-bus-quickstart-portal)
1. Install [Dapr CLI](https://docs.dapr.io/getting-started/install-dapr-cli/)
1. mosquitto_pub from the [Mosquitto](https://mosquitto.org/download/) installer

> WARNING:
> If installing Mosquitto for Windows, deselect the `Service` component as you may have conflicts with the Mosquitto broker and IoT MQ.

## Setup

1. Build the container:

    ```
    cd src
    docker build src -t dapr-service-bus:0.0.1
    ```

1. Push to a container registry if desired.

1. Edit `app.yaml` with the following changes:

    1. Update the Service Bus components `connectionString` using a policy with the Manage access
    1. Update the Service Bus components `queueName` with the Service Bus queues name

1. Install Dapr to the cluster:

    ```
    dapr init -k --runtime-version 1.11.0
    ```

1. Deploy the yaml:

    ```
    kubectl apply -f app.yaml
    ```

## Testing

1. Configure the cluster with [No TLS and no authentications](https://learn.microsoft.com/azure/iot-operations/manage-mqtt-connectivity/howto-test-connection#no-tls-and-no-authentication) to IoT MQ for debugging purposes.

1. Publish a message to the broker using Mosquitto:

    ```
    mosquitto_pub -L mqtt://localhost/servicebus -m helloworld
    ```

1. View the output using [Service Bus Explorer](https://learn.microsoft.com/azure/service-bus-messaging/explorer)
