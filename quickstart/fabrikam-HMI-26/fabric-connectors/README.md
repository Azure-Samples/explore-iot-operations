# Fabric Connectors — Fabrikam HMI-26

This folder documents how Azure IoT Operations dataflow pipelines deliver factory telemetry into **Microsoft Fabric** for analytics, dashboards, and AI enrichment.

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

### Pipeline 1 — Factory Telemetry → Event Hub

Forwards all `factory/#` MQTT messages to Azure Event Hubs in near-real-time.

| Setting | Value |
|---------|-------|
| Source | MQTT topic `factory/#` |
| Destination | Event Hub namespace in `<your-resource-group>` |
| Auth | Managed Identity (no secrets) |
| Serialization | JSON passthrough |

The Event Hub name and namespace are configured in `aio_config.json`. The dataflow is deployed by `External-Configurator.ps1`.

### Pipeline 2 — OEE-enriched stream → Eventhouse

After Foundry Local enrichment (anomaly labels, OEE scores), a second dataflow writes enriched records to the Fabric Eventhouse.

| Setting | Value |
|---------|-------|
| Source | Internal MQTT topic `factory/enriched/#` |
| Destination | Fabric Eventhouse via Eventstream |
| KQL table | `factory_telemetry` |

---

## Microsoft Fabric Setup

### 1. Create a Fabric workspace

In the Fabric portal, create a workspace named `fabrikam-hmi26` (or link to an existing one).

### 2. Eventstream — connect Event Hub

1. In the workspace, create a new **Eventstream**.
2. Add a source: **Azure Event Hub** → select the hub from `<your-resource-group>`.
3. Add a destination: **Eventhouse** → create or select a KQL database.

### 3. KQL Database (Eventhouse)

Suggested table schema for `factory_telemetry`:

```kusto
.create table factory_telemetry (
    timestamp: datetime,
    machine_id: string,
    station_id: string,
    equipment_type: string,
    status: string,
    part_type: string,
    part_id: string,
    cycle_time: real,
    quality: string,
    oee_availability: real,
    oee_performance: real,
    oee_quality: real
)
```

Ingestion mapping (JSON → columns):

```kusto
.create table factory_telemetry ingestion json mapping 'factory_telemetry_mapping'
'['
'  {"column":"timestamp","path":"$.timestamp","datatype":"datetime"},'
'  {"column":"machine_id","path":"$.machine_id","datatype":"string"},'
'  {"column":"station_id","path":"$.station_id","datatype":"string"},'
'  {"column":"equipment_type","path":"$.equipment_type","datatype":"string"},'
'  {"column":"status","path":"$.status","datatype":"string"},'
'  {"column":"part_type","path":"$.part_type","datatype":"string"},'
'  {"column":"part_id","path":"$.part_id","datatype":"string"},'
'  {"column":"cycle_time","path":"$.cycle_time","datatype":"real"},'
'  {"column":"quality","path":"$.quality","datatype":"string"}'
']'
```

### 4. Power BI Real-Time Dashboard

Connect a Power BI report directly to the KQL database. Recommended visuals:

- **OEE Gauge** — overall plant OEE (last 1 hour)
- **Machine Status Grid** — color-coded by `status` field
- **Scrap Rate Trend** — quality % over time per machine type
- **Cycle Time Histogram** — per equipment type

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

- [IoT Operations Dataflow documentation](https://learn.microsoft.com/azure/iot-operations/connect-to-cloud/overview-dataflow)
- [Fabric Eventstream docs](https://learn.microsoft.com/fabric/real-time-intelligence/eventstream/overview)
- [Fabric Real-Time Intelligence overview](https://learn.microsoft.com/fabric/real-time-intelligence/overview)
- [KQL quick reference](https://learn.microsoft.com/azure/data-explorer/kql-quick-reference)
