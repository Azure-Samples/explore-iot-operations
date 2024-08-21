# Steps to create a Contextual app for state store

This application reads from a endpoint that could be either a HTTP endpoint or a SQL endpoint and 
inserts the data to State Store which is running as a part of MQTT broker. The application has 2 parts:
1. A sample Node.js Service (just for testing)
2. Contextual App for State Store in C#


## 1: A sample Node.js Service (just for testing)
A sample Node.js service has been created to test the Contextual app for State Store. 
The service is a simple Express.js server that listens on port 80 and returns a JSON response.
The service has been containerized and can be deployed to Kubernetes.
Currently this service works using username and password authentication.

If you are on a k3d cluster, you can use the local registry to push the image. 
To do this, you need to run the following command to create the registry:
```bash
k3d registry create registry.localhost --port 5500
k3d cluster create -p '1883:1883@loadbalancer' -p '8883:8883@loadbalancer' --registry-use k3d-registry.localhost:5500
```

All commands assume that a local registry is  being used. If not, please replace the registry name with the chosen registry.

### 1. Run the Node.js Service

1. Navigate to the `DummyService` directory
2. Build and push the container image using the following command with:
	```bash
    docker build -t localhost:5500/my-backend-api .
	docker push localhost:5500/my-backend-api
	```
3. Deploy the Node.js Service to Kubernetes by running the following command. Please use the correct image name in the yaml file.
	```bash
	kubectl apply -f backend-api.yaml
	```
4. Verify that the Node.js Service is running by running the following command:
	```bash
	kubectl get pods -A
	```
5. On the logs of the pod, the following message should be seen:
	```bash
	kubectl logs $(kubectl get pods -l app=my-backend-api-d -o jsonpath="{.items[0].metadata.name}")
    Server listening on port 80
	```

### 2. Run the Contextual App for State Store

1. While being in the folder `ContextAppForDSS` directory there are 2 yamls that need to be prepopulated with the correct values:
- `console-app-secret.yaml` : This contains base64 encoded username and password for the Node.js service. Base64 encoding can be done using the following command:
	```bash
	echo -n 'myusername' | base64
	echo -n 'mysecretpassword' | base64
	```
Replace these values in the above file with the base64 encoded value.
- `context-app-configmap.yaml` : This file contains the configuration for the Context App for State Store. The following values need to be updated:

| Variable Name             | What It Means                                                                                       | Type   | Is It Required | Default Value      |
|---------------------------|-----------------------------------------------------------------------------------------------------|--------|----------------|--------------------|
| `ENDPOINT_TYPE`           | Specifies the type of endpoint to connect to. Values are "http" or "sql".                           | string | Yes            | None               |
| `AUTH_TYPE`               | Defines the authentication method. Values are "httpbasic" and "sqlbasic".                           | string | Yes            | None               |
| `REQUEST_INTERVAL_SECONDS`| The interval in seconds between consecutive requests to the data source.                            | integer| No             | 5                  |
| `DSS_KEY`                 | A key used to identify or categorize the data being processed.                                      | string | Yes            | None               |
| `MQTT_HOST`               | The IP address or hostname of the MQTT broker.                                                      | string | Yes            | None               |
| `MQTT_CLIENT_ID`          | The client ID used to connect to the MQTT broker. Should be unique for each client.                 | string | Yes            | None               |
| `HTTP_BASE_URL`           | The base URL of the HTTP endpoint.                                                                  | string | Yes (if `ENDPOINT_TYPE` is `http`) | None       |
| `HTTP_PATH`               | The specific path or resource to access on the HTTP endpoint.                                       | string | Yes (if `ENDPOINT_TYPE` is `http`) | None       |


2. Deploy the above secret and config map before deploying the app. Run the following commands:
	```bash
	kubectl apply -f console-app-secret.yaml
	kubectl apply -f context-app-configmap.yaml
	```
3. Dotnet build the application by running the following command:
	```bash
	dotnet build
	```
4. This project contains the necessary `.csproj` to containerize the application with `dotnet publish`. Replace the registry name with the chosen registry. 
The following is an example of pushing to local registry. Skip steps 5 and 6 if using this method.
	```bash
	dotnet publish /t:PublishContainer ContextAppForDSS/ContextAppForDSS.csproj /p:ContainerRegistry=localhost:5500
	```
5. In case of docker commands please use the Dockerfile in the project root to build and push the image.
```docker
# Use the official .NET SDK image as a build stage
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build

# Set the working directory
WORKDIR /app

# Copy the NuGet.config file
COPY NuGet.config ./

# Copy the project file and restore dependencies
COPY ContextAppForDSS/ContextAppForDSS.csproj ./ContextAppForDSS/
RUN dotnet restore ./ContextAppForDSS/ContextAppForDSS.csproj

# Copy the remaining source code and build the application
COPY ContextAppForDSS/ ./ContextAppForDSS/
RUN dotnet publish ./ContextAppForDSS/ContextAppForDSS.csproj -c Release -o out

# Use the official .NET runtime image as a runtime stage
FROM mcr.microsoft.com/dotnet/aspnet:8.0 AS runtime
WORKDIR /app
COPY --from=build /app/out .

# Set the entry point for the application
ENTRYPOINT ["dotnet", "ContextAppForDSS.dll"]
```
6. Containerize and push the application by running the following command choosing the correct registry.
	```bash
	docker build -t localhost:5500/context-app-for-dss .
    docker push localhost:5500/context-app-for-dss
	```
7. Deploy the Context App for State Store to Kubernetes by running the following command:
	```bash
	kubectl apply -f console-app-deployment.yaml
	```
8. On the logs of the pod, the following message should be seen with regular intervals:
	```bash
    kubectl logs $(kubectl get pods -l app=console-app-deployment -o jsonpath="{.items[0].metadata.name}")
	Retrieve data from at source.
	Store data in Distributed State Store.
	```