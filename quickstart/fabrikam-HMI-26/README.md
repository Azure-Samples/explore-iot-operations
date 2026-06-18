# Fabrikam HMI-26 Demo

This folder is a demo overlay on the base `explore-iot-operations` quickstart, showing an end-to-end industrial IoT solution for the Fabrikam rHDPE post-consumer plastics recycling facility — a 100 m × 40 m, 18-stage production line that uses Azure IoT Operations to stream live plant telemetry from the edge, Foundry Local (on-cluster) for real-time AI quality ops, Microsoft Fabric for analytics and dashboards, and NVIDIA Omniverse for a live digital twin of the plant floor.

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

---

## References

### Azure IoT Operations

- [Deploy Azure IoT Operations](https://learn.microsoft.com/azure/iot-operations/deploy-iot-ops/howto-deploy-iot-operations) — full install guide for the base platform
- [Azure IoT Operations overview](https://learn.microsoft.com/azure/iot-operations/overview-iot-operations)
- [Arc-enable a Kubernetes cluster](https://learn.microsoft.com/azure/azure-arc/kubernetes/quickstart-connect-cluster) — prerequisite for IoT Operations deployment
- [Connect to an Arc-enabled cluster (proxy)](https://learn.microsoft.com/azure/azure-arc/kubernetes/cluster-connect) — how to use `az connectedk8s proxy` for kubectl access

### Foundry Local

- [Foundry Local overview](https://learn.microsoft.com/azure/ai-foundry/foundry-local/overview)
- [Microsoft Agent Framework](https://learn.microsoft.com/azure/ai-foundry/agents/overview)

### Microsoft Fabric

- [Fabric Real-Time Intelligence overview](https://learn.microsoft.com/fabric/real-time-intelligence/overview)

### NVIDIA Omniverse

- [NVIDIA Omniverse documentation](https://docs.omniverse.nvidia.com/)
