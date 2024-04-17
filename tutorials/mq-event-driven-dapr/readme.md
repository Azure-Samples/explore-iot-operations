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

## Building

To build the application container, execute the following:

```bash
cd src
docker build . -t mq-event-driven-dapr
```

