# Anomaly Detection Server

## Quick Start

```sh
kubectl apply -f manifest.yml
```

## Usage

### Server as a Pod

```sh
# From the root of the anomaly-detection directory.
docker build ../.. -f Dockerfile -t ghcr.io/azure-samples/explore-iot-operations/anomaly-detection:latest

# Or if running from the root of the explore-iot-operations repository.
# docker build . -f ./samples/anomaly-detection/Dockerfile -t ghcr.io/azure-samples/explore-iot-operations/anomaly-detection:latest

# Push or load your newly built image into your cluster, depending on the k8s setup.
# docker push ghcr.io/azure-samples/explore-iot-operations/anomaly-detection:latest # Using AKS + Connected ACR
# minikube load ghcr.io/azure-samples/explore-iot-operations/anomaly-detection:latest # Using minikube
# docker save ghcr.io/azure-samples/explore-iot-operations/anomaly-detection:latest | k3s ctr images import - # Using K3s

kubectl apply -f manifest.yml
```

### Configuration

```yaml
logger: # Logger settings
  level: 0
server: # Server settings
  route: /anomaly
  port: 3333
algorithm: # Algorithm settings
  temperature: # Temperature related algorithm settings
    lambda: 0.25 # Lambda value for temperature anomaly detection
    lFactor: 3 # L factor for temperature anomaly detection
    controlT: 90 # Control limit T constant
    controlS: 20 # Control limit S constant
    controlN: 10 # Control limit N constant
  vibration: # Vibration related algorithm settings
    lambda: 0.25
    lFactor: 3
    type: dynamic # Use dynamic algorithm, no requirement for control limit T, S, or N values
  humidity: # Humidity related algorithm settings
    lambda: 0.25
    lFactor: 3
    controlT: 80
    controlS: 20
    controlN: 10
```

### Http Interface

__Important Note__: The anomaly detection server is a _stateful server_, meaning that it will keep track of the EWMA values and control limits over time. If the pod is destroyed and then reinitialized, the state will be lost and the EWMA will be recalculated starting from the initial value of 0. All algorithms in the anomaly detector use a recursive algorithm, where the ewma value and control limits calculated at observation $i$ depends on those calculated at $i - 1$ (as well as the newly observed value). Algorithms in a mathematical notation can be viewed in the sections that follow, while all implementations can be found in the `./lib/ewma` package of this directory.

#### Example Input

```json
// POST localhost:3333/anomaly
{
  "payload": {
    "Payload": {
      "assetID": "Tac_S1",
      "asset_id": "Tac_S1",
      "asset_name": "Tacoma_Slicer_Tacoma_Slicer__asset_0",
      "humidity": 82.34915832237789,
      "machine_status": 1,
      "maintenanceStatus": "Upcoming",
      "name": "Contoso",
      "operating_time": 5999,
      "serialNumber": "SN010",
      "site": "Tacoma",
      "source_timestamp": "2023-11-02T20:27:09.143Z",
      "temperature": 93.56069711661576,
      "vibration": 50.98858025013501
    }
  }
}
```

#### Example Output with No Anomalies

```json
// Status 200 OK
{
  "payload": {
    "payload": {
      "asset_id": "Tac_S1",
      "asset_name": "Tacoma_Slicer_Tacoma_Slicer__asset_0",
      "maintainence_status": "",
      "name": "Contoso",
      "serialNumber": "SN010",
      "site": "Tacoma",
      "source_timestamp": "2023-11-02T20:27:09.143Z",
      "operating_time": 5999,
      "machineStatus": 0,
      "humidity": 82.34915832237789,
      "temperature": 93.56069711661576,
      "vibration": 50.98858025013501,
      "humidityAnomalyFactor": 77.71178778387797,
      "humidityAnomaly": false,
      "temperatureAnomalyFactor": 88.2919654233107,
      "temperatureAnomaly": false,
      "vibrationAnomalyFactor": 48.11723408620391,
      "vibrationAnomaly": false
    }
  }
}
```

