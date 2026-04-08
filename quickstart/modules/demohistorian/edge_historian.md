# Edge Historian - Design Document

## Overview
The Edge Historian is a lightweight containerized service that provides historical data storage and retrieval for MQTT messages on the edge. It subscribes to all MQTT topics, stores messages in PostgreSQL, and exposes an HTTP API for querying the last known good values.

## Architecture

### Components
```
┌─────────────────────────────────────────────────────┐
│              Edge Historian Container                │
│                                                      │
│  ┌─────────────────┐      ┌──────────────────┐    │
│  │  MQTT Subscriber │──────▶  PostgreSQL DB   │    │
│  │  (paho-mqtt)     │      │  (Time-series)   │    │
│  └─────────────────┘      └──────────────────┘    │
│                                   │                  │
│  ┌─────────────────┐             │                  │
│  │  HTTP API        │─────────────┘                 │
│  │  (Flask/FastAPI) │                               │
│  └─────────────────┘                                │
└─────────────────────────────────────────────────────┘
         ▲                          │
         │                          │
    HTTP Queries              MQTT Messages
         │                          │
         │                          ▼
    ┌────┴────┐            ┌────────────────┐
    │ Clients │            │ MQTT Broker    │
    │  (API)  │            │ (IoT Ops)      │
    └─────────┘            └────────────────┘
```

## Technology Stack

### Database
- **PostgreSQL** - Lightweight, reliable, excellent JSON support
- Single container with persistent volume
- Time-series optimized queries
- Automatic cleanup via CRON job or scheduled task

### Application
- **Python 3.11+** with `uv` package manager
- **paho-mqtt** - MQTT client library
- **FastAPI** - Modern, fast HTTP framework with automatic OpenAPI docs
- **psycopg2** or **asyncpg** - PostgreSQL driver
- **uvicorn** - ASGI server

### Authentication
- **ServiceAccountToken (K8S-SAT)** for MQTT broker connection (following project pattern)
- No authentication for HTTP API (edge-local only)

## Database Schema

### Table: `mqtt_history`
```sql
CREATE TABLE mqtt_history (
    id BIGSERIAL PRIMARY KEY,
    timestamp TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    topic TEXT NOT NULL,
    payload JSONB NOT NULL,
    qos INTEGER DEFAULT 0,
    received_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    -- Extracted fields for faster queries (optional optimization)
    machine_id TEXT GENERATED ALWAYS AS (payload->>'machine_id') STORED,
    status TEXT GENERATED ALWAYS AS (payload->>'status') STORED
);

-- Index for fast topic lookups
CREATE INDEX idx_topic_timestamp ON mqtt_history(topic, timestamp DESC);

-- Index for timestamp-based queries and cleanup
CREATE INDEX idx_timestamp ON mqtt_history(timestamp DESC);

-- Index for machine-specific queries (common pattern)
CREATE INDEX idx_machine_timestamp ON mqtt_history(machine_id, timestamp DESC) WHERE machine_id IS NOT NULL;

-- Index for JSONB queries (for complex payload searches)
CREATE INDEX idx_payload_gin ON mqtt_history USING GIN(payload);
```

### Compatible Topics
The historian subscribes to all topics (`#`) and is designed to work with edgemqttsim topics:
- `factory/cnc` - CNC machine telemetry
- `factory/3dprinter` - 3D printer telemetry  
- `factory/welding` - Welding station telemetry
- `factory/painting` - Painting booth telemetry
- `factory/testing` - Testing rig telemetry
- `factory/orders` - Customer orders
- `factory/dispatch` - Dispatch/fulfillment
- `factory/telemetry` - Fallback topic

### Example Message Storage
When edgemqttsim publishes this CNC message:
```json
{
  "timestamp": "2026-01-12T10:30:45Z",
  "machine_id": "CNC-01",
  "station_id": "LINE-1-STATION-A",
  "status": "running",
  "part_type": "HullPanel",
  "part_id": "HP-1001",
  "cycle_time": 12.5,
  "quality": "good"
}
```

