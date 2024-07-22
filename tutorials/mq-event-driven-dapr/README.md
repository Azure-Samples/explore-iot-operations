---
page_type: sample
description: Build event-driven apps with Dapr on the Edge
languages:
- python
products:
- azure-iot
- azure-iot-operations
---

# Building an event driven app with Dapr

Learn how to aggregate data at the edge using IoT MQ and Dapr.

## Tutorial instructions

For detailed instructions on running this tutorial, follow [Build an event-driven app with Dapr](https://learn.microsoft.com/azure/iot-operations/develop/tutorial-event-driven-with-dapr).

## Building and deploying from source

1. To build the application container, execute the following:

    ```bash
    docker build src -t mq-event-driven-dapr
    ```

1. Import to the CodeSpaces cluster:

    ```bash
    k3d image import mq-event-driven-dapr
    ```

1. Install Dapr to the cluster:

    ```bash
    dapr init -k
    ```

1. Deploy the yaml:

    ```bash
    kubectl apply -f deploy.yaml
    ```
