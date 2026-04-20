# Fabric Connectors — Fabrikam HMI-26

This folder documents how Azure IoT Operations dataflow pipelines deliver recycling plant telemetry into **Microsoft Fabric** for analytics, dashboards, and AI enrichment.

No ARM templates are stored here — those live in the base quickstart [`arm_templates/`](../../arm_templates/). This doc records the HMI-26-specific dataflow topology and what to configure in each Fabric service.

---

## Architecture

```
IoT Operations MQTT Broker (edge)
  └── IoT Operations Dataflow Pipeline
        ├── → Event Hub (ingestion)
        │     └── Fabric Eventstream → Eventhouse (KQL)
        │           └── Power BI Real-Time Dashboard
        └── → Fabric Lakehouse (batch / cold path)
              └── Notebooks → ML / OEE reports
```

---

## Dataflow Pipelines

### Pipeline 1 - Recycling Plant Telemetry -> Event Hub

Forwards all `fabrikam/#` MQTT messages to Azure Event Hubs in near-real-time.

| Setting | Value |
|---------|-------|
| Source | MQTT topic `fabrikam/#` |
| Destination | Event Hub namespace in `<your-resource-group>` |
| Auth | Managed Identity (no secrets) |
| Serialization | JSON passthrough |

The Event Hub name and namespace are configured in `aio_config.json`. The dataflow is deployed by `External-Configurator.ps1`.

### Pipeline 2 - Quality-enriched stream -> Eventhouse

After Foundry Local enrichment (colour quality classification, contamination scores), a second dataflow writes enriched records to the Fabric Eventhouse.

| Setting | Value |
|---------|-------|
| Source | Internal MQTT topic `fabrikam/enriched/#` |
| Destination | Fabric Eventhouse via Eventstream |
| KQL table | `plant_telemetry` |

---

## Microsoft Fabric Setup

### 1. Create a Fabric workspace

In the Fabric portal, create a workspace named `fabrikam-hmi26` (or link to an existing one).

### 2. Eventstream — connect Event Hub

1. In the workspace, create a new **Eventstream**.
2. Add a source: **Azure Event Hub** → select the hub from `<your-resource-group>`.
3. Add a destination: **Eventhouse** → create or select a KQL database.

### 3. KQL Database (Eventhouse)

Suggested table schema for `plant_telemetry`:

```kusto
.create table plant_telemetry (
    timestamp: datetime,
    machine_id: string,
    process_stage: string,
    lot_id: string,
    source_zone: string,
    source_bin_id: string,
    throughput_kg_hr: real,
    oee_availability: real,
    oee_performance: real,
    oee_quality: real,
    contamination_ppm: real,
    separation_purity_pct: real,
    pellet_size_p50_mm: real,
    colour_r: int,
    colour_g: int,
    colour_b: int,
    quality_classification: string
)
```

Ingestion mapping (JSON -> columns):

```kusto
.create table plant_telemetry ingestion json mapping 'plant_telemetry_mapping'
'['
'  {"column":"timestamp","path":"$.timestamp","datatype":"datetime"},'
'  {"column":"machine_id","path":"$.machine_id","datatype":"string"},'
'  {"column":"process_stage","path":"$.process_stage","datatype":"string"},'
'  {"column":"lot_id","path":"$.lot_id","datatype":"string"},'
'  {"column":"source_zone","path":"$.source_zone","datatype":"string"},'
'  {"column":"throughput_kg_hr","path":"$.throughput_kg_hr","datatype":"real"},'
'  {"column":"contamination_ppm","path":"$.contamination_ppm","datatype":"real"},'
'  {"column":"quality_classification","path":"$.quality_classification","datatype":"string"}'
']'
```

### 4. Power BI Real-Time Dashboard

Connect a Power BI report directly to the KQL database. Recommended visuals:

- **OEE Gauge** - overall plant OEE (last 1 hour)
- **Machine Status Grid** - colour-coded by `process_stage` and machine status
- **Throughput Trend** - kg/hr across the production line over time
- **Contamination Rate** - contamination_ppm trend per sorting/wash stage
- **Pellet Quality Trend** - colour scan RGB readings at PKG-01; highlight blue-tint events
- **Lot Lineage View** - trace `lot_id` from source bin/zone through all 18 stages to packaged output

---

## Managed Identity Permissions

The IoT Operations cluster's managed identity needs the following roles:

| Role | Scope |
|------|-------|
| `Azure Event Hubs Data Sender` | Event Hub namespace |
| `Storage Blob Data Contributor` | Storage account (for Lakehouse cold path) |

These are granted by `grant_entra_id_roles.ps1` in the base quickstart. Confirm with:

```powershell
az role assignment list --assignee <cluster-managed-identity-object-id> --output table
```

---

## Troubleshooting

| Symptom | Check |
|---------|-------|
| No data in Eventhouse | Verify dataflow is `Running` in the IoT Operations portal; check Event Hub metrics |
| Auth errors in dataflow | Re-run `grant_entra_id_roles.ps1`; confirm managed identity object ID |
| Timestamps wrong in KQL | Ensure `timestamp` field is ISO 8601 UTC in the MQTT payload |
| Eventstream lag > 30 s | Check Event Hub partition count; scale up if needed |

---

## References

### How to do this yourself

- [IoT Operations Dataflow overview](https://learn.microsoft.com/azure/iot-operations/connect-to-cloud/overview-dataflow) — how dataflow pipelines work
- [Configure an Event Hubs dataflow destination](https://learn.microsoft.com/azure/iot-operations/connect-to-cloud/howto-configure-destination-event-hubs) — step-by-step for the MQTT → Event Hub pipeline
- [Fabric Eventstream overview](https://learn.microsoft.com/fabric/real-time-intelligence/eventstream/overview)
- [Add Azure Event Hubs as an Eventstream source](https://learn.microsoft.com/fabric/real-time-intelligence/eventstream/add-source-azure-event-hubs) — wire Event Hub output into Fabric
- [Fabric Eventhouse overview](https://learn.microsoft.com/fabric/real-time-intelligence/eventhouse) — the KQL database that stores `plant_telemetry`
- [Fabric Real-Time Intelligence overview](https://learn.microsoft.com/fabric/real-time-intelligence/overview)
- [KQL quick reference](https://learn.microsoft.com/azure/data-explorer/kql-quick-reference)
- [Grant managed identity RBAC for Event Hubs](https://learn.microsoft.com/azure/event-hubs/authenticate-managed-identity) — required for the dataflow managed identity auth