It's stored as:
```
id: 1234
timestamp: 2026-01-12T10:30:45Z
topic: factory/cnc
payload: {entire JSON}
machine_id: CNC-01 (extracted)
status: running (extracted)
received_at: 2026-01-12T10:30:45.123Z
```

### Data Retention
- Automatic deletion of records older than 24 hours
- Implemented via scheduled cleanup task in application
- Runs every hour: `DELETE FROM mqtt_history WHERE timestamp < NOW() - INTERVAL '24 hours'`

## Application Design

### MQTT Subscriber Component
```python
# Pseudo-code structure for AIO MQTT broker
import paho.mqtt.client as mqtt
import ssl
from pathlib import Path

class MQTTSubscriber:
    def __init__(self, config, db_connection):
        # MQTT v5 for K8S-SAT authentication
        self.client = mqtt.Client(protocol=mqtt.MQTTv5)
        self.db = db_connection
        self.config = config
        
    def setup_authentication(self):
        """Configure ServiceAccountToken authentication for AIO broker."""
        # Read K8S ServiceAccountToken
        token_path = Path(self.config['mqtt']['sat_token_path'])
        token = token_path.read_text().strip()
        
        # Configure MQTT v5 enhanced authentication
        auth_properties = mqtt.Properties(packetType=mqtt.PacketTypes.CONNECT)
        auth_properties.AuthenticationMethod = 'K8S-SAT'
        auth_properties.AuthenticationData = token.encode('utf-8')
        
        # TLS required but no cert verification for in-cluster
        self.client.tls_set(cert_reqs=ssl.CERT_NONE)
        
        return auth_properties
        
    def on_connect(self, client, userdata, flags, reason_code, properties):
        """Called when connected to AIO MQTT broker."""
        if reason_code == 0:
            # Subscribe to all topics (requires proper BrokerAuthorization)
            client.subscribe("#", qos=0)
            print("✓ Subscribed to all topics")
        else:
            print(f"✗ Connection failed: {reason_code}")
        
    def on_message(self, client, userdata, msg):
        """Store incoming MQTT message to database."""
        try:
            # Parse JSON payload
            payload = json.loads(msg.payload.decode('utf-8'))
            # Store in database
            self.store_message(msg.topic, payload, msg.qos)
        except json.JSONDecodeError:
            # Handle non-JSON messages
            self.store_message(msg.topic, msg.payload.decode('utf-8'), msg.qos)
        except Exception as e:
            print(f"Error storing message: {e}")
        
    def store_message(self, topic, payload, qos):
        """Insert message into PostgreSQL."""
        with self.db.cursor() as cursor:
            cursor.execute(
                """INSERT INTO mqtt_history (topic, payload, qos) 
                   VALUES (%s, %s, %s)""",
                (topic, json.dumps(payload), qos)
            )
        self.db.commit()
```

### HTTP API Component
```python
# FastAPI endpoints
@app.get("/health")
def health_check():
    """Health check endpoint for Kubernetes"""
    return {"status": "healthy"}

@app.get("/api/v1/last-value/{topic:path}")
def get_last_value(topic: str):
    """Get last known good value for a topic"""
    # Query: SELECT * FROM mqtt_history 
    #        WHERE topic = $1 
    #        ORDER BY timestamp DESC 
    #        LIMIT 1
    return {
        "timestamp": "2026-01-12T10:30:00Z",
        "topic": topic,
        "payload": {...}
    }

@app.get("/api/v1/query")
def query_history(
    topic: str = None,
    start_time: datetime = None,
    end_time: datetime = None,
    limit: int = 100
):
    """Query historical data with filters"""
    # Advanced queries for future enhancement
    pass

@app.get("/api/v1/stats")
def get_statistics():
    """Get database statistics"""
    return {
        "total_messages": 12345,
        "topics_count": 25,
        "oldest_message": "2026-01-11T10:30:00Z",
        "newest_message": "2026-01-12T10:30:00Z"
    }
```

## Configuration

### Configuration File (config.yaml)
The application uses a YAML configuration file for all settings, with optional environment variable overrides for sensitive data.

