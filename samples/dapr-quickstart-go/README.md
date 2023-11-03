# Dapr Quickstart Sample

This is a Dapr sample that makes use of the aio-mq-pubsub and aio-mq-statestore pluggable component to interact with the IoT MQ broker and the IoT MQ state store.

## Deploying the app

For instructions on how to deploy and interact with this, refer to [Use Dapr to develop distributed application workloads](https://learn.microsoft.com/azure/iot-operations/develop/howto-develop-dapr-app)

## Building

To build the quickstart image, use the following command: 

```
docker build . -t quickstart-sample:0.3 -t quickstart-sample:latest
```
