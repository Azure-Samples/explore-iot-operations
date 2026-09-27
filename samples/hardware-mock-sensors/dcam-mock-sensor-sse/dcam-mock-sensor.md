
# DCAM Mock Device (General Purpose)

This component provides a general-purpose mock DCAM device that simulates data using Server-Sent Events (SSE) protocol. It is designed for testing and development of any solution that requires DCAM-like event and image streams, without needing physical hardware.

## Overview

The DCAM mock device exposes endpoints for event streaming and image snapshots:

- **`/dcam-events` endpoint**: Generates continuous event streams via SSE (Server-Sent Events) for the following event types:
  - HEARTBEAT - Regular operational status updates
  - ALERT - Detection events requiring attention
  - ALERT_DLQC - Deep learning quality control alerts
  - ANALYTICS_DISABLED - Notifications when analytics processing is turned off
  - ANALYTICS_ENABLED - Notifications when analytics processing is turned on

- **`/get-snapshot` endpoint**: Returns camera snapshot images based on query parameters:
  - `cameraId` - Identifier for the specific camera
  - `eventId` - Identifier for the specific event
  
  > Note: The current implementation returns an image from a predefined set based on a random number, regardless of the actual parameter values provided.

## Prerequisites

Before deploying, ensure you have:
- [Docker](https://docs.docker.com/get-docker/)
- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli)
- [Azure Container Registry](https://learn.microsoft.com/en-us/azure/container-registry/) (ACR) access

## Security

Dependencies are pinned for security. To check for vulnerabilities:

```bash
# Install security scanner
pip install pip-audit

# Check for vulnerabilities in DCAM requirements
cd dcam-mock-sensor-sse
pip-audit -r requirements.txt

# Expected output: "No known vulnerabilities found"
```

## Deployment

This section provides steps for building, running, and deploying the DCAM mock device. It includes instructions for deploying as an Azure Container Instance, which allows you to run containers in the cloud. For more details, see the official Azure Container Instances quickstart: [Azure Container Instances Quickstart](https://learn.microsoft.com/en-us/azure/container-instances/container-instances-quickstart).

### 1. Build and Push Docker Image

#### 1.1 Set Environment Variables

Replace the values as needed:

```bash
export RESOURCE_GROUP="<your-resource-group>" # Resource group for container instances
export ACR_NAME="<your-acr-name>"  # Azure Container Registry name
export DCAM_IMAGE_NAME="dcam-mock-sensor-sse"  # Docker image name
export IMAGE_VERSION="<your-image-version>"  # Docker image version
```

#### 1.2. Build and Push Mock Device Image

```bash
# Login to ACR
az acr login --name $ACR_NAME

# Build and push DCAM mock device
# from hardware-mock-sensors directory
docker build -t $ACR_NAME.azurecr.io/$DCAM_IMAGE_NAME:$IMAGE_VERSION ./dcam-mock-sensor-sse
docker push $ACR_NAME.azurecr.io/$DCAM_IMAGE_NAME:$IMAGE_VERSION
```

### 2. Deploy Mock Device

Deploy DCAM mock device as an Azure Container Instance.

#### Deployment Commands

When running the Azure deployment command, replace `$SP_APP_ID` and `$SP_SECRET` with your Azure service principal credentials, and replace the DNS label to a unique DNS name for your container instance.

```bash
# Deploy the container
az container create \
    --resource-group $RESOURCE_GROUP \
    --name dcam-mock-sensor-sse \
    --image $ACR_NAME.azurecr.io/$DCAM_IMAGE_NAME:$IMAGE_VERSION \
    --registry-login-server $ACR_NAME.azurecr.io \
    --registry-username $SP_APP_ID \
    --registry-password=$SP_SECRET \
    --ip-address Public \
    --dns-name-label "dcam-mock-iot" \
    --ports 8080 \
    --os-type Linux \
    --cpu 1 \
    --memory 1.5
```

After deployment, you can get the endpoint using:

```bash
az container show -g $RESOURCE_GROUP -n dcam-mock-sensor-sse --query ipAddress.fqdn -o tsv
```

The endpoint will be in the format:

```
http://<your-dns-label>.<region>.azurecontainer.io:8080
```

After retrieving the endpoint from the Azure CLI command, set an environment variable for the sensor to use in your API call:

```
export DCAM_SENSOR_ENDPOINT="http://dcam-mock-iot.eastus2.azurecontainer.io:8080"
```

### 3. Verify Deployment

**Get container logs:**
```bash
az container logs -g $RESOURCE_GROUP -n dcam-mock-sensor-sse
```

## Usage

### Default Behavior

When the DCAM mock device is first deployed, the default settings are:

- **Alerts**: Off (no alert events will be generated)
- **Analytics**: Disabled

```bash
# See current settings at any time
curl $DCAM_SENSOR_ENDPOINT/healthcheck
```

You must explicitly enable alerts after deployment using the control endpoints.

### Generating Alerts

To enable alerts:

```bash
# Enable alert generation
curl $DCAM_SENSOR_ENDPOINT/start-alert

# Disable alert generation
curl $DCAM_SENSOR_ENDPOINT/stop-alert
```
**Important:** To get `ALERT_DLQC` events, you must enable analytics. Otherwise, if analytics are disabled, you'll only get basic `ALERT` events when you start the alert generation.

To enable/disable analytics: 

```bash
# Enable analytics
curl $DCAM_SENSOR_ENDPOINT/set-analytics-enabled

# Disable analytics
curl $DCAM_SENSOR_ENDPOINT/set-analytics-disabled
```

### Available Endpoints

**Server-Sent Events:** `/dcam-events` - Continuous event streams  
**Camera Snapshots:** `/get-snapshot?cameraId=<id>&eventId=<id>` - Camera images  
**Alert Control:** `/start-alert`, `/stop-alert` - Enable/disable alerts  
**Analytics Control:** `/start-analytics`, `/stop-analytics` - Enable/disable analytics  
**Health Check:** `/healthcheck` - Device status and configuration  

### Example Usage

```bash
# Connect to event stream
curl -N $DCAM_SENSOR_ENDPOINT/dcam-events

# Get camera snapshot
curl "$DCAM_SENSOR_ENDPOINT/get-snapshot?cameraId=1&eventId=2"

# Control alerts and analytics
curl $DCAM_SENSOR_ENDPOINT/set-analytics-enabled  # Enable analytics
curl $DCAM_SENSOR_ENDPOINT/start-alert      # Enable alert generation
curl $DCAM_SENSOR_ENDPOINT/healthcheck      # Check status

curl $DCAM_SENSOR_ENDPOINT/stop-alert      # Disable alert generation
curl $DCAM_SENSOR_ENDPOINT/set-analytics-disabled  # Disable analytics
```

### Adjusting Alert Frequency

By default, alerts are generated approximately every 120 seconds (50% probability per 60-second check). To adjust alert frequency in Azure Container Instance, set the INTERVAL environment variable using the `--environment-variables` flag during deployment:

```bash
az container create \
  --resource-group $RESOURCE_GROUP \
  --name dcam-mock-sensor-sse \
  --image $ACR_NAME.azurecr.io/$DCAM_IMAGE_NAME:$IMAGE_VERSION \
  --registry-login-server $ACR_NAME.azurecr.io \
  --registry-username $SP_APP_ID \
  --registry-password $SP_SECRET \
  --ip-address Public \
  --dns-name-label "dcam-mock-iot" \
  --ports 8080 \
  --os-type Linux \
  --cpu 1 \
  --memory 1.5 \
  --environment-variables INTERVAL=60
```
This will check for events every 30 seconds (INTERVAL/2), resulting in approximately one alert per minute on average.

Examples:
- INTERVAL=120 (default): ~1 alert per 2 minutes
- INTERVAL=60: ~1 alert per minute
- INTERVAL=30: ~2 alerts per minute