```yaml
# config.yaml
mqtt:
  broker: aio-broker.azure-iot-operations.svc.cluster.local
  port: 18883  # AIO MQTTS port
  topic: "#"  # Subscribe to all topics (requires proper authorization)
  auth_method: K8S-SAT  # Kubernetes ServiceAccountToken (AIO standard)
  qos: 0  # At-most-once delivery (lightest)
  keepalive: 60
  reconnect_delay: 5  # seconds
  protocol_version: 5  # MQTT v5 required for K8S-SAT auth
  sat_token_path: /var/run/secrets/tokens/broker-sat
  sat_audience: aio-internal  # Must match broker configuration
  
database:
  host: localhost
  port: 5432
  name: mqtt_historian
  user: historian
  password: ${POSTGRES_PASSWORD}  # From environment variable or K8s secret
  pool_size: 5
  pool_max_overflow: 10
  
http:
  host: 0.0.0.0
  port: 8080
  cors_enabled: false
  
retention:
  hours: 24
  cleanup_interval_seconds: 3600  # Run cleanup every hour
  
logging:
  level: INFO  # DEBUG, INFO, WARNING, ERROR
  format: json  # json or text
  
metrics:
  enabled: true
  port: 9090
```

### Environment Variable Overrides
Sensitive values can be overridden via environment variables:

```bash
# Override database password (recommended for production)
POSTGRES_PASSWORD=secure_password_from_k8s_secret

# Override MQTT broker (for different environments)
MQTT_BROKER=aio-broker.azure-iot-operations.svc.cluster.local

# Override log level
LOG_LEVEL=DEBUG
```

### Configuration Priority
1. Environment variables (highest priority)
2. YAML configuration file
3. Application defaults (lowest priority)

### Configuration Loading
```python
# Pseudo-code for config loading
import yaml
import os

def load_config(config_path="config.yaml"):
    # Load YAML
    with open(config_path) as f:
        config = yaml.safe_load(f)
    
    # Override with environment variables
    config['database']['password'] = os.getenv('POSTGRES_PASSWORD', 
                                                config['database']['password'])
    config['mqtt']['broker'] = os.getenv('MQTT_BROKER', 
                                         config['mqtt']['broker'])
    config['logging']['level'] = os.getenv('LOG_LEVEL', 
                                           config['logging']['level'])
    
    return config
```

## Deployment Strategy

### Overview
The demohistorian is deployed using the existing deployment infrastructure:
- **Deploy-EdgeModules.ps1** - PowerShell script for remote deployment
- **Azure Arc Proxy** - kubectl through Azure connectedk8s proxy
- **Cross-network deployment** - Windows development machine → Linux edge server
- **Configuration-driven** - Controlled via `aio_config.json`

### Deployment Architecture
```
Windows Dev Machine                    Azure Arc                    Linux Edge Server
┌─────────────────┐                ┌──────────┐                ┌──────────────────┐
│                 │                │          │                │                  │
│ Deploy-         │──az──────────▶│   Arc    │──kubectl─────▶│  K3s Cluster     │
│ EdgeModules.ps1 │   connectedk8s │  Proxy   │   proxy       │  + AIO           │
│                 │                │          │                │  + demohistorian │
└─────────────────┘                └──────────┘                └──────────────────┘
```

### Configuration File

Add `demohistorian` to `linux_build/aio_config.json`:

```json
{
  "modules": {
    "edgemqttsim": true,
    "hello-flask": false,
    "sputnik": false,
    "wasm-quality-filter-python": false,
    "demohistorian": true
  }
}
```

### Deployment Files Structure

The module follows the standard iotopps pattern:
```
iotopps/demohistorian/
├── app.py                      # Main application
├── Dockerfile                  # Container image
├── deployment.yaml             # Kubernetes deployment manifest
├── requirements.txt            # Python dependencies
├── config.yaml                 # Default configuration
├── schema.sql                  # Database initialization
├── README.md                   # Module documentation
└── edge_historian.md          # Design document (this file)
```

