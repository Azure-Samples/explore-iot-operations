# Factory Model — Fabrikam HMI-26

This folder documents the **factory simulation model** for the HMI-26 demo and the customizations applied to the `edgemqttsim` module.

The simulator itself lives in the [shared module](../../modules/edgemqttsim/).

This folder does **not** copy those files. Instead it records:
- What the factory model represents (Fabrikam spaceship parts)
- What was changed from the default simulator configuration
- How to build and deploy the module for this environment
- The MQTT topic layout and asset definitions

---

## Factory Model: Fabrikam Spaceship Parts Plant

The simulated factory represents a Fabrikam facility that manufactures and assembles spaceship components. It is modeled in the [`message_structure.yaml`](../../modules/edgemqttsim/message_structure.yaml) config and documented in [`Factory_Simulation_Spec.md`](../../modules/edgemqttsim/Factory_Simulation_Spec.md).

### Factory Lines and Equipment

| Equipment | Count | Topics |
|-----------|-------|--------|
| CNC Machines | 5 | `factory/cnc` |
| 3D Printers | 8 | `factory/3dprinter` |
| Welding Stations | 4 | `factory/welding` |
| Painting Booths | 3 | `factory/painting` |
| Testing Rigs | 2 | `factory/testing` |
| Customer Orders | — | `factory/orders` |
| Dispatch Events | — | `factory/dispatch` |

### Key Design Decisions

- Messages are sent at ~1 msg/sec aggregate across all machines.
- Machine IDs follow `<TYPE>-<NN>` (e.g., `CNC-01`, `3DP-03`).
- Stations follow `LINE-{n}-STATION-A` pattern.
- Quality distribution: 95 % `good`, 5 % `scrap` (tunable in `message_structure.yaml`).
- OEE (Availability, Performance, Quality) is derivable from the raw telemetry — no pre-aggregation.

---

## edgemqttsim Module Reference

Source: [`quickstart/modules/edgemqttsim/`](../../modules/edgemqttsim/)

Key files:

| File | Purpose |
|------|---------|
| `app.py` | Main MQTT client — connects to `aio-broker`, drives message loop |
| `messages.py` | Message generation logic per equipment type |
| `message_structure.yaml` | Tune frequencies, machine counts, quality distributions |
| `deployment.yaml` | K8s deployment — update `image:` field to your ACR |
| `Dockerfile` | Build image for ACR push |
| `mqtt-asset-endpoint.yaml` | Azure IoT Operations Asset Endpoint Profile for the simulator |
| `mqtt-asset-example.yaml` | Example Azure IoT Operations Asset definition |
| `arm_asset_creation.py` | Helper to create Azure IoT Operations assets via ARM API |
| `deploy-mqtt-assets.sh` | Shell wrapper for asset creation |
| `Factory_Simulation_Spec.md` | Full payload schema for all message types |

---

## HMI-26 Customizations

Record changes made to the default `edgemqttsim` config for this environment below.

### `message_structure.yaml` changes

<!-- 
  Document any tweaks to machine counts, frequencies, or part types.
  Example:
  - Increased `cnc` machine count from 5 → 8 to match HMI-26 floor plan
  - Added custom part_type `ThrusterNozzle` to cnc_machine section
-->

_No customizations recorded yet. Update this section as changes are made._

### `deployment.yaml` changes

| Setting | Value | Notes |
|---------|-------|-------|
| `image` | `<your-acr-name>.azurecr.io/edgemqttsim:latest` | HMI-26 ACR |
| `MQTT_BROKER` | `aio-broker.azure-iot-operations.svc.cluster.local` | Do not change |
| `MQTT_PORT` | `18883` | MQTTS |

---

## Building and Deploying

### 1. Build and push the image

```bash
# From quickstart/modules/edgemqttsim/
docker build -t <your-acr-name>.azurecr.io/edgemqttsim:latest .
az acr login --name <your-acr-name>
docker push <your-acr-name>.azurecr.io/edgemqttsim:latest
```

### 2. Deploy to cluster

```bash
# From quickstart/modules/edgemqttsim/
kubectl apply -f deployment.yaml
```

The [`Deploy-EdgeModules.ps1`](../../external_configuration/Deploy-EdgeModules.ps1) script automates ACR credential setup and deployment. Run it from the Windows management machine after the base Azure IoT Operations install.

### 3. Verify

```bash
kubectl logs -l app=edgemqttsim -f
# Expect: "Published: factory/cnc ..." messages every second
```

---

## MQTT Asset Definitions

Azure IoT Operations Asset resources map the simulator's MQTT streams into the IoT Operations asset model. The base templates are in the [shared module](../../modules/edgemqttsim/):

- [`mqtt-asset-endpoint.yaml`](../../modules/edgemqttsim/mqtt-asset-endpoint.yaml) — defines the MQTT source endpoint
- [`mqtt-asset-example.yaml`](../../modules/edgemqttsim/mqtt-asset-example.yaml) — example asset for a single machine type

HMI-26-specific asset YAML files should be added to this folder when created.

---

## Related

- [Factory_Simulation_Spec.md](../../modules/edgemqttsim/Factory_Simulation_Spec.md) — full payload schema
- [Foundry Local](../foundry-local/README.md) — AI inference layer on top of this telemetry
- [Omniverse](../omniverse/README.md) — digital twin visualization of this factory
