# Plant Simulation Model — Fabrikam HMI-26

This folder documents the **recycling plant simulation model** for the HMI-26 demo and the customizations applied to the `edgemqttsim` module.

The simulator itself lives in the [shared module](../../modules/edgemqttsim/).

This folder does **not** copy those files. Instead it records:
- What the plant model represents (Fabrikam rHDPE recycling)
- What was changed from the default simulator configuration
- How to build and deploy the module for this environment
- The MQTT topic layout and asset definitions

---

## Plant Model: Fabrikam rHDPE Recycling Facility

The simulated plant represents the Fabrikam post-consumer plastics recycling facility — a 100 m × 40 m operation that processes collected plastic waste into production-ready recycled HDPE (rHDPE) pellets. It is modeled in the [`message_structure.yaml`](../../modules/edgemqttsim/message_structure.yaml) config and documented in [`HMI-fabrikam-data-spec.md`](../../modules/edgemqttsim/HMI-fabrikam-data-spec.md).

### Production Line and Equipment

Material flows through 18 stages from collection to finished pellet packaging:

| Stage | Equipment | MQTT topic |
|-------|-----------|------------|
| Collection | Smart bins, trucks | `fabrikam/collection`, `fabrikam/collection_transport` |
| Inbound identification | Feed scanner | `fabrikam/inbound_identification` |
| Feeding | Feed conveyor (FC-01) | `fabrikam/feeding` |
| Sorting | NIR optical sorters (NIR-01, NIR-02) | `fabrikam/sorting` |
| Primary size reduction | Shredder (SHR-01) | `fabrikam/primary_size_reduction` |
| Secondary size reduction | Granulator (GRN-01) | `fabrikam/secondary_size_reduction` |
| Pre-wash | Pre-wash tank (PW-01) | `fabrikam/pre_wash` |
| Friction wash | Friction washers (FW-01, FW-02) | `fabrikam/friction_wash` |
| Hot wash | Hot wash tank (HW-01) | `fabrikam/hot_wash` |
| Rinsing | Rinse tank (RW-01) | `fabrikam/rinsing` |
| Density separation | Float-sink separator (FS-01) | `fabrikam/density_separation` |
| Mechanical drying | Centrifugal dryer (CD-01) | `fabrikam/mechanical_drying` |
| Thermal drying | Thermal dryer (TD-01) | `fabrikam/thermal_drying` |
| Post-dry buffering | Collection bin (CB-EXTR-01) | `fabrikam/post_dry_buffering` |
| Extrusion | Extruders (EXT-01, EXT-02) | `fabrikam/extrusion` |
| Melt filtration | Screen changers (SC-01, SC-02) | `fabrikam/melt_filtration` |
| Pelletizing | Pelletizer (PEL-01) | `fabrikam/pelletizing` |
| Pellet screening | Pellet screener (PS-01) | `fabrikam/pellet_screening` |
| Packaging | Bagging station (PKG-01) | `fabrikam/packaging` |

### Key Design Decisions

- One simulated lot travels end-to-end in ~900 seconds (configurable in `message_structure.yaml`).
- Machine IDs follow `<TYPE>-<NN>` (e.g., `NIR-02`, `EXT-01`).
- All messages carry `lot_id` and `source_zone` to support full lineage tracing from collection bin to finished pellet.
- OEE (Availability, Performance, Quality) is derivable from raw telemetry — no pre-aggregation.
- The PKG station emits colour scan readings (RGB) used by the Colour Quality Ops Agent to detect blue-tint contamination.

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
| `HMI-fabrikam-data-spec.md` | Full payload schema for all machine types and stages |

---

## HMI-26 Customizations

Record changes made to the default `edgemqttsim` config for this environment below.

### `message_structure.yaml` changes

<!--
  Document any tweaks to stage weights, machine counts, lot duration, or anomaly seed.
  Example:
  - Reduced total_duration_sec from 900 to 600 for faster demo cycles
  - Increased contamination probability at sorting stage to make blue-tint events more frequent
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

- [HMI-fabrikam-data-spec.md](../../modules/edgemqttsim/HMI-fabrikam-data-spec.md) — full payload schema for all stages
- [Foundry Local](../foundry-local/README.md) — on-cluster AI for quality ops and contamination detection
- [Omniverse](../omniverse/README.md) — digital twin visualization of this plant