### Docker Compose (for local testing only)
```yaml
version: '3.8'
services:
  postgres:
    image: postgres:16-alpine
    environment:
      POSTGRES_DB: mqtt_historian
      POSTGRES_USER: historian
      POSTGRES_PASSWORD: changeme
    volumes:
      - postgres_data:/var/lib/postgresql/data
    
  historian:
    build: .
    depends_on:
      - postgres
    environment:
      POSTGRES_HOST: postgres
      MQTT_BROKER: host.docker.internal  # For local testing
    ports:
      - "8080:8080"

volumes:
  postgres_data:
```

### Kubernetes Deployment via Deploy-EdgeModules.ps1

**Prerequisites:**
1. Azure Arc proxy connection established
2. `aio_config.json` configured with `"demohistorian": true`
3. Container registry credentials configured (Docker Hub or ACR)

**Deployment Command:**
```powershell
# Deploy from Windows development machine
cd linux_build

# Deploy demohistorian module
.\Deploy-EdgeModules.ps1 -ModuleName demohistorian

# Deploy all enabled modules (including demohistorian)
.\Deploy-EdgeModules.ps1

# Force redeployment
.\Deploy-EdgeModules.ps1 -ModuleName demohistorian -Force
```

**What the script does:**
1. Reads configuration from `aio_config.json`
2. Starts Azure Arc proxy (`az connectedk8s proxy`)
3. Builds Docker image locally (if not skipped)
4. Pushes image to configured registry
5. Updates `deployment.yaml` with registry details
6. Creates ServiceAccount `mqtt-client` if needed
7. Deploys via `kubectl apply -f deployment.yaml`
8. Verifies pod status

### Kubernetes Manifests

**File: `iotopps/demohistorian/deployment.yaml`**

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: historian-pvc
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 5Gi
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: historian-sa
  namespace: default
---
# CRITICAL: BrokerAuthorization must be created for wildcard subscription
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
          - "#"  # Allow subscription to ALL topics
      - method: Subscribe
        clientIds:
          - "historian-*" 
        topics:
          - "factory/#"  # Explicit factory namespace permission
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demohistorian
  namespace: default
spec:
  replicas: 1  # Single instance for edge
  selector:
    matchLabels:
      app: demohistorian
  template:
    metadata:
      labels:
        app: demohistorian
    spec:
      serviceAccountName: historian-sa  # For AIO MQTT K8S-SAT auth
      containers:
      - name: postgres
        image: postgres:16-alpine
        env:
          - name: POSTGRES_DB
            value: mqtt_historian
          - name: POSTGRES_USER
            value: historian
          - name: POSTGRES_PASSWORD
            valueFrom:
              secretKeyRef:
                name: historian-secret
                key: db-password
          - name: PGDATA
            value: /var/lib/postgresql/data/pgdata
        volumeMounts:
          - name: postgres-storage
            mountPath: /var/lib/postgresql/data
        resources:
          requests:
            memory: "256Mi"
            cpu: "200m"
          limits:
            memory: "512Mi"
            cpu: "500m"
        livenessProbe:
          exec:
            command:
              - pg_isready
              - -U
              - historian
          initialDelaySeconds: 15
          periodSeconds: 10
      
      - name: historian
        image: <registry>/demohistorian:latest
        env:
          # Database connection (same pod)
          - name: POSTGRES_HOST
            value: localhost
          - name: POSTGRES_PASSWORD
            valueFrom:
              secretKeyRef:
                name: historian-secret
                key: db-password
          
          # AIO MQTT broker configuration
          - name: MQTT_BROKER
            value: aio-broker.azure-iot-operations.svc.cluster.local
          - name: MQTT_PORT
            value: "18883"
          - name: MQTT_CLIENT_ID
            value: historian-001  # Must match BrokerAuthorization pattern
          - name: MQTT_AUTH_METHOD
            value: K8S-SAT
          - name: SAT_TOKEN_PATH
            value: /var/run/secrets/tokens/broker-sat
          
          - name: PYTHONUNBUFFERED
            value: "1"
        
        ports:
          - containerPort: 8080
            name: http
        
        volumeMounts:
          - name: broker-sat
            mountPath: /var/run/secrets/tokens
            readOnly: true
          - name: config
            mountPath: /app/config
            readOnly: true
        
        livenessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 15
          periodSeconds: 30
        
        readinessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 10
          periodSeconds: 10
        
        resources:
          requests:
            memory: "128Mi"
            cpu: "100m"
          limits:
            memory: "256Mi"
            cpu: "500m"
      
      volumes:
        - name: postgres-storage
          persistentVolumeClaim:
            claimName: historian-pvc
        
        # ServiceAccountToken for AIO MQTT authentication
        - name: broker-sat
          projected:
            sources:
              - serviceAccountToken:
                  path: broker-sat
                  expirationSeconds: 86400  # 24 hours
                  audience: aio-internal  # Must match BrokerListener config
        
        # ConfigMap for application configuration
        - name: config
          configMap:
            name: historian-config
