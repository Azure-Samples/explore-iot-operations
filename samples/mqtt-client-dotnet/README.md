# .NET sample application for E4k

This is a .NET sample used to demonstrate how to connect an in-cluster Pod using MQTTnet to E4k, using a Kubernetes service account token.

Add the `Program.cs` and `SampleDotNetMqtt.csproj` files to your directory. The `Program.cs` is the .NET sample code and the `SampleDotNetMqtt.csproj` tells .NET how to build the application which will be needed when creating the docker image.

## Create service account for client

To create SATs, first create a Service Account. The command below creates a Service Account called `mqtt-client`.

```bash
kubectl create serviceaccount mqtt-client
```

## Build the Docker image

To build the docker image, first create a `Dockerfile` in the root of the directory, and add the following to the newly created `Dockerfile`.

Replace the following variables with your own values:
```bash
IMAGE_NAME=<image-name>
```
For example:
```bash
IMAGE_NAME=e4kpreview
```

```bash
FROM mcr.microsoft.com/dotnet/sdk:7.0 AS build-env
WORKDIR /App

# Copy everything
COPY . ./

# Build and publish a release
RUN dotnet publish --os linux -c Release -o out

# Build runtime image
FROM mcr.microsoft.com/dotnet/runtime:7.0-alpine
WORKDIR /App
COPY --from=build-env /App/out .
ENTRYPOINT ["dotnet", "SampleDotnetMqtt.dll"]
```

Next, build the image with the following command

```bash
docker build -t $IMAGE_NAME -f Dockerfile .
```

## Push the Docker image to Azure Container Registry

Create an instance of Azure Container Registry (if required). Then, push the image to the registry. _Optionally, simply deploy a pre-built image without using Azure Container Registry; see [below](#Run-pre-built-image)._

Replace the following variables with your own values:
```bash
RESOURCE_GROUP=<resource-group-name>
LOCATION=<location>
ACR_NAME=<globally unique registry-name>
```
For example:
```bash
RESOURCE_GROUP=myResourceGroup
LOCATION=eastus
ACR_NAME=mycontainerregistry$RANDOM
```

Create a resource group (if required):
```bash
az group create --name $RESOURCE_GROUP --location $LOCATION
```

Create a container registry. For ease of use, enable the admin user:

<blockquote>
<strong>Important!</strong>
The admin user account is designed for a single user to access the registry, mainly for testing purposes. We don't recommend sharing the admin account credentials with multiple users. Individual identity is recommended for users and service principals for headless scenarios. 
</blockquote>

Instead of enabling and using the admin user, you can create a service principal and use its credentials. For more information, see [Pull images from an Azure container registry to a Kubernetes cluster using a pull secret](https://learn.microsoft.com/en-us/azure/container-registry/container-registry-auth-kubernetes)


```bash
az acr create --resource-group $RESOURCE_GROUP \
  --name $ACR_NAME --sku Basic --admin-enabled true
```

When the registry is created, the output is similar to the following:
```bash
{
  "adminUserEnabled": true,
  "anonymousPullEnabled": false,
  "creationDate": "2023-02-17T16:25:33.851424+00:00",
  "dataEndpointEnabled": false,
  "dataEndpointHostNames": [],
  "encryption": {
    "keyVaultProperties": null,
    "status": "disabled"
  },
  "id": "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/myResourceGroup/providers/Microsoft.ContainerRegistry/registries/mycontainerregistry7479",
  "identity": null,
  "location": "eastus",
  "loginServer": "mycontainerregistry7479.azurecr.io",
  "name": "mycontainerregistry7479",
  "networkRuleBypassOptions": "AzureServices",
  "networkRuleSet": null,
  "policies": {
    "azureAdAuthenticationAsArmPolicy": {
      "status": "enabled"
    },
    "exportPolicy": {
      "status": "enabled"
    },
    "quarantinePolicy": {
      "status": "disabled"
    },
    "retentionPolicy": {
      "days": 7,
      "lastUpdatedTime": "2023-02-17T16:25:40.287712+00:00",
      "status": "disabled"
    },
    "softDeletePolicy": {
      "lastUpdatedTime": "2023-02-17T16:25:40.287712+00:00",
      "retentionDays": 7,
      "status": "disabled"
    },
    "trustPolicy": {
      "status": "disabled",
      "type": "Notary"
    }
  },
  "privateEndpointConnections": [],
  "provisioningState": "Succeeded",
  "publicNetworkAccess": "Enabled",
  "resourceGroup": "myResourceGroup",
  "sku": {
    "name": "Basic",
    "tier": "Basic"
  },
  "status": null,
  "tags": {},
  "type": "Microsoft.ContainerRegistry/registries",
  "zoneRedundancy": "Disabled"
}
```

Retrieve the login server:
```bash
ACR_LOGIN_SERVER=$(az acr show --name $ACR_NAME --query loginServer --output tsv)
```

Login to the registry:
```bash
az acr login --name $ACR_NAME
```
The command returns a `Login Succeeded` message once completed.

Tag the image using the `docker tag` command: 
```bash
docker tag $IMAGE_NAME $ACR_LOGIN_SERVER/$IMAGE_NAME
```

Use `docker push` to push the image to the registry instance:
```bash
docker push $ACR_LOGIN_SERVER/$IMAGE_NAME
```

## Run the Azure Container Registry image
To run the Azure Container Registry image, obtain the admin user credentials for the registry (or the service principal), create a Kubernets secret for the credentials, update the deployment yaml, then deploy. 

Retrieve the admin user password for the registry:
```bash
ADMIN_PASSWORD=$(az acr credential show --name $ACR_NAME --query passwords[0].value --output tsv)
```
Replace the following variables with your own values:
```bash
SECRET_NAME=<secret-name>
NAMESPACE=<namespace>
```
For example:
```bash
SECRET_NAME=mySecret
NAMESPACE=default
```
Create an image pull secret with the following `kubectl` command:
```bash
kubectl create secret docker-registry $SECRET_NAME \
    --namespace $NAMESPACE \
    --docker-server=$ACR_LOGIN_SERVER \
    --docker-username=$ACR_NAME \
    --docker-password=$ADMIN_PASSWORD
```

Update the supplied [./deploy/pod.yaml](./deploy/pod.yaml) file to use the Azure Container Registry image for the `spec.containers.image` value, and to include the image pull secret in an `spec.imagePullSecrets` section. For example:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: publisherclient
  labels:
    app: publisher
spec:
  serviceAccountName: mqtt-client
  volumes: 
    - name: mqtt-client-token
      projected:
        sources:
        - serviceAccountToken:
            path: mqtt-client-token
            audience: azedge-dmqtt
            expirationSeconds: 86400
  containers:
    - name: publisherclient
      image: <mycontainerregistry>.azurecr.io/e4k-playground-csharp
      volumeMounts:
        - name: mqtt-client-token
          mountPath: /var/run/secrets/tokens
      imagePullPolicy: IfNotPresent
  restartPolicy: Never
  imagePullSecrets:
    - name: mySecret
```

Deploy the pod:

```bash
kubectl apply -f ./deploy/pod.yaml
```

See the logs of the pod publishing messages using:

```bash
kubectl logs publisherclient
```

## Run pre-built image

A pre-built docker container image for the sample is available at `e4kpreview.azurecr.io/dotnetmqttsample`.

Deploy the pod:

```bash
kubectl apply -f ./deploy/pod.yaml
```

See the logs of the pod publishing messages using:

```bash
kubectl logs publisherclient
```

