# Edge MQTT Simulator

A comprehensive IoT simulator designed to send realistic telemetry to Azure IoT Operations MQTT Broker. Originally built for a spaceship manufacturing facility, but can be adapted for any industrial IoT scenario.

## Overview

This simulator generates telemetry from multiple types of manufacturing equipment:
- **CNC Machines** - Precision part manufacturing
- **3D Printers** - Additive manufacturing for complex components
- **Welding Stations** - Assembly welding operations
- **Painting Booths** - Surface finishing operations
- **Testing Rigs** - Quality assurance and testing

Plus business events:
- **Customer Orders** - Order placement events
- **Dispatch Events** - Fulfillment and shipping notifications

## Architecture

The simulator is built with a modular architecture:

```
app.py                    # Main MQTT client application
messages.py               # Message generation logic
message_structure.yaml    # Configuration for message types and cadence
```

### Key Features

- **Configurable Message Patterns** - All message types, frequencies, and parameters defined in YAML
- **Realistic State Management** - Machines maintain state across cycles
- **K8S-SAT Authentication** - Native Kubernetes ServiceAccountToken authentication
- **MQTT v5 Support** - Modern MQTT protocol with enhanced features
- **Message Routing** - Intelligent topic routing based on message type
- **Queue Management** - Buffered message queue with overflow protection
- **Statistics Tracking** - Real-time monitoring of message throughput

## Message Topics

Messages are routed to different MQTT topics based on type:

| Topic | Description |
|-------|-------------|
| `factory/cnc` | CNC machine telemetry |
| `factory/3dprinter` | 3D printer telemetry |
| `factory/welding` | Welding station telemetry |
| `factory/painting` | Painting booth telemetry |
| `factory/testing` | Testing rig telemetry |
| `factory/orders` | Customer order events |
| `factory/dispatch` | Dispatch/fulfillment events |
| `factory/telemetry` | Default topic for other messages |

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MQTT_BROKER` | `localhost` | MQTT broker hostname |
| `MQTT_PORT` | `18883` | MQTT broker port (MQTTS) |
| `MQTT_TOPIC_PREFIX` | `factory` | Topic prefix for all messages |
| `MQTT_CLIENT_ID` | `factory-sim-{pid}` | MQTT client identifier |
| `MQTT_AUTH_METHOD` | `K8S-SAT` | Authentication method |
| `SAT_TOKEN_PATH` | `/var/run/secrets/tokens/broker-sat` | Path to SAT token |
| `MESSAGE_CONFIG_PATH` | `message_structure.yaml` | Path to message config |
| `PYTHONUNBUFFERED` | `1` | Python output buffering |

### Message Configuration

The `message_structure.yaml` file controls all aspects of message generation:

- **Global Settings** - Base interval, machine counts
- **Message Types** - Enable/disable message types
- **Frequency Weights** - Relative frequency of each message type
- **Quality Distributions** - Percentage of good/bad parts
- **Status Distributions** - Machine operational states
- **Part/Assembly Types** - Product variety
- **Business Event Rates** - Orders and dispatches per hour

## Deployment

### Prerequisites

- Kubernetes cluster with Azure IoT Operations installed
- Service account `mqtt-client` with appropriate permissions
- Container registry access

### Build and Push

```bash
# Build the container
docker build -t <YOUR_REGISTRY>/edgemqttsim:latest .

# Push to registry
docker push <YOUR_REGISTRY>/edgemqttsim:latest
```

### Deploy to Kubernetes

1. Update `deployment.yaml` with your container registry
2. Apply the deployment:

```bash
kubectl apply -f deployment.yaml
```

### Register Assets in Azure IoT Operations

After deployment, register the factory assets in Azure IoT Operations for monitoring and management.

#### 🔑 Important: MQTT Assets are NOT Auto-Discovered

Unlike OPC UA assets, **MQTT-based assets do NOT appear in the "Discovery" window** in the Azure portal. The Discovery feature is exclusively for OPC UA auto-discovery. For MQTT assets, you must create them manually using one of these methods:

##### Option 1: Deploy Using Kubernetes Manifests (Recommended)

Use the provided asset manifest examples:

```bash
# Deploy MQTT asset endpoint profile
kubectl apply -f mqtt-asset-endpoint.yaml

# Deploy example asset definition
kubectl apply -f mqtt-asset-example.yaml

# Or use the deployment script
bash deploy-mqtt-assets.sh
```

The manifests include:
- **mqtt-asset-endpoint.yaml** - Defines the MQTT broker endpoint configuration
- **mqtt-asset-example.yaml** - Example asset with data points (customize for your needs)
- **deploy-mqtt-assets.sh** - Automated deployment script

After deployment:
1. Wait 2-3 minutes for `enable-rsync` to sync resources to Azure
2. Check Azure Portal → IoT Operations Instance → **Assets** (not Discovery)
3. Your assets will appear in the Assets list

##### Option 2: Create Assets via Azure Portal

1. Navigate to your IoT Operations instance
2. Go to **Assets** → **Create asset**
3. Configure:
   - Asset endpoint: Select or create MQTT endpoint
   - Asset properties: Name, description, manufacturer
   - Data points: Map to MQTT topics your simulator publishes to

##### Option 3: Create Assets via Azure CLI

```bash
# Create asset endpoint profile
az iot ops asset endpoint create \
  --name spaceship-factory-mqtt \
  --resource-group <resource-group> \
  --cluster <cluster-name> \
  --target-address "mqtt://aio-broker.azure-iot-operations.svc.cluster.local:18883"

# Create asset
az iot ops asset create \
  --name spaceship-assembly-line-1 \
  --resource-group <resource-group> \
  --cluster <cluster-name> \
  --endpoint spaceship-factory-mqtt \
  --data-points temperature,pressure,status
```

#### Customizing Asset Definitions

Edit `mqtt-asset-example.yaml` to match your actual:
- MQTT topics from the simulator
- Data point names and schemas
- Asset properties (manufacturer, model, serial number)

The example includes common data points:
- `temperature` - Temperature readings
- `pressure` - Pressure measurements  
- `production_count` - Production counters
- `status` - Machine status

**📋 See the comprehensive guide: [AZURE_ASSET_REGISTRATION.md](./AZURE_ASSET_REGISTRATION.md)** (if available)

This guide provides:
- Complete asset definitions for all factory equipment
- Datapoint configurations and event mappings
- MQTT topic structure recommendations
- Step-by-step registration process

### Verify Deployment

```bash
# Check pod status
kubectl get pods -l app=edgemqttsim

# View logs
kubectl logs -l app=edgemqttsim -f

# Check MQTT messages (if you have a subscriber)
kubectl logs -l app=edgemqttsim --tail=100
```

## OEE (Overall Equipment Effectiveness) Support

The simulator generates data to support OEE calculation:

### 🟢 Availability
- `status` field tracks machine state (running, idle, maintenance, faulted)
- `timestamp` enables uptime/downtime calculation
- Status distributions configurable per machine type

### 🟡 Performance
- `cycle_time` tracks actual operation duration
- Compare against configured `cycle_time_range` for ideal time
- `progress` field for 3D printers shows pacing

### 🔴 Quality
- `quality` field indicates part quality (good, scrap, rework)
- `test_result` from testing rigs (pass, fail)
- `issues_found` quantifies defects
- Quality distributions configurable per machine type

## Customization

### Adjust Message Frequency

Edit `message_structure.yaml`:

```yaml
global:
  base_interval: 1.0  # Seconds between generation cycles

message_types:
  cnc_machine:
    frequency_weight: 3  # Higher = more frequent
```

### Add New Machine Types

1. Define machine in `message_structure.yaml`
2. Add generation method in `messages.py`
3. Update topic routing in `app.py` if needed

### Change Quality Distributions

```yaml
message_types:
  cnc_machine:
    quality_distribution:
      good: 0.95   # 95% good parts
      scrap: 0.05  # 5% scrap
```

## Monitoring

The simulator outputs periodic statistics:

```
📊 Statistics (Uptime: 120s)
   Messages Sent: 450
   Messages Failed: 2
   Queue Depth: 5
   Message Rate: 3.75 msg/sec
```

## Troubleshooting

### Connection Issues

Check broker service:
```bash
kubectl get service -n azure-iot-operations aio-broker
```

Verify SAT token:
```bash
kubectl exec -it <pod-name> -- cat /var/run/secrets/tokens/broker-sat
```

### Message Not Appearing

1. Check topic subscriptions match the prefix
2. Verify QoS settings on subscriber
3. Check broker logs for errors

### Performance Issues

- Reduce `frequency_weight` values in config
- Increase `base_interval`
- Reduce machine counts
- Increase resource limits in deployment

## Architecture Diagram

```
┌─────────────────────────────────────────────────────┐
│  message_structure.yaml                             │
│  (Configuration)                                    │
└────────────────┬────────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────────────────┐
│  messages.py                                        │
│  ├─ FactoryMessageGenerator                        │
│  ├─ Machine state management                       │
│  ├─ Message generation logic                       │
│  └─ Business event generation                      │
└────────────────┬────────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────────────────┐
│  app.py                                             │
│  ├─ MQTT Client (K8S-SAT auth)                     │
│  ├─ Message queue management                       │
│  ├─ Topic routing                                  │
│  └─ Statistics & monitoring                        │
└────────────────┬────────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────────────────┐
│  Azure IoT Operations MQTT Broker                  │
│  Topics: factory/cnc, factory/3dprinter, etc.      │
└─────────────────────────────────────────────────────┘
```

## References

- [Factory Simulation Spec](../../Factory_Simulation_Spec.md) - Detailed message specifications
- [Sputnik Module](../sputnik/) - Reference implementation for MQTT connectivity
- [Azure IoT Operations Documentation](https://learn.microsoft.com/azure/iot-operations/)

## License

See repository root for license information.