---
apiVersion: v1
kind: Service
metadata:
  name: demohistorian
  namespace: default
spec:
  selector:
    app: demohistorian
  ports:
    - port: 8080
      targetPort: 8080
      name: http
  type: ClusterIP
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: historian-config
  namespace: default
data:
  config.yaml: |
    mqtt:
      broker: aio-broker.azure-iot-operations.svc.cluster.local
      port: 18883
      topic: "#"
      auth_method: K8S-SAT
      qos: 0
      keepalive: 60
      reconnect_delay: 5
      protocol_version: 5
      sat_token_path: /var/run/secrets/tokens/broker-sat
      sat_audience: aio-internal
    
    database:
      host: localhost
      port: 5432
      name: mqtt_historian
      user: historian
      pool_size: 5
    
    http:
      host: 0.0.0.0
      port: 8080
    
    retention:
      hours: 24
      cleanup_interval_seconds: 3600
    
    logging:
      level: INFO
      format: json
```

### BrokerAuthorization (Applied Separately)

**File: `linux_build/assets/historian-authorization.yaml`**

Applied manually via kubectl:
```bash
kubectl apply -f linux_build/assets/historian-authorization.yaml
```

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
          - "#"  # Allow subscription to ALL topics
          - "factory/#"  # Explicit factory namespace permission
```

### Verification Commands

Via Azure Arc proxy from Windows:
```powershell
# Check deployment status
kubectl get deployments -n default

# Check pod status
kubectl get pods -n default -l app=demohistorian

# View historian logs
kubectl logs -n default -l app=demohistorian -c historian -f

# View PostgreSQL logs
kubectl logs -n default -l app=demohistorian -c postgres

# Check service
kubectl get svc -n default demohistorian

# Test health endpoint (from within cluster)
# Short form:
kubectl run -it --rm debug --image=curlimages/curl --restart=Never -- \
  curl http://demohistorian:8080/health

# FQDN (use this format for cross-namespace access like AIO UI):
kubectl run -it --rm debug --image=curlimages/curl --restart=Never -- \
  curl http://demohistorian.default.svc.cluster.local:8080/health
```

### Troubleshooting Deployment

**Issue: Arc proxy not connecting**
```powershell
# Verify cluster is Arc-enabled
az connectedk8s show --name <cluster-name> --resource-group <rg>

# Check cluster connectivity
az connectedk8s list --resource-group <rg>
```

**Issue: Pod not starting**
```bash
# Via Arc proxy
kubectl describe pod -n default -l app=demohistorian
kubectl logs -n default -l app=demohistorian --all-containers
```

**Issue: MQTT connection fails**
```bash
# Check ServiceAccount
kubectl get sa historian-sa -n default

# Check BrokerAuthorization
kubectl get brokerauthorization -n azure-iot-operations historian-authz

# Check token mount
kubectl exec -n default <pod-name> -c historian -- ls -la /var/run/secrets/tokens/

# Test MQTT broker connectivity
kubectl exec -n default <pod-name> -c historian -- \
  curl -k https://aio-broker.azure-iot-operations.svc.cluster.local:18883
```

