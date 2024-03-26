# Dapr Service Bus sample

## Overview

This sample uses Dapr to subscribe to a topic on IoT MQ and then publish this data to an Azure Service Bus Queue.

## Prerequisites

1. An [AIO deployment](https://learn.microsoft.com/azure/iot-operations/get-started/quickstart-deploy)
1. An [Azure Service Bus queue](https://learn.microsoft.com/en-us/azure/service-bus-messaging/service-bus-quickstart-portal)

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

1. Deploy the yaml:

    ```
    kubectl apply -f app.yaml
    ```

## Testing

1. Extract the trust bundle for IoT MQ.

1. Publish a message to the broker using mosquitto.

    ```
    mosquitto_pub 
    ```

1. View the output in the Service Bus Queue

* Publish  local MQTT messages using instructions in the [Quickstart](https://preview.e4k.dev/docs/quickstart/connect-clients/#publish)