#### Example Output with Anomalies

```json
// Status 200 OK
{
  "payload": {
    "payload": {
      "asset_id": "Tac_S1",
      "asset_name": "Tacoma_Slicer_Tacoma_Slicer__asset_0",
      "maintainence_status": "",
      "name": "Contoso",
      "serialNumber": "SN010",
      "site": "Tacoma",
      "source_timestamp": "2023-11-02T20:27:09.143Z",
      "operating_time": 5999,
      "machineStatus": 0,
      "humidity": 1082.349158322378, // Humidity has an anomaly.
      "temperature": 93.56069711661576,
      "vibration": 50.98858025013501,
      "humidityAnomalyFactor": 328.87113041850296, // Anomaly factor rose sharply.
      "humidityAnomaly": true, // Humidity anomaly was detected.
      "temperatureAnomalyFactor": 89.60914834663697,
      "temperatureAnomaly": false,
      "vibrationAnomalyFactor": 48.83507062718669,
      "vibrationAnomaly": false
    }
  }
}
```

## Algorithms

Use the `type: dynamic` property in the configuration to choose an algorithm from the following.

### Algorithm #1 - Control Limit Formula with Estimated Control Limits

$$B = L\frac{S}{\sqrt{n}}\sqrt{\frac{\lambda}{2 - \lambda}[1 - (1 - \lambda)^{2i}]}$$

$$B_u = T + B$$

$$B_l = T - B$$

<center>

| Symbol    | Meaning                                       |
| --------- | --------------------------------------------- |
| $B$       | Control Limit Value                           |
| $B_u$     | Upper Control Limit                           |
| $B_l$     | Lower Control Limit                           |
| $L$       | L Factor                                      |
| $\lambda$ | Lambda Factor $(0 \leq \lambda \leq 1)$       |
| $i$       | Iteration or Count                            |
| $T$       | Constant Estimation of Sample Mean            |
| $S$       | Constant Estimation of Sample Std Dev         |
| $n$       | Constant Estimation of Rational Subgroup Size |

</center>

### Algorithm #2 - Control Limit Formula with Dynamically Evaluated Control Limits (`type: dynamic`)

$$B = L\sigma_i\sqrt{\frac{\lambda}{2 - \lambda}[1 - (1 - \lambda)^{2i}]}$$

$$B_u = \mu_i + B$$

$$B_l = \mu_i - B$$

<center>

| Symbol     | Meaning                                 |
| ---------- | --------------------------------------- |
| $B$        | Control Limit Value                     |
| $B_u$      | Upper Control Limit                     |
| $B_l$      | Lower Control Limit                     |
| $L$        | L Factor                                |
| $\lambda$  | Lambda Factor $(0 \leq \lambda \leq 1)$ |
| $i$        | Iteration or Count                      |
| $\mu_i$    | Sample Mean from Iteration $i$          |
| $\sigma_i$ | Sample Std Dev from Iteration $i$       |

</center>

### EWMA Value and Anomaly Detection Conditions

The following formulas are shared between the two algorithms.

**EWMA Value Formula**

$$z_{i} = \lambda x_i + (1 - \lambda)z_{i-1}$$

**Anomaly Condition**

$$
a=
\begin{cases}
0, & \text{if } B_l \leq z_i \leq B_u \\
1, & \text{otherwise}
\end{cases}
$$

<center>

| Symbol    | Meaning                                   |
| --------- | ----------------------------------------- |
| $B_u$     | Upper Control Limit                       |
| $B_l$     | Lower Control Limit                       |
| $\lambda$ | Lambda Factor $(0 \leq \lambda \leq 1)$   |
| $i$       | Iteration or Count                        |
| $x_i$     | Observed Value from Iteration $i$         |
| $z_i$     | EWMA Value for Iteration $i$              |
| $a$       | Anomaly Occurance, $1$ Implies an Anomaly |

</center>
