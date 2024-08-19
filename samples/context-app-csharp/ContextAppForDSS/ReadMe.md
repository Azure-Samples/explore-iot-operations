# Steps to create a Context App for DSS

This application reads from a endpoint that could be either a HTTP endpoint or a Sql endpoint and 
inserts the data to DSS which is running as a part of the MQ broker. The appllication has 2 parts for now:
1. A sample Node.js Service (just for testing)
2. Context App for DSS in C#


## 1: A sample Node.js Service (just for testing)
A sample Node.js service has been created to test the Context App for DSS. 
The service is a simple Express.js server that listens on port 80 and returns a JSON response.
The service has been dockerized and can be deployed to Kubernetes.
Currently this service works on username and password authentication.

### 1. Run the Node.js Service

1. Navigate to the `DummyService` directory`
2. Build the Docker image using the following command with:
	```bash
	docker build -t my-registry/my-backend-api .
	```
3. Push the Docker image to the chosen Docker registry by running the following command:
	```bash
	docker push my-registry/my-backend-api
	```
	Note: Replace `my-registry` with the chosen Docker registry.
4. Deploy the Node.js Service to Kubernetes by running the following command. Please use the correct image name in the yaml file.
	```bash
	kubectl apply -f backend-api.yaml
	```
5. Verify that the Node.js Service is running by running the following command:
	```bash
	kubectl get pods -A
	```
6. On the logs of the pod, the following message should be seen:
	```bash
	Server listening on port 80
	```

### 2. Run the Context App for DSS

1. While being in the folder `ContextAppForDSS` directory there are 2 yamls that need to be prepopulated with the correct values:
	- `console-app-secret.yaml` : This contains base 64 encoded username and password for the Node.js service. Base 64 encoding can be done using the following command:
		```bash
		echo -n 'myusername' | base64
		echo -n 'mysecretpassword' | base64
		```
		Replace thees values in the above file with the base 64 encoded value.
	
	- `context-app-configmap.yaml` : This file contains the configuration for the Context App for DSS. The following values need to be updated:
		- `ENDPOINT_TYPE`: Specifies the type of endpoint to connect to. Values are "http" or "sql".
		- `AUTH_TYPE`: Defines the authentication method. "httpbasic" indicates Basic Authentication (username/password) for HTTP. "sqlbasic" indicates Basic Authentication (username/password) for SQL.
		- `REQUEST_INTERVAL_SECONDS`: The interval in seconds between consecutive requests to the data source.
		- `DSS_KEY`: A key used to identify or categorize the data being processed.
		- `MQTT_HOST`: The IP address or hostname of the MQTT broker.
		- `MQTT_CLIENT_ID`: The client ID used to connect to the MQTT broker. This should be unique for each client.
		- `HTTP_BASE_URL`: The base URL of the HTTP endpoint. This Kubernetes service DNS name indicates it's accessing a service named "my-backend-api-s" in the "default" namespace.
		- `HTTP_PATH`: The path or specfic resource to the HTTP endpoint.

2. Deploy the above secret and config map before deploying the app. Run the following commands:
	```bash
	kubectl apply -f console-app-secret.yaml
	kubectl apply -f context-app-configmap.yaml
	```
3. Dotnet build the application by running the following command:
	```bash
	dotnet build
	```
4. Dockerize the application by running the following command.
	```bash
	docker build -t my-registry/my-context-app .
	```

5. Push the Docker image to the chosen Docker registry by running the following command:
	```bash
	docker push my-registry/my-context-app
	```
	Note: Replace `my-registry` with the chosen registry.

6. Deploy the Context App for DSS to Kubernetes by running the following command:
	```bash
	kubectl apply -f console-app-deployment.yaml
	```
7. On the logs of the pod, the following message should be seen with regular intervals:
	```bash
	Retrieve data from at source.
	Store data in Distributed State Store.
	```