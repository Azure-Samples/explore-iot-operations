# Mock Sensors for Azure IoT Operations

This collection provides containerized mock sensors designed for rapid integration and testing with Azure IoT Operations. These sensors simulate real-world industrial hardware, enabling solution architects and developers to validate data flows and downstream analytics without requiring physical devices.

**Key Features:**
- Simulate weather, air quality (SPOD), camera (DCAM via SSE protocol), and invalid sensor data
- Expose HTTP endpoints for polling and event streaming (DCAM uses Server-Sent Events)
- Deployable to Azure Container Instances or any cloud/container environment

These mock sensors are ideal for:
- Prototyping and validating Azure IoT Operations pipelines
- Testing error handling and data ingestion logic

## Overview

The mock devices include:

- **Weather Mock Sensor**: Simulates weather data (temperature, humidity, wind speed, atmospheric pressure) and is designed to emulate a RainWise weather station.
- **SPOD Mock Sensor**: Simulates SPOD sensor readings, specifically for SENSIT SPOD air quality sensors.
- **Invalid Mock Sensor**: Produces malformed data for error handling testing.
- **DCAM Mock Device**: Simulates camera data and confidence readings using Server-Sent Events (SSE) ([documentation here](./dcam-mock-sensor-sse/dcam-mock-sensor.md)).

These mock devices are designed for integration and testing in any IoT or cloud environment. Each sensor exposes HTTP endpoints for polling or event streaming.

## Prerequisites

Before deploying, ensure you have:
- [Docker](https://docs.docker.com/get-docker/)
- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) (for Azure deployments)
- [Azure Container Registry](https://learn.microsoft.com/en-us/azure/container-registry/) (ACR) access or another container registry
---

## Deployment Steps


### 1. Build and Push Docker Images

Set environment variables as needed:

```bash
export RESOURCE_GROUP="<your-resource-group>"
export ACR_NAME="<your-acr-name>"
export WEATHER_IMAGE_NAME="weather-mock-sensor"
export SPOD_IMAGE_NAME="spod-mock-sensor"
export INVALID_IMAGE_NAME="invalid-mock-sensor"
export IMAGE_VERSION="<your-image-version>"
```

Build and push each mock sensor image:

```bash
# Login to your container registry
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

### 2. Deploy Mock Sensors 

Deploy each mock sensor as an Azure Container Instance using the Azure CLI. Use the following template command, substituting the appropriate sensor name, image name, and DNS label for each sensor:

```bash
az container create \
   --resource-group $RESOURCE_GROUP \
   --name <sensor-name> \
   --image $ACR_NAME.azurecr.io/<image-name>:$IMAGE_VERSION \
   --registry-login-server $ACR_NAME.azurecr.io \
   --registry-username $SP_APP_ID \
   --registry-password $SP_SECRET \
   --ip-address Public \
   --dns-name-label "<your-dns-label>" \
   --ports 8080 \
   --os-type Linux \
   --cpu 1 \
   --memory 1.5
```

For example, to deploy the weather mock sensor:

```bash
az container create \
   --resource-group $RESOURCE_GROUP \
   --name $WEATHER_IMAGE_NAME \
   --image $ACR_NAME.azurecr.io/$WEATHER_IMAGE_NAME:$IMAGE_VERSION \
   --registry-login-server $ACR_NAME.azurecr.io \
   --registry-username $SP_APP_ID \
   --registry-password $SP_SECRET \
   --ip-address Public \
   --dns-name-label "weather-mock-sensor-iot" \
   --ports 8080 \
   --os-type Linux \
   --cpu 1 \
   --memory 1.5
```

After deployment, you can get the endpoint for each sensor using:

```bash
az container show -g $RESOURCE_GROUP -n weather-mock-sensor --query ipAddress.fqdn -o tsv
az container show -g $RESOURCE_GROUP -n spod-mock-sensor --query ipAddress.fqdn -o tsv
az container show -g $RESOURCE_GROUP -n invalid-mock-sensor --query ipAddress.fqdn -o tsv
```

The endpoint will be in the format:

```
http://<your-dns-label>.<region>.azurecontainer.io:8080
```

After retrieving the endpoint from the Azure CLI command, set an environment variable for each sensor to use in your API calls. For example:

```
export WEATHER_SENSOR_ENDPOINT="http://weather-mock-sensor-iot.eastus2.azurecontainer.io:8080"
export SPOD_SENSOR_ENDPOINT="http://spod-mock-sensor-iot.eastus2.azurecontainer.io:8080"
export INVALID_SENSOR_ENDPOINT="http://invalid-mock-sensor-iot.eastus2.azurecontainer.io:8080"
```

---

## Using Mock Sensors

### Accessing Sensor Endpoints

Use the endpoints returned from the Azure CLI commands above to interact with each sensor.

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

All mock devices use pinned dependency versions for security. To verify package security:

```bash
pip install pip-audit
# Run in each mock sensor folder
pip-audit -r requirements.txt
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

You may need to delete the existing container first if redeployment is not successful before deploying again:

```bash
# Delete old container if replacement fails
az container delete -g $RESOURCE_GROUP -n weather-mock-sensor --yes
```
