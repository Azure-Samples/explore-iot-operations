# DCAM Mock Device Component

This component provides a mock DCAM device that simulates data using Server-Sent Events (SSE) protocol, making it crucial for testing and development of solutions eventually requiring physical DCAM hardware.

## Overview

The DCAM mock device provides two primary endpoints:

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

Before deploying the DCAM mock device, ensure you have:

- [Docker](https://docs.docker.com/get-docker/)
- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli)
- [Azure Container Registry](https://learn.microsoft.com/en-us/azure/container-registry/) (ACR) access

## Security

The DCAM mock device uses pinned dependency versions for security. To verify package security:

```bash
# Install security scanner
pip install pip-audit

# Check for vulnerabilities in DCAM requirements
cd dcam-mock-sensor-sse
pip-audit -r requirements.txt

# Expected output: "No known vulnerabilities found"
```

## Deployment

### 1. Build and Push Docker Image

#### 1.1 Set Environment Variables

Replace the values as needed:

```bash
export RESOURCE_GROUP="rg-fof" # Resource group that will hold mock device container instances
export ACR_NAME="acrfof"  # Azure Container Registry name
export DCAM_IMAGE_NAME="dcam-mock-sensor-sse"  # Docker image name
export IMAGE_VERSION="latest"  # Docker image version
```

#### 1.2. Build and Push Mock Device Image

```bash
# Login to ACR
az acr login --name $ACR_NAME

# Build and push DCAM mock device
# from mock-devices directory
docker build -t $ACR_NAME.azurecr.io/$DCAM_IMAGE_NAME:$IMAGE_VERSION ./dcam-mock-sensor-sse
docker push $ACR_NAME.azurecr.io/$DCAM_IMAGE_NAME:$IMAGE_VERSION
```

### 2. Deploy Mock Device

Deploy DCAM mock device as an Azure Container Instance.

> **Note:** When deploying an Azure Container Instance (ACI) with the same name to the same resource group, it will replace any existing container with that name. If you want to maintain the same endpoint URL, make sure to use the same DNS suffix when redeploying.

#### Deployment Commands

**Deploy using the deployment script:**
```bash
# from mock-devices directory
source ../../infra/scripts/helper.sh

# You may need to run this to set SP_APP_ID and SP_SECRET
source ../../infra/scripts/init-chance-plains-subscription.sh

# Deploy sensors with different options
# Option 1: Use a custom DNS suffix (for consistent DNS naming and redeployment)
deploy_mock_sensor dcam-mock-sensor-sse ./dcam-mock-sensor-sse fof-246aa

# Option 2: Auto-generate a random DNS name label
deploy_mock_sensor dcam-mock-sensor-sse ./dcam-mock-sensor-sse

# The deployment will export the endpoint variable automatically but save the output of the command if needed
# Example endpoint generated:
export DCAM_SENSOR_ENDPOINT="http://dcam-mock-sensor-sse-fof-246aa.eastus2.azurecontainer.io:8080"
```

**Or deploy manually:**
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
    --dns-name-label "dcam-mock-sensor-sse-fof-246aa" \
    --ports 8080 \
    --os-type Linux \
    --cpu 1 \
    --memory 1.5
```

### 3. Verify Deployment

**Get container logs:**
```bash
az container logs -g $RESOURCE_GROUP -n dcam-mock-sensor-sse
```

**Container Updates:**
You may need to delete the old container first if redeployment is not successful
```bash
# Delete old container if replacement fails
az container delete -g $RESOURCE_GROUP -n dcam-mock-sensor-sse --yes

# Redeploy
deploy_mock_sensor dcam-mock-sensor-sse ./dcam-mock-sensor-sse fof-246aa
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
**Important:** To get `ALERT_DLQC` events, you must enable analytics. Otherwise,if analytics are disabled, you'll only get basic `ALERT` events when you start the alert generation.

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

By default, the DCAM mock device generates alerts approximately every 120 seconds (with 50% probability on each 60-second check). You can increase the frequency of alerts by reducing the `INTERVAL` environment variable:

```bash
# Reduce alert frequency by increasing the interval (in seconds)
# Higher values = fewer alerts
deploy_mock_sensor dcam-mock-sensor-sse ./dcam-mock-sensor-sse fof-246aa INTERVAL=60
# This will check for events every 30 seconds (INTERVAL/2) with the same 50% probability,
# resulting in approximately one alert every minute on average
```

Alert frequency examples:
- INTERVAL=120 (default): ~1 alert per 2 minutes
- INTERVAL=60: ~1 alert per minute  
- INTERVAL=30: ~2 alerts per minute
