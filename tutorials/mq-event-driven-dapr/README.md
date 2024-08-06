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

Learn how to aggregate data at the edge using Azure IoT Operations and Dapr.

## Tutorial instructions

For detailed instructions on running this tutorial, follow [Build an event-driven app with Dapr](https://learn.microsoft.com/azure/iot-operations/develop/tutorial-event-driven-with-dapr).

## Building and deploying from source

1. Build the application and push the container to the cluster:

    ```bash
    docker build . -t mq-event-driven-dapr
    k3d image import mq-event-driven-dapr
    ```

1. Deploy dapr and the app:

    ```bash
    dapr init -k
    kubectl apply -f app.yaml
    ```
