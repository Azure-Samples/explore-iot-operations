---
page_type: sample
description: Learn how to aggregate data at the edge using IoT MQ and Dapr.
languages:
- python
products:
- azure-iot-operations
---

# Building event driven apps with Dapr

Learn how to aggregate data at the edge using IoT MQ and Dapr.

## Tutorial instructions

For detailed instructions on running this tutorial, follow [Build event-driven apps with Dapr](https://learn.microsoft.com/azure/iot-operations/tutorials/tutorial-event-driven-with-dapr/).

## Building

1. To build the application container, execute the following:

    ```bash
    docker build . -t mq-event-driven-dapr
    ```

## Running

To run the application, deploy it to your cluster:

1. The application:

    ```bash
    kubectl apply -f ./yaml/deploy.yaml
    ```

1. The simulator:

    ```bash
    kubectl apply -f ./yaml/simulate-data.yaml
    ```