**Issue: Database not initializing**
```bash
# Check PostgreSQL logs
kubectl logs -n default -l app=demohistorian -c postgres

# Check PVC status
kubectl get pvc historian-pvc -n default

# Exec into postgres container
kubectl exec -n default <pod-name> -c postgres -it -- psql -U historian -d mqtt_historian
```

## Implementation Phases

### Phase 1: Core Functionality (MVP)
- [ ] PostgreSQL setup with schema
- [ ] MQTT subscriber with wildcard (#) subscription
- [ ] Basic message storage to database
- [ ] HTTP endpoint for last known value
- [ ] Health check endpoint
- [ ] Basic error handling and logging

### Phase 2: Production Features
- [ ] Automatic 24-hour data cleanup
- [ ] ServiceAccountToken authentication for MQTT
- [ ] Connection retry logic
- [ ] Graceful shutdown handling
- [ ] Prometheus metrics endpoint

### Phase 3: Enhanced Features (Optional)
- [ ] Topic filtering/whitelisting
- [ ] Query API with time ranges
- [ ] Statistics and dashboard endpoint
- [ ] Message rate limiting
- [ ] Compression for old data

## Performance Considerations

### Resource Usage
- **Memory**: ~384MB total (256MB PostgreSQL + 128MB Python app)
- **CPU**: Low usage, burst during high message rates
- **Storage**: Depends on message rate, ~1GB for 24 hours at 100 msg/sec
- **Network**: Minimal, local MQTT and HTTP only

### Scalability
- Single instance sufficient for edge deployment
- PostgreSQL handles thousands of inserts/second
- HTTP queries optimized with indexes
- No horizontal scaling needed (edge device limitation)

### Message Rate Estimation
Assuming factory simulation scenario:
- 5 machines × 1 message/second = 5 msg/sec
- 5 msg/sec × 86,400 sec/day = 432,000 messages/day
- Average message size: 500 bytes
- Daily storage: ~216 MB (uncompressed)

## API Examples

### Get Last Known Value
```bash
# Request - Get last value from CNC machine topic
# Short form (same namespace):
GET http://demohistorian:8080/api/v1/last-value/factory/cnc

# FQDN (cross-namespace, use this for AIO UI):
GET http://demohistorian.default.svc.cluster.local:8080/api/v1/last-value/factory/cnc

# Response - Actual edgemqttsim CNC message format
{
  "timestamp": "2026-01-12T10:30:45Z",
  "topic": "factory/cnc",
  "payload": {
    "timestamp": "2026-01-12T10:30:45Z",
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

```bash
# Request - Get last value from 3D printer topic
GET http://edge-historian:8080/api/v1/last-value/factory/3dprinter

# Response - Actual edgemqttsim 3D printer message
{
  "timestamp": "2026-01-12T10:31:20Z",
  "topic": "factory/3dprinter",
  "payload": {
    "timestamp": "2026-01-12T10:31:20Z",
    "machine_id": "3DP-03",
    "station_id": "LINE-2-STATION-B",
    "status": "running",
    "part_type": "GearboxCasing",
    "part_id": "P-456",
    "progress": 0.65,
    "quality": null
  },
  "received_at": "2026-01-12T10:31:20.089Z"
}
```

```bash
# Request - Query specific machine by filtering
GET http://edge-historian:8080/api/v1/query?machine_id=CNC-01&limit=10

# Response - Last 10 messages from CNC-01
{
  "results": [
    {
      "timestamp": "2026-01-12T10:30:45Z",
      "topic": "factory/cnc",
      "payload": {...}
    }
  ],
  "count": 10
}
```

### Health Check
```bash
# Request (use FQDN for AIO UI)
GET http://demohistorian.default.svc.cluster.local:8080/health

# Or short form (same namespace only):
GET http://demohistorian:8080/health

# Response
{
  "status": "healthy",
  "mqtt_connected": true,
  "db_connected": true,
  "messages_stored": 12345,
  "uptime_seconds": 3600
}
```

### Statistics
```bash
# Request
GET http://demohistorian.default.svc.cluster.local:8080/api/v1/stats

# Response
{
  "total_messages": 432000,
  "unique_topics": 25,
  "oldest_message": "2026-01-11T10:30:00Z",
  "newest_message": "2026-01-12T10:30:00Z",
  "database_size_mb": 216.5,
  "messages_per_second_avg": 5.0
}
```

## Testing Strategy

### Unit Tests
- Database operations (insert, query, cleanup)
- MQTT message parsing
- HTTP endpoint responses
- Error handling

### Integration Tests
- MQTT broker connection
- PostgreSQL connection
- End-to-end message flow: MQTT → DB → HTTP
- Cleanup task execution

### Load Testing
- Simulate high message rates (100+ msg/sec)
- Concurrent HTTP queries
- 24-hour retention verification

## Monitoring and Observability

### Logging
- Structured JSON logging
- Log levels: DEBUG, INFO, WARNING, ERROR
- Key events:
  - MQTT connection status
  - Database connection status
  - Messages stored (periodic summary)
  - Cleanup task execution
  - API requests (with response times)

### Metrics (Prometheus format)
```
# MQTT
mqtt_messages_received_total
mqtt_messages_stored_total
mqtt_connection_errors_total

# Database
db_insert_duration_seconds
db_query_duration_seconds
db_cleanup_duration_seconds
db_total_messages
db_size_bytes

# HTTP
http_requests_total{method, endpoint, status}
http_request_duration_seconds
```

## Azure IoT Operations Configuration

### Required Resources

The historian requires specific Azure IoT Operations resources to function properly:

#### 1. ServiceAccount
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: historian-sa
  namespace: default
```

#### 2. BrokerAuthorization (Critical)
```yaml
apiVersion: mqttbroker.iotoperations.azure.com/v1beta1
kind: BrokerAuthorization
metadata:
  name: historian-authz
  namespace: azure-iot-operations
spec:
  authorizationPolicies:
    brokerResources:
      - method: Subscribe
        clientIds:
          - "historian-*"  # Allow historian clients
        topics:
          - "#"  # Subscribe to ALL topics
      - method: Connect
        clientIds:
          - "historian-*"
```

**Why this is critical:** 
- Without proper BrokerAuthorization, the historian will connect but fail to subscribe to `#` wildcard
- AIO broker enforces authorization policies - authentication alone is not sufficient
- The wildcard subscription `#` requires explicit permission in authorization policy
- Default policies may only allow specific topic patterns

#### 3. BrokerListener (Verify Configuration)
Ensure the broker listener is configured for SAT authentication:
```yaml
apiVersion: mqttbroker.iotoperations.azure.com/v1beta1
kind: BrokerListener
metadata:
  name: default-listener
  namespace: azure-iot-operations
spec:
  serviceName: aio-broker
  serviceType: ClusterIP
  port: 18883
  tls:
    mode: Automatic
  authenticationMethods:
    - sat:  # ServiceAccountToken method
        audiences:
          - aio-internal  # Must match deployment config
```

### Installation Order
1. Create ServiceAccount: `historian-sa`
2. Create BrokerAuthorization with wildcard subscription permission
3. Deploy historian with `serviceAccountName: historian-sa`
4. Verify connection and subscription in logs

## Security Considerations

### MQTT (Azure IoT Operations Specific)
- **Authentication**: K8S-SAT (ServiceAccountToken) via MQTT v5 enhanced auth
- **Authorization**: BrokerAuthorization policy with wildcard (`#`) subscribe permission
- **TLS**: Automatic TLS via AIO broker listener (port 18883)
- **Token Lifecycle**: 24-hour token automatically renewed by Kubernetes
- **Subscribe QoS**: 0 (at-most-once, lightest load on broker)
- **Client ID**: Include `historian-` prefix to match authorization policy

### AIO Broker Access Pattern
```
1. Historian pod starts with serviceAccountName: historian-sa
2. Kubernetes projects SAT token to /var/run/secrets/tokens/broker-sat
3. App reads token and connects to aio-broker using MQTT v5
4. Broker authenticates via K8S-SAT method (validates token)
5. Broker checks BrokerAuthorization for connect permission
6. App subscribes to "#" wildcard
7. Broker checks BrokerAuthorization for subscribe permission to "#"
8. If authorized, messages flow to historian
```

### Common Authorization Issues
- **Symptom**: Connects but doesn't receive messages
  - **Cause**: Missing BrokerAuthorization for wildcard subscription
  - **Fix**: Add `topics: ["#"]` to BrokerAuthorization subscribe policy
  
- **Symptom**: "Not authorized" error on connect
  - **Cause**: Missing connect permission in BrokerAuthorization
  - **Fix**: Add `method: Connect` policy with matching clientIds
  
- **Symptom**: Token authentication fails
  - **Cause**: Audience mismatch between deployment and BrokerListener
  - **Fix**: Ensure both use `audience: aio-internal`

### Database
- Password from Kubernetes secret
- No external access (localhost only in same pod)
- Regular PostgreSQL security updates

### HTTP API
- No authentication (internal edge network only)
- Not exposed outside cluster
- Rate limiting if needed
- Input validation on topic parameter

### Network Segmentation
- Historian runs in `default` namespace
- Accesses broker in `azure-iot-operations` namespace
- Uses Kubernetes DNS for cross-namespace service discovery
- No external network access required

## Maintenance

### Database Maintenance
- Automatic VACUUM via PostgreSQL autovacuum
- Index maintenance (REINDEX if needed)
- Monitor table size and performance

### Log Rotation
- Container logs managed by Kubernetes
- Retain last 7 days
- Max 100MB per container

## Future Enhancements

1. **Advanced Queries**: Time-range queries, aggregations
2. **Topic Filtering**: Whitelist/blacklist specific topics
3. **Data Export**: Export historical data to cloud storage
4. **Web UI**: Simple dashboard for browsing messages
5. **Compression**: Compress old data (>12 hours)
6. **Message Deduplication**: Optional dedup based on payload
7. **Multiple Retention Policies**: Different retention per topic pattern
8. **Streaming Export**: Real-time data export to Azure Event Hub/Fabric

## References

- [Azure IoT Operations MQTT Broker](https://learn.microsoft.com/azure/iot-operations/manage-mqtt-broker)
- [PostgreSQL Time-Series Best Practices](https://www.postgresql.org/docs/current/functions-datetime.html)
- [FastAPI Documentation](https://fastapi.tiangolo.com/)
- [paho-mqtt Python Client](https://www.eclipse.org/paho/index.php?page=clients/python/index.php)
- Project pattern: [edgemqttsim](../edgemqttsim/README.md)

## Notes

- This is a **demo/development tool** - not intended for production workloads
- 24-hour retention is sufficient for edge testing and development
- For production, consider Azure Data Explorer or Time Series Insights
- Lightweight design prioritizes simplicity over advanced features
- Single-pod deployment (PostgreSQL + App) reduces complexity

### Deployment Method
- **Deployed via**: `Deploy-EdgeModules.ps1` (PowerShell automation)
- **Connectivity**: Azure Arc proxy (`az connectedk8s proxy`)
- **Registry**: Docker Hub or Azure Container Registry
- **Remote execution**: Windows dev machine → Linux edge server (cross-network)
- **Configuration-driven**: Controlled by `aio_config.json`
- **Module integration**: Follows standard iotopps pattern

### Quick Start
```powershell
# 1. Add to config
# Edit linux_build/aio_config.json
# Set "demohistorian": true in modules section

# 2. Deploy
cd linux_build
.\Deploy-EdgeModules.ps1 -ModuleName demohistorian

# 3. Verify
kubectl get pods -n default -l app=demohistorian

# 4. Test API
kubectl run -it --rm debug --image=curlimages/curl --restart=Never -- \
  curl http://demohistorian:8080/api/v1/last-value/factory/cnc
```
