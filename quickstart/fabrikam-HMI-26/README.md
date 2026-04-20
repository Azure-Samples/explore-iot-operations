# Fabrikam HMI-26 Demo

This folder contains the documentation, configuration, and scripts specific to the **Fabrikam HMI-26** demo environment — a post-consumer plastics recycling plant (rHDPE) running Azure IoT Operations with Foundry Local, Microsoft Fabric, and NVIDIA Omniverse integration.

This is a customized layer on top of the base `explore-iot-operations` quickstart. It does **not** duplicate the base solution; instead it records what is different, what was configured, and how the demo-specific components connect.

## Architecture Overview

```
Edge Device (K8s cluster)
  └── Azure IoT Operations
        ├── edgemqttsim (recycling plant telemetry → MQTT broker)
        ├── MQTT Broker (aio-broker)
        ├── Dataflow pipelines → Azure
        └── Foundry Local (on-cluster AI inference, deployed via Helm)

Workstation
  └── NVIDIA Omniverse  (digital twin / visualization)

Azure
  └── Microsoft Fabric  (data pipelines & analytics)
```

## Folder Structure

| Folder | Contents |
|--------|----------|
| [factory-model/](factory-model/) | Recycling plant simulation spec and edgemqttsim customizations |
| [foundry-local/](foundry-local/) | Foundry Local setup, model configuration, and agent prompts |
| [fabric-connectors/](fabric-connectors/) | Fabric Real-Time Intelligence connector docs and dataflow references |
| [omniverse/](omniverse/) | Omniverse USD stage spec, connector config, and setup scripts |
| [scripts/](scripts/) | Fix-it scripts and one-offs that solve HMI-26-specific issues |

## Prerequisites

This demo builds on the base quickstart. Complete the base install before applying HMI-26 customizations:

- [Base quickstart README](../readme.md)
- [Advanced config](../README_ADVANCED.md)
- Config file: `../config/aio_config.json` (resource group `<your-resource-group>`, cluster `<your-cluster-name>`)

## Getting Started

1. Complete the base Azure IoT Operations install (Path A or Path B from the base readme).
2. Deploy the edgemqttsim module — see [factory-model/README.md](factory-model/README.md).
3. Set up Foundry Local — see [foundry-local/README.md](foundry-local/README.md).
4. Configure Fabric connectors — see [fabric-connectors/README.md](fabric-connectors/README.md).
5. Connect Omniverse — see [omniverse/README.md](omniverse/README.md).
6. Any environment-specific fixes are in [scripts/](scripts/).
