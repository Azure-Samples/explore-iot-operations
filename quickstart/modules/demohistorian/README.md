# Edge Historian (demohistorian)

A lightweight SQL-based historian for Azure IoT Operations that subscribes to all MQTT topics and provides an HTTP API for querying historical data.

## Overview

The Edge Historian is a containerized service that:
- ✅ Subscribes to all MQTT topics on Azure IoT Operations broker
- ✅ Stores messages in PostgreSQL with timestamp, topic, and JSON payload
- ✅ Provides HTTP REST API for querying last known values
- ✅ Automatically purges data older than 24 hours (configurable)
- ✅ Uses K8S ServiceAccountToken authentication for MQTT
- ✅ Lightweight design optimized for edge deployment

## Architecture

```
┌─────────────────────────────────────┐
│     AIO MQTT Broker                 │
│   (azure-iot-operations ns)         │
└───────────┬─────────────────────────┘
            │ MQTT v5 (K8S-SAT auth)
            ▼
┌─────────────────────────────────────┐
│   Edge Historian Pod                │
│                                     │
│  ┌──────────┐    ┌──────────────┐  │
│  │ Historian│───▶│ PostgreSQL   │  │
│  │ App      │    │ 16-alpine    │  │
│  │ (Python) │    │              │  │
│  └────┬─────┘    └──────────────┘  │
│       │                             │
│       ▼                             │
│  HTTP API :8080                     │
└─────────────────────────────────────┘
```

## Features

### MQTT Subscription
- Subscribes to `#` wildcard (all topics)
- Supports factory topics: `factory/cnc`, `factory/3dprinter`, etc.
- K8S-SAT authentication for secure AIO broker access
- Automatic reconnection on connection loss
- QoS 0 (at-most-once) for minimal broker load
- **Character sanitization** - Special/unicode characters replaced with underscores to prevent encoding errors

### Data Storage
- **PostgreSQL 16-alpine** (lightweight, reliable)
- **Table**: `mqtt_history` with columns:
  - `timestamp` - Message timestamp from payload
  - `topic` - MQTT topic
  - `payload` - Full message as JSONB
  - `qos` - Quality of Service level
  - `received_at` - When historian received it
  - `machine_id` - Extracted for fast queries (generated column)
  - `status` - Extracted for fast queries (generated column)
- **Indexes** for fast topic and machine queries
- **24-hour retention** (automatic cleanup)
- **Unicode handling** - Special characters automatically sanitized to prevent encoding issues

### HTTP API
- `GET /health` - Health check (for K8s probes)
- `GET /api/v1/last-value/{topic}` - Get last value for topic
- `GET /api/v1/query?topic=X&machine_id=Y&limit=N` - Query with filters
- `GET /api/v1/stats` - Database statistics

### Resource Usage
- **Memory**: ~384MB (256MB PostgreSQL + 128MB Python)
- **CPU**: Low (bursts during high message rates)
- **Storage**: ~200MB per day @ 5 msg/sec (auto-purged after 24h)

## Deployment

### Prerequisites
1. Azure IoT Operations cluster with Arc connectivity
2. `aio_config.json` configured
3. BrokerAuthorization with wildcard subscription permission

### Quick Deploy

```powershell
# 1. Enable in configuration
# Edit: linux_build/aio_config.json
# Set: "demohistorian": true in modules section

# 2. Deploy using automation script
cd linux_build
.\Deploy-EdgeModules.ps1 -ModuleName demohistorian

# 3. Verify deployment
kubectl get pods -n default -l app=demohistorian
kubectl logs -n default -l app=demohistorian -c historian -f
```

### Manual Deployment

```bash
# Build and push container
docker build -t <registry>/demohistorian:latest .
docker push <registry>/demohistorian:latest

# Update deployment.yaml with your registry
sed -i 's|<YOUR_REGISTRY>|<registry>|g' deployment.yaml

# Create BrokerAuthorization (CRITICAL - required for wildcard subscription)
kubectl apply -f ../../linux_build/assets/historian-authorization.yaml

# Deploy to cluster
kubectl apply -f deployment.yaml

# Check status
kubectl get pods -n default -l app=demohistorian
```

## BrokerAuthorization Setup

**CRITICAL**: The historian requires wildcard subscription permission.

Create `historian-authorization.yaml` in `linux_build/assets/`:

```yaml
apiVersion: mqttbroker.iotoperations.azure.com/v1beta1
kind: BrokerAuthorization
metadata:
  name: historian-authz
  namespace: azure-iot-operations
spec:
  authorizationPolicies:
    brokerResources:
      - method: Connect
        clientIds:
          - "historian-*"
      - method: Subscribe
        clientIds:
          - "historian-*"
        topics:
          - "#"           # All topics
          - "factory/#"   # Explicit factory namespace
```

Apply it:
```bash
kubectl apply -f linux_build/assets/historian-authorization.yaml
```

## API Usage

### Health Check

**Get the service IP address:**
```bash
kubectl get svc demohistorian -n default -o jsonpath='{.spec.clusterIP}'
```

Then use the IP:
```bash
# Replace <CLUSTER_IP> with the IP from above
curl http://<CLUSTER_IP>:8080/health
```

Or use service name (inside cluster):
```bash
curl http://demohistorian:8080/health
```

Response:
```json
{
  "status": "healthy",
  "mqtt_connected": true,
  "db_connected": true,
  "messages_stored": 12345,
  "timestamp": "2026-01-12T10:30:00Z"
}
```

### Get Last Value for Topic

**Get the service IP address:**
```bash
kubectl get svc demohistorian -n default -o jsonpath='{.spec.clusterIP}'
```

Then use the IP:
```bash
# Replace <CLUSTER_IP> with the IP from above
curl http://<CLUSTER_IP>:8080/api/v1/last-value/factory/cnc
```

Or use service name (inside cluster):
```bash
curl http://demohistorian:8080/api/v1/last-value/factory/cnc
```

Response:
```json
{
  "timestamp": "2026-01-12T10:30:45Z",
  "topic": "factory/cnc",
  "payload": {
    "machine_id": "CNC-01",
    "station_id": "LINE-1-STATION-A",
    "status": "running",
    "part_type": "HullPanel",
    "part_id": "HP-1001",
    "cycle_time": 12.5,
    "quality": "good"
  },
  "received_at": "2026-01-12T10:30:45.123Z"
}
```

### Query Messages

**Get the service IP address:**
```bash
# Get the ClusterIP
kubectl get svc demohistorian -n default -o jsonpath='{.spec.clusterIP}'
```

Then use the IP address to query:
```bash
# Replace <CLUSTER_IP> with the IP from above
# Get last 10 messages from specific machine
curl "http://<CLUSTER_IP>:8080/api/v1/query?machine_id=CNC-01&limit=10"

# Get messages from specific topic
curl "http://<CLUSTER_IP>:8080/api/v1/query?topic=factory/welding&limit=50"
```

Or use the service name (DNS works inside cluster):
```bash
curl "http://demohistorian:8080/api/v1/query?machine_id=CNC-01&limit=10"
```

### Get Statistics

**Get the service IP address:**
```bash
kubectl get svc demohistorian -n default -o jsonpath='{.spec.clusterIP}'
```

Then use the IP:
```bash
# Replace <CLUSTER_IP> with the IP from above
curl http://<CLUSTER_IP>:8080/api/v1/stats
```

Or use service name (inside cluster):
```bash
curl http://demohistorian:8080/api/v1/stats
```

Response:
```json
{
  "total_messages": 432000,
  "unique_topics": 25,
  "oldest_message": "2026-01-11T10:30:00Z",
  "newest_message": "2026-01-12T10:30:00Z",
  "database_size_mb": 216.5,
  "messages_stored_session": 12345,
  "errors": 0
}
```

## Configuration

Configuration is loaded from `config.yaml` with environment variable overrides.

### Key Environment Variables
```bash
# MQTT Configuration
MQTT_BROKER=aio-broker.azure-iot-operations.svc.cluster.local
MQTT_PORT=18883
MQTT_AUTH_METHOD=K8S-SAT
SAT_TOKEN_PATH=/var/run/secrets/tokens/broker-sat

# Database Configuration
POSTGRES_HOST=localhost
POSTGRES_PORT=5432
POSTGRES_DB=mqtt_historian
POSTGRES_USER=historian
POSTGRES_PASSWORD=your_password

# Application Configuration
LOG_LEVEL=INFO  # DEBUG, INFO, WARNING, ERROR
```

## Troubleshooting

### Pod Not Starting
```bash
# Check pod status
kubectl describe pod -n default -l app=demohistorian

# Check logs
kubectl logs -n default -l app=demohistorian -c historian
kubectl logs -n default -l app=demohistorian -c postgres
```

### MQTT Connection Issues
```bash
# Check ServiceAccount
kubectl get sa historian-sa -n default

# Check BrokerAuthorization
kubectl get brokerauthorization -n azure-iot-operations historian-authz

# Check token mount
kubectl exec -n default <pod> -c historian -- ls -la /var/run/secrets/tokens/

# Check logs for connection errors
kubectl logs -n default -l app=demohistorian -c historian | grep -i mqtt
```

### No Messages Being Stored
```bash
# Verify MQTT subscription
kubectl logs -n default -l app=demohistorian -c historian | grep -i subscribed

# Check BrokerAuthorization allows wildcard subscription
kubectl describe brokerauthorization -n azure-iot-operations historian-authz

# Test if edgemqttsim is publishing
kubectl logs -n default -l app=edgemqttsim | tail -20
```

### Database Issues
```bash
# Check PostgreSQL is ready
kubectl exec -n default <pod> -c postgres -- pg_isready -U historian

# Check database schema
kubectl exec -n default <pod> -c postgres -- \
  psql -U historian -d mqtt_historian -c "\dt"

# Query message count
kubectl exec -n default <pod> -c postgres -- \
  psql -U historian -d mqtt_historian -c "SELECT COUNT(*) FROM mqtt_history;"
```

### Unicode/Encoding Errors
The historian automatically sanitizes special characters to prevent encoding issues:
- Special/unicode characters (emojis, fancy symbols) → replaced with `_`
- Keeps safe ASCII: letters, numbers, spaces, basic punctuation (`. - _ , : / ( ) [ ] { } @`)
- Applied recursively to all string values in JSON payloads
- No configuration needed - automatic protection

### Access API from Outside Cluster
```bash
# Port forward (for testing)
kubectl port-forward -n default svc/demohistorian 8080:8080

# Then access from local machine
curl http://localhost:8080/health
```

## Development

### Local Testing with Docker Compose
```bash
# Start PostgreSQL + Historian locally
docker-compose up

# Test against local MQTT broker
export MQTT_BROKER=host.docker.internal
docker-compose up historian
```

### Run Locally (Development)
```bash
# Install dependencies
pip install -r requirements.txt

# Set environment variables
export POSTGRES_HOST=localhost
export POSTGRES_PASSWORD=changeme
export MQTT_BROKER=localhost  # or remote broker

# Run application
python app.py
```

## Integration with edgemqttsim

The historian automatically captures all messages from edgemqttsim:
- `factory/cnc` - CNC machine telemetry
- `factory/3dprinter` - 3D printer progress
- `factory/welding` - Welding station status
- `factory/painting` - Painting booth data
- `factory/testing` - Testing rig results
- `factory/orders` - Customer orders
- `factory/dispatch` - Dispatch notifications

Query example:
```bash
# Get the service IP
kubectl get svc demohistorian -n default -o jsonpath='{.spec.clusterIP}'

# Replace <CLUSTER_IP> with the IP from above
# Get last CNC machine status
curl http://<CLUSTER_IP>:8080/api/v1/last-value/factory/cnc

# Get last 20 welding events
curl "http://<CLUSTER_IP>:8080/api/v1/query?topic=factory/welding&limit=20"
```

## Limitations

- **Demo tool** - Not for production workloads
- **24-hour retention** - Data automatically purged
- **Single replica** - No high availability
- **No authentication** - HTTP API is open (cluster-internal only)
- **Simple queries** - No time-range queries yet (Phase 3 feature)

For production use cases, consider:
- Azure Data Explorer
- Azure Time Series Insights
- InfluxDB + Grafana

## Files

```
demohistorian/
├── app.py              # Main application (MQTT + FastAPI + DB)
├── requirements.txt    # Python dependencies
├── Dockerfile          # Container image
├── deployment.yaml     # Kubernetes deployment
├── config.yaml         # Default configuration
├── schema.sql          # Database schema
├── README.md           # This file
└── edge_historian.md   # Design document
```

## Support

- Design Document: [edge_historian.md](edge_historian.md)
- Project Pattern: [edgemqttsim](../edgemqttsim/README.md)
- AIO Auth: [AUTH_COMPARISON.md](../AUTH_COMPARISON.md)

## License

Part of the learn-iot project - demo/educational purposes.
