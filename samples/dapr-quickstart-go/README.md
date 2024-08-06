# Dapr Quickstart Sample

This is a Dapr sample that makes use of the Azure IoT Operations pluggable Dapr components to interact with the MQTT broker and the State Store.

## Deploying the app

For instructions on how to deploy and interact with this, refer to [Use Dapr to develop distributed application workloads](https://learn.microsoft.com/azure/iot-operations/develop/howto-develop-dapr-app)

## Building

To build the quickstart image, use the following command: 

    ``` bash
    docker build . -t quickstart-sample:1.0 -t quickstart-sample:latest
    ```
