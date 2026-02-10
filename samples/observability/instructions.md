# Azure IoT Operations Unified Observability Dashboard

A comprehensive Grafana dashboard for monitoring Azure IoT Operations (AIO) deployments, combining Prometheus metrics with Azure Log Analytics logs in a single unified view.

![Grafana](https://img.shields.io/badge/Grafana-11.x-orange)
![Azure IoT Operations](https://img.shields.io/badge/Azure%20IoT%20Operations-1.x-blue)

## Overview

This dashboard provides end-to-end observability for Azure IoT Operations running on Arc-enabled Kubernetes clusters. It consolidates metrics and logs from all AIO components into a single pane of glass, enabling operators to:

- **Monitor health** of all AIO services at a glance
- **Troubleshoot issues** with integrated logs alongside metrics
- **Track performance** of brokers, dataflows, and connectors
- **Observe Kubernetes infrastructure** health and resource usage

## Dashboard Sections

| Section | Description |
|---------|-------------|
| **📊 Health Overview** | State-timeline panels showing health status of Broker, Dataflow, Kubernetes Workloads, and Nodes |
| **🔌 Broker (MQTT)** | MQTT broker metrics including sessions, subscriptions, latency, auth failures, backpressure, and logs |
| **📡 Dataflow** | Pipeline metrics for message throughput, latency, errors, and pipeline logs |
| **🔧 OPC-UA Connector** | OPC-UA connector metrics for datapoints, endpoints, MQTT publishing, and connector logs |
| **📚 Schema Registry** | Schema registry request rates and errors |
| **📊 Observability Pipeline (OTel)** | OpenTelemetry collector metrics for export rates and failures |
| **☸️ Kubernetes Infrastructure** | Node resources (CPU, memory, disk), pod health, restarts, and Kubernetes events |
| **🚨 Troubleshooting** | Full log tables for error/warning logs and all AIO component logs |

## Prerequisites

### Observability Services

   Before using this dashboard, you must deploy the observability services for Azure IoT Operations. Follow the official guide:

   - [Configure observability and
  monitoring](https://learn.microsoft.com/en-us/azure/iot-operations/configure-observability-monitoring/howto-configure-observability)

   This enables metrics collection and log forwarding required for the dashboard panels.

### Data Sources Required

1. **Prometheus / Azure Managed Prometheus**
   - Must be scraping AIO metrics from your cluster
   - Configure the datasource during import

2. **Azure Monitor (Log Analytics)**
   - Workspace must be receiving container logs from your AIO cluster
   - Configure the datasource during import
   - **Important**: You must provide your Azure Subscription ID in the dashboard's `subscriptionId` variable for log queries to work

### Metrics Collection

Ensure your cluster has metrics collection enabled:

```bash
# Verify AIO metrics are being scraped
kubectl get pods -n azure-iot-operations -l app.kubernetes.io/component=prometheus
```

### Logs Collection

Container logs must be flowing to Azure Log Analytics. Verify with:

```bash
# Check if Container Insights is enabled
az k8s-extension show --name azuremonitor-containers \
  --cluster-name <cluster-name> \
  --resource-group <rg-name> \
  --cluster-type connectedClusters
```

## Installation

### Import via Grafana UI

1. In Grafana, go to **Dashboards** → **Import**
2. Upload the `aio-unified-observability-dashboard.json` file or paste the JSON content
3. Select your Prometheus and Azure Monitor datasources
4. Click **Import**


## Configuration

### Template Variables

After importing, configure these variables at the top of the dashboard:

| Variable | Type | Description |
|----------|------|-------------|
| `DS_PROMETHEUS` | Datasource | Select your Prometheus or Azure Managed Prometheus datasource |
| `DS_AZURE_MONITOR` | Datasource | Select your Azure Monitor datasource |
| `cluster` | Query | Auto-populated from Prometheus - select your AIO cluster |
| `namespace` | Query | Auto-populated - filter by namespace (default: all AIO namespaces) |
| `subscriptionId` | Text | **Manual entry required** - Your Azure subscription ID for Log Analytics queries |


## Usage

### Health Overview

The top section shows color-coded health status:
- 🟢 **Green** = Healthy (value = 1)
- 🟡 **Yellow** = Degraded (value = 0.5)
- 🔴 **Red** = Unhealthy (value = 0)
- ⚫ **Gray** = No data (value = 404)

### Drilling Down

1. **Start with Health Overview** - Identify which component has issues
2. **Expand the relevant section** - Click on row headers to expand/collapse
3. **Check metrics panels** - Look for anomalies in throughput, latency, errors
4. **Review logs** - Each section has integrated logs for that component
5. **Use Troubleshooting section** - For cross-component error analysis

### Time Range

- Use the time picker (top right) to adjust the viewing window
- Recommended: Start with "Last 1 hour" for initial troubleshooting
- Use "Last 15 minutes" for real-time monitoring

### Filtering

- Use the `cluster` variable to select your AIO cluster
- Use the `namespace` variable to focus on specific AIO namespaces
- Logs automatically filter to the selected cluster and time range

## Metrics Reference

### Broker Metrics

| Panel | Metric | Description |
|-------|--------|-------------|
| Total Sessions | `aio_broker_store_total_sessions` | Total MQTT client sessions (connected + offline) |
| Total Subscriptions | `aio_broker_store_subscriptions` + `aio_broker_store_shared_subscriptions` | Total topic subscriptions including shared |
| Inbound Messages/s | `aio_broker_publishes_received` | Rate of messages received by broker |
| Outbound Messages/s | `aio_broker_publishes_sent` | Rate of messages sent by broker |
| Avg Connect Latency | `aio_broker_connect_latency_mu_ms` | Average MQTT connect latency (ms) |
| Avg Publish Latency | `aio_broker_publish_latency_mu_ms` | Average MQTT publish latency (ms) |
| Authentication Failure Rate | `aio_broker_authentication_failures` | Rate of authentication failures by category |
| Authorization Failure Rate | `aio_broker_authorization_deny` | Rate of authorization denials by category |
| Backpressure Rejection % | `aio_broker_backpressure_packets_rejected_memory`, `aio_broker_backpressure_packets_rejected_disk` | Percentage of packets rejected due to backpressure |
| Message Throughput | `aio_broker_publishes_received`, `aio_broker_publishes_sent` | Messages in/out over time |
| Message Throughput (Bytes) | `aio_broker_payload_bytes_received`, `aio_broker_payload_bytes_sent` | Bytes in/out over time |

### Broker Health Metrics

| Metric | Description |
|--------|-------------|
| `aio_broker_connect_route_replication_correctness` | Connect route replication health |
| `aio_broker_publish_route_replication_correctness` | Publish route replication health |
| `aio_broker_subscribe_route_replication_correctness` | Subscribe route replication health |
| `aio_broker_message_delivery_check_total_timeouts` | Message delivery timeout tracking |
| `aio_broker_ping_correctness` | Broker ping health |

### Dataflow Metrics

| Panel | Metric | Description |
|-------|--------|-------------|
| Active Pipelines | `aio_dataflow_active_dataflows` | Count of running dataflow pipelines |
| Dataflow Graphs | `aio_dataflow_graphs` | Dataflow graph count |
| Graph Modules | `aio_dataflow_graph_modules` | Number of graph modules |
| Graph Errors | `aio_dataflow_graph_errors` | Errors in output stages |
| Dataflow Errors/s | `aio_dataflow_errors` | Rate of pipeline errors |
| P95 E2E Latency | `aio_dataflow_processing_latency_bucket` | 95th percentile end-to-end processing time |
| Dataflow Throughput | `aio_dataflow_messages_received`, `aio_dataflow_messages_sent` | Messages in/out over time |
| Dataflow Throughput (Bytes) | `aio_dataflow_bytes_received`, `aio_dataflow_bytes_sent` | Bytes in/out over time |
| Messages Dropped | `aio_dataflow_messages_dropped_processing_errors`, `aio_dataflow_messages_dropped_when_busy`, `aio_dataflow_messages_expired`, `aio_dataflow_messages_filtered` | Messages dropped by reason |
| Pipeline Error Rate | `aio_dataflow_errors` | Error rate by error code and asset |

### OPC-UA Connector Metrics

| Panel | Metric | Description |
|-------|--------|-------------|
| Datapoints | `aio_opc_asset_datapoint_count` | Monitored OPC-UA datapoints |
| Endpoints | `aio_opc_endpoint_count` | Connected OPC-UA endpoints |
| Messages Published/s | `aio_opc_mqtt_message_publishing_duration_count` | Successful MQTT publish rate |
| MQTT Publish Latency P95 | `aio_opc_mqtt_message_publishing_duration_bucket` | 95th percentile MQTT publish latency |
| Publish Errors/s | `aio_opc_mqtt_message_publishing_duration_count` (filtered) | MQTT publish error rate |
| MQTT Publishing Rate | `aio_opc_mqtt_message_publishing_duration_count` | Success vs error publishing rate |
| OPC-UA Session Connections | `aio_opc_session_connect_duration_count` | Session connection success/failure rate |

### Schema Registry Metrics

| Panel | Metric | Description |
|-------|--------|-------------|
| Schema Registry Requests/s | `aio_schema_registry_requests` | Request rate to schema registry |
| Schema Registry Errors/s | `aio_schema_registry_errors` | Error rate from schema registry |

### OpenTelemetry Metrics

| Panel | Metric | Description |
|-------|--------|-------------|
| OTel Metrics Exported/s | `otelcol_exporter_sent_metric_points` | Metrics successfully exported |
| OTel Export Failures/s | `otelcol_exporter_send_failed_metric_points` | Failed metric exports |

### Kubernetes Infrastructure Metrics

| Panel | Metric | Description |
|-------|--------|-------------|
| Node CPU % | `node_cpu_seconds_total` | Average node CPU utilization |
| Node Memory % | `node_memory_MemAvailable_bytes`, `node_memory_MemTotal_bytes` | Average node memory utilization |
| Node Disk % | `node_filesystem_avail_bytes`, `node_filesystem_size_bytes` | Average node disk utilization (root mount) |
| AIO Pods | `kube_pod_info` | Count of pods in AIO namespaces |
| Pod Restarts (1h) | `kube_pod_container_status_restarts_total` | Total container restarts in last hour |
| Unhealthy Pods | `kube_pod_status_phase` | Pods not in Running/Succeeded state |
| Node Resource Usage | `node_cpu_seconds_total`, `node_memory_*`, `node_filesystem_*` | CPU, memory, disk over time |
| Pod Restarts by Pod | `kube_pod_container_status_restarts_total` | Restart count per pod |

## Log Queries Reference

The dashboard includes integrated log panels using Azure Log Analytics (KQL):

| Panel | Log Table | Filter |
|-------|-----------|--------|
| Broker Logs | `ContainerLogV2` | `PodName startswith "aio-broker"` |
| Dataflow Logs | `ContainerLogV2` | `PodName startswith "aio-dp-" or "aio-dataflow"` |
| OPC-UA Connector Logs | `ContainerLogV2` | `PodName startswith "aio-opc"` |
| Kubernetes Events | `KubeEvents` | `Namespace startswith "azure-iot-operations"` |
| Error & Warning Logs | `ContainerLogV2` | `LogLevel in ("error", "warning", ...)` |
| All AIO Logs | `ContainerLogV2` | `PodNamespace startswith "azure-iot-operations"` |

## Troubleshooting

### "No Data" in Panels

1. **Check datasource connection**: Go to Settings → Datasources and test both Prometheus and Azure Monitor
2. **Verify cluster variable**: Ensure your cluster is selected in the dropdown
3. **Check time range**: Some metrics may not exist for the selected period
4. **Verify metrics exist**: Use Grafana Explore to query raw metrics

### Log Panels Show Error

1. **Enter Subscription ID**: The `subscriptionId` variable must be set
2. **Check permissions**: Ensure your Azure credentials have Log Analytics Reader access
3. **Verify Log Analytics workspace**: Confirm logs are flowing to the workspace

### Health Panels Show Gray

Gray (404) indicates the metric doesn't exist or no data is available. This is normal if:
- The component isn't deployed (e.g., OPC-UA connector)
- The cluster was recently created and hasn't generated metrics yet

## Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test with a real AIO cluster
5. Submit a pull request


## Support

- **Azure IoT Operations Documentation**: [Microsoft Learn](https://learn.microsoft.com/azure/iot-operations/)
- **Issues**: Open an issue in this repository
- **Azure Support**: For production issues, contact Azure Support

---

*Built for Azure IoT Operations monitoring and observability*
