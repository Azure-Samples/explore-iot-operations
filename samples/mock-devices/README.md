# Mock Devices Component

This component provides mock sensors that simulate data from various industrial sensors including weather stations, SPOD, DCAM systems. These mock devices are crucial for testing and development of the FOF solution without requiring physical hardware.

## Overview

The mock devices include:

- **Weather Mock Sensor**: Generates simulated weather data including temperature, humidity, wind speed, and atmospheric pressure
- **SPOD Mock Sensor**: Simulates readings from SPOD sensors
- **Invalid Mock Sensor**: Produces intentionally malformed data to test error handling and alert mechanisms
- **DCAM Mock Device**: Simulates camera data and confidence readings using Server-Sent Events (SSE) protocol ([documentation here](./dcam-mock-sensor-sse/dcam-mock-sensor.md))

These mock devices are designed to integrate with the Azure IoT Operations (AIO) ecosystem. The weather and SPOD sensors provide HTTP endpoints that can be polled by the Akri broker, while the DCAM device uses Server-Sent Events (SSE) to push data to subscribers.

## Prerequisites

Before deploying the mock devices, ensure you have:

- [Docker](https://docs.docker.com/get-docker/)
- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli)
- [Azure Container Registry](https://learn.microsoft.com/en-us/azure/container-registry/) (ACR) access
---

## Deployment Steps

### 1. Clone the Repository

```bash
git clone git@ssh.dev.azure.com:v3/chevron/MS-EXT-FOFEnterpriseEngagement/FOF_Pilot
cd FOF_Pilot/components/mock-devices
```

### 2. Build and Push Docker Image

#### 2.1 Set Environment Variables

Replace the values as needed:

```bash
export RESOURCE_GROUP="rg-fof" # Resource group that will hold mock device container instances
export ACR_NAME="acrfof"  # Azure Container Registry name
export WEATHER_IMAGE_NAME="weather-mock-sensor"  # Docker image name
export SPOD_IMAGE_NAME="spod-mock-sensor"  # Docker image name
export INVALID_IMAGE_NAME="invalid-mock-sensor"  # Docker image name
export IMAGE_VERSION="latest"  # Docker image version
```

#### 2.2. Build and Push Mock Sensor Images

```bash
# Login to ACR
az acr login --name $ACR_NAME

# Build and push weather sensor
docker build -t $ACR_NAME.azurecr.io/$WEATHER_IMAGE_NAME:$IMAGE_VERSION ./weather-mock-sensor
docker push $ACR_NAME.azurecr.io/$WEATHER_IMAGE_NAME:$IMAGE_VERSION

# Build and push SPOD sensor
docker build -t $ACR_NAME.azurecr.io/$SPOD_IMAGE_NAME:$IMAGE_VERSION ./spod-mock-sensor
docker push $ACR_NAME.azurecr.io/$SPOD_IMAGE_NAME:$IMAGE_VERSION

# Build and push invalid sensor
docker build -t $ACR_NAME.azurecr.io/$INVALID_IMAGE_NAME:$IMAGE_VERSION ./invalid-mock-sensor
docker push $ACR_NAME.azurecr.io/$INVALID_IMAGE_NAME:$IMAGE_VERSION
```

### 3. Deploy Mock Sensors

Deploy each mock sensor as an Azure Container Instance.

> Note: When deploying an Azure Container Instance (ACI) with the same name to the same resource group, it will replace any existing container with that name. If you want to maintain the same endpoint URL, make sure to use the same DNS suffix when redeploying.


```bash
source ../../infra/scripts/helper.sh

# You may need to run this to set SP_APP_ID and SP_SECRET
source ../../infra/scripts/init-chance-plains-subscription.sh

# Deploy sensors with different options
# Option 1: Use a custom DNS suffix (for consistent DNS naming and redeployment)
deploy_mock_sensor weather-mock-sensor ./weather-mock-sensor fof-246aa
deploy_mock_sensor spod-mock-sensor ./spod-mock-sensor fof-246aa
deploy_mock_sensor invalid-mock-sensor ./invalid-mock-sensor fof-246aa

# Option 2: Auto-generate a random DNS name label
deploy_mock_sensor weather-mock-sensor ./weather-mock-sensor

# Option 3: Pass environment variables with deployment
# You can configure the error type for invalid sensors (1=missing field, 2=wrong type, 3=out-of-range)
deploy_mock_sensor invalid-mock-sensor ./invalid-mock-sensor fof-246aa ERROR_TYPE=2

# The deployment will automatically export these variables but note the outputted export commands if needed in future
# Example endpoints generated:
export WEATHER_SENSOR_ENDPOINT="http://weather-mock-sensor-fof-246aa.eastus2.azurecontainer.io:8080"
export SPOD_SENSOR_ENDPOINT="http://spod-mock-sensor-fof-246aa.eastus2.azurecontainer.io:8080"
export INVALID_SENSOR_ENDPOINT="http://invalid-mock-sensor-fof-246aa.eastus2.azurecontainer.io:8080"
```

#### Understanding Hostname Options

The `deploy_mock_sensor` function supports two DNS naming options:

1. **Auto-generated DNS suffix** (default if no suffix provided):
   ```bash
   deploy_mock_sensor spod-mock-sensor ./spod-mock-sensor
   ```
   - Automatically generates a unique DNS suffix using timestamp and random characters
   - Results in something like: `spod-mock-sensor-35290-zzfe2.eastus2.azurecontainer.io`
   - Good for development/testing when you don't need consistent DNS names
   - Each deployment creates a new unique DNS name

2. **Custom DNS suffix** (when suffix parameter is provided):
   ```bash
   deploy_mock_sensor weather-mock-sensor ./weather-mock-sensor fof-246aa
   ```
   - The suffix is combined with the mock sensor name to form: `weather-mock-sensor-fof-246aa.eastus2.azurecontainer.io`
   - Useful for consistent naming or when redeploying to the same DNS address
   - Helpful when other systems are configured to connect to a specific DNS name
   - Required when redeploying containers to maintain the same endpoint

#### Container Updates
You may need to delete the existing container first if redeployment is not successful:

```bash
# Delete old container if replacement fails
az container delete -g $RESOURCE_GROUP -n weather-mock-sensor --yes

# Redeploy
deploy_mock_sensor weather-mock-sensor ./weather-mock-sensor fof-246aa
```

---

## Using Mock Sensors

### Accessing Sensor Endpoints

Make sure the following are set from previous step.

```bash
echo $WEATHER_SENSOR_ENDPOINT
echo $SPOD_SENSOR_ENDPOINT
echo $INVALID_SENSOR_ENDPOINT
```

### Available Endpoints

Each sensor exposes the following HTTP endpoints:

**Weather Sensor:**
- `/weather/input` - Get valid weather data
- `/healthcheck` - Check sensor health status

**SPOD Sensor:**
- `/spod/input` - Get valid SPOD data

**Invalid Sensor:**
- `/weather/invalid-input` - Get invalid weather data
- `/spod/invalid-input` - Get invalid SPOD data

Example usage:

```bash
# Get weather data
curl $WEATHER_SENSOR_ENDPOINT/weather/input

# Get SPOD data
curl $SPOD_SENSOR_ENDPOINT/spod/input

# Get invalid weather data
curl $INVALID_SENSOR_ENDPOINT/weather/invalid-input
```

## Customizing Mock Sensors

To modify the sensor data simulation:

1. Edit the Python files in the respective sensor directories:
   - `weather-mock-sensor/randomized-weather-sensor.py`
   - `spod-mock-sensor/randomized-spod-sensor.py`
   - `invalid-mock-sensor/invalid-data-sensor.py`

2. Update the ranges and simulation logic as needed
3. Rebuild and redeploy the containers

For example, to modify temperature ranges in the weather sensor, edit the `RANGES` dictionary in `randomized-weather-sensor.py`.

## Security

The DCAM mock device uses pinned dependency versions for security. To verify package security:

```bash
# Install security scanner
pip install pip-audit

# Check for vulnerabilities in requirements in each mock sensor folder
pip-audit -r requirements.txt

# Expected output: "No known vulnerabilities found"
```

## Troubleshooting

If you encounter issues with the mock sensors:

1. Check container status:
   ```bash
   az container show -g $RESOURCE_GROUP -n weather-mock-sensor
   ```

2. View container logs:
   ```bash
   az container logs -g $RESOURCE_GROUP -n weather-mock-sensor
   ```

3. Verify the container endpoint is accessible:
   ```bash
   curl $WEATHER_SENSOR_ENDPOINT/healthcheck
   ```