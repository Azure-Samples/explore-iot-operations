# Microsoft Fabric Workspace – Export and Recreation Scripts

Two Bash scripts that use the [Microsoft Fabric REST API](https://learn.microsoft.com/rest/api/fabric/core) and the [Azure Data Explorer (Kusto) REST API](https://learn.microsoft.com/azure/data-explorer/kusto/api/rest/) to capture and replay the full configuration of a Fabric workspace, including:

- **Eventhouse** and its **KQL Databases** (tables, column schemas, ingestion mappings)
- **Eventstream** with Event Hubs source connection
- **Real-Time Dashboard** with tile layout and queries

## How it works

```
export-fabric-workspace.sh   →   snapshot.json   →   recreate-fabric-workspace.sh
       (reads existing)               (file)              (creates new workspace)
```

1. **Export** – connects to your existing workspace, pulls every resource definition via the Fabric API and the Kusto management API, and saves everything to `snapshot.json`
2. **Recreate** – reads `snapshot.json`, creates the workspace and all resources in the correct order, then runs the KQL table/mapping commands against the new cluster

## Prerequisites

| Requirement | Details |
|---|---|
| **Azure CLI** | Installed and authenticated (`az login`) |
| **curl** | HTTP client |
| **jq** | JSON processor (`sudo apt-get install jq`) |
| **Fabric capacity** | A Fabric capacity (F2+) must be available in your tenant |
| **Permissions** | Workspace Member or Admin role on the source workspace; capacity assignment rights for the target |

## Quick start

```bash
# 1. Log in to Azure
az login

# 2. Copy and edit the config file
cp sample-config.env my-config.env
# → set FABRIC_WORKSPACE_ID to your existing workspace

# 3. Export the existing workspace
chmod +x export-fabric-workspace.sh
./export-fabric-workspace.sh --config my-config.env
# → produces snapshot.json

# 4. Review the snapshot (optional)
jq '{workspace: .workspace.displayName, eventhouses: [.eventhouses[].displayName], kql_dbs: [.kql_databases[].displayName], eventstreams: [.eventstreams[].displayName], dashboards: [.realtime_dashboards[].displayName]}' snapshot.json

# 5. Dry-run the recreation to see what would be created
./recreate-fabric-workspace.sh --snapshot snapshot.json --dry-run

# 6. Recreate
chmod +x recreate-fabric-workspace.sh
./recreate-fabric-workspace.sh \
    --snapshot snapshot.json \
    --config   my-config.env
```

## Configuration reference

| Variable | Script | Required | Description |
|---|---|---|---|
| `FABRIC_WORKSPACE_ID` | export | **Yes** | Source workspace to export |
| `SNAPSHOT_FILE` | both | No | Snapshot path (default: `snapshot.json`) |
| `FABRIC_CAPACITY_ID` | recreate | Yes* | Capacity for the new workspace |
| `FABRIC_WORKSPACE_ID` | recreate | No | Reuse an existing workspace instead of creating one |
| `NEW_WORKSPACE_NAME` | recreate | **Yes** | Display name for the new workspace |
| `EVENTHUB_CONNECTION_STRING` | recreate | No† | Full SAS connection string — overrides the four individual fields below if set |
| `EVENTHUB_NAMESPACE` | recreate | No† | Namespace name only (without `.servicebus.windows.net`) |
| `EVENTHUB_ENTITY_PATH` | recreate | No† | Event Hub name (entity path) |
| `EVENTHUB_KEY_NAME` | recreate | No† | Shared-access policy name |
| `EVENTHUB_KEY` | recreate | No† | Shared-access key value |
| `EVENTHUB_CONSUMER_GROUP` | recreate | No | Consumer group (default: `$Default`) |
| `DRY_RUN` | recreate | No | `true` = print plan only |

\* Required when creating a new workspace; not needed if `FABRIC_WORKSPACE_ID` is set. `NEW_WORKSPACE_NAME` is always required.  
† To create a new Event Hub source connection, set either `EVENTHUB_CONNECTION_STRING` **or** all four of `EVENTHUB_NAMESPACE` + `EVENTHUB_ENTITY_PATH` + `EVENTHUB_KEY_NAME` + `EVENTHUB_KEY`. Without any of these the script reuses the connection ID from the snapshot (works within the same tenant; fails across tenants).

## What gets exported and recreated

### Eventhouse / KQL Database

The export script runs the following Kusto management commands:

| Command | Captures |
|---|---|
| `.show database ['<db>'] schema as json` | All tables, column names, and data types |
| `.show table * ingestion mappings` | All CSV/JSON/Avro/… ingestion mappings |

On recreation, tables are created with `.create-merge table` (idempotent) and mappings with `.create-or-alter table … ingestion … mapping`.

### Eventstream

The full item definition is exported via `POST /v1/workspaces/{id}/eventstreams/{id}/getDefinition`. This includes:
- Source node configuration (Event Hubs namespace, hub name, consumer group, serialization format)
- Destination node configuration
- Stream transformations

The Event Hubs **connection string / shared-access key** is a secret and is not stored in the Fabric API definition. Supply it at recreation time via `EVENTHUB_CONNECTION_STRING`, which is patched into the definition before the Eventstream is created.

### Real-Time Dashboard

The full dashboard definition is exported via `POST /v1/workspaces/{id}/items/{id}/getDefinition` and recreated verbatim (including all tiles, KQL queries, time ranges, and visual settings).

## Finding your Fabric Capacity ID

```bash
az fabric capacity list --query "[].{name:name, id:id, sku:sku.name, state:properties.state}" -o table
```

Or in the Azure portal: **Microsoft Fabric → Capacities → \<your capacity\> → Properties → Resource ID**

## Notes

- The scripts are idempotent in the sense that KQL objects use `.create-merge` and `.create-or-alter`; workspace and Fabric item creation may fail with a name conflict if the workspace already exists.
- Long-running Fabric API operations (HTTP 202) are automatically polled until completion.
- Kusto tokens are obtained per-cluster using `az account get-access-token --resource <cluster-uri>`. Make sure your account has at least *AllDatabasesViewer* on the source cluster and *AllDatabasesAdmin* on the target.
