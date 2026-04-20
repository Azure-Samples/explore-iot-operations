# Omniverse Integration — Fabrikam HMI-26

This folder contains the specification files, connector configuration, and setup scripts for the **NVIDIA Omniverse** digital twin integration of the HMI-26 factory floor.

Omniverse consumes live telemetry from the IoT Operations MQTT broker (or via Fabric) and drives the digital twin visualization in real time.

---

## Architecture

```
IoT Operations MQTT Broker
  └── Omniverse Connector (MQTT → USD Live)
        └── Omniverse Nucleus (USD stage server)
              └── Omniverse USD Composer / Isaac Sim
                    └── Fabrikam HMI-26 Stage
```

---

## Spec Files

| File | Description |
|------|-------------|
| [`stage-layout.yaml`](stage-layout.yaml) | USD stage hierarchy and prim paths for factory equipment |
| [`telemetry-bindings.yaml`](telemetry-bindings.yaml) | Maps MQTT topic fields → USD prim attributes |
| [`connector-config.json`](connector-config.json) | Omniverse Connector endpoint and auth configuration |

---

## Setup

### 1. Install Omniverse Launcher

Download from [https://www.nvidia.com/en-us/omniverse/](https://www.nvidia.com/en-us/omniverse/) and install Omniverse Launcher.

From the launcher, install:
- **Nucleus** (local or enterprise server)
- **USD Composer** (for stage editing)
- The **IoT Connector** extension (or a custom connector — see [`scripts/start-omniverse-connector.ps1`](../scripts/start-omniverse-connector.ps1))

### 2. Configure the connector

Edit [`connector-config.json`](connector-config.json) with your Nucleus server address and MQTT broker details, then run:

```powershell
# From the omniverse/ folder
..\scripts\start-omniverse-connector.ps1
```

### 3. Open the stage

In USD Composer or Isaac Sim, open:

```
omniverse://localhost/Projects/fabrikam-hmi26/factory_floor.usd
```

The stage will auto-populate machine prims from [`stage-layout.yaml`](stage-layout.yaml).

---

## Telemetry Binding Overview

The connector translates incoming MQTT JSON into USD attribute writes on the corresponding machine prims.

Example mapping (from `telemetry-bindings.yaml`):

```
MQTT topic: fabrikam/packaging
  $.machine_id          → prim path  /World/Plant/Packaging/${machine_id}
  $.run_state           → attribute  state:status         (token)
  $.colour_r            → attribute  metrics:colourR      (int)
  $.colour_g            → attribute  metrics:colourG      (int)
  $.colour_b            → attribute  metrics:colourB      (int)
  $.quality_classification → attribute  state:colourQuality  (token)
```

Status values drive material variant switching (green = running, amber = idle, red = faulted).

---

## References

### How to do this yourself

#### NVIDIA Omniverse

- [NVIDIA Omniverse documentation](https://docs.omniverse.nvidia.com/)
- [Omniverse Launcher download](https://www.nvidia.com/en-us/omniverse/download/) — install Nucleus, USD Composer, and extensions
- [Omniverse USD Composer](https://docs.omniverse.nvidia.com/composer/latest/index.html)
- [Omniverse IoT Connector extension](https://docs.omniverse.nvidia.com/extensions/latest/ext_iot-connector.html) — the bridge that reads MQTT and writes USD attributes
- [OpenUSD reference](https://openusd.org/release/index.html) — USD prim and attribute concepts used in `stage-layout.yaml`
- [USD Live sync overview](https://docs.omniverse.nvidia.com/usd/latest/usd_tutorials/usd_live_sync.html) — how attribute writes propagate to connected viewports

#### Azure IoT Operations

- [IoT Operations MQTT Broker overview](https://learn.microsoft.com/azure/iot-operations/manage-mqtt-broker/overview-broker)
- [Expose MQTT broker outside the cluster](https://learn.microsoft.com/azure/iot-operations/manage-mqtt-broker/howto-configure-brokerlistener) — NodePort/LoadBalancer config needed for the Omniverse connector on a Windows workstation
