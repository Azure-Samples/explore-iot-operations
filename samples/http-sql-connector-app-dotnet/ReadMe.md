﻿# Steps to create a HTTP SQL Connector For Data Enrichment and Storing it in state store

This application reads from a endpoint that could be either a HTTP endpoint or a SQL endpoint and 
inserts the data to State Store which is running as a part of MQTT broker. The application has 3 parts:
1. A sample Node.js Service (just for testing)
2. A sample SQL Server (just for testing)
3. HTTP SQL Connector App for State Store in C#

Please refer to [official documentation](https://learn.microsoft.com/en-us/azure/iot-operations/manage-mqtt-broker/overview-iot-mq) for broker information and how to set up the broker.

## 1: A sample Node.js Service (just for testing)
A sample Node.js service has been created to test the HTTP SQL Connector app for State Store. 
The service is a simple Express.js server that listens on port 80 and returns a JSON response.
The service has been containerized and can be deployed to Kubernetes.
Currently this service works using username and password authentication.

If you are on a k3d cluster, you can use the local registry to push the image. 
To do this, you need to run the following command to create the registry:
```bash
k3d registry create registry.localhost --port 5500
k3d cluster create -p '1883:1883@loadbalancer' -p '8883:8883@loadbalancer' --registry-use k3d-registry.localhost:5500
```

All commands assume that a local registry is being used. If not, please replace the registry name with the chosen registry.

### 1. Run the Node.js Service

1. Navigate to the `DummyService` directory
2. Build and push the container image using the following command with:
	```bash
    docker build -t k3d-registry.localhost:5500/my-backend-api:latest .
	docker push k3d-registry.localhost:5500/my-backend-api:latest 
	```
3. Choose username/password that the Node JS service will use to authenticate. Base 64 encode them and replace it in the secret named `my-backend-api-secrets`in the `backend_api.yaml`.
   ```bash
	echo -n "your-username" | base64
    echo -n "your-password" | base64
   ```
NOTE : The HTTP SQL Connector app will use the same username and password to authenticate with the Node.js service.
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
	kubectl logs -l app=my-backend-api-d --all-containers=true --since=0s --tail=-1 --max-log-requests=1
    Server listening on port 80
	```

### 2. Run the SQL Server

1. Navigate to the `SampleSQL` directory
2. Apply a config map which contains a set up script to create a database named `MySampleDB`, table named `CountryMeasurements` and insert some sample rows in the table.
	```bash
	kubectl apply -f sql-configmap.yaml
	```
3. Create a base64 encoded password which would be used as password for the default user of "sa". This password must contain special characters and digits.
	```bash
    echo -n 'Mystrongpassword@123' | base64
	```
4. Use the base64 value obtained above in the secret definition portion of the "sql-server.yaml"
5. Deploy the SQL Server deployment. 
	```bash
	kubectl apply -f sql-server.yaml
	```
6. The SQL server deployment may take some time to complete. After a few minutes, verify SQL Server is running by executing the following command:
	```bash
	kubectl logs -l app=mssql --all-containers=true --since=0s --tail=-1 --max-log-requests=1
	```
7. On the logs of the pod, the following message should be seen:
	```bash
	Changed database context to 'master'.
	2024-08-20 22:07:53.01 spid51      [5]. Feature Status: PVS: 0. CTR: 0. ConcurrentPFSUpdate: 1.
	2024-08-20 22:07:53.01 spid51      Starting up database 'MySampleDB'.
	2024-08-20 22:07:53.04 spid51      Parallel redo is started for database 'MySampleDB' with worker pool size [10].
	2024-08-20 22:07:53.06 spid51      Parallel redo is shutdown for database 'MySampleDB' with worker pool size [10].
	Created MySampleDB database
	Changed database context to 'MySampleDB'.
	Switched to MySampleDB database

	(4 rows affected)
	Created and populated CountryMeasurements table
	Setup script completed
	```
8. The remaining steps are optional and verify the database, table, rows have been created successfully
   Set an environment variable for the password of the "sa" user ( SA_PASSWORD=Mystrongpassword@123) before doing the following steps.

9.  Verify user "sa" can login (this will open a SQL command prompt). Type QUIT to exit the prompt.
	```bash
	kubectl exec -it $(kubectl get pods -l app=mssql -o jsonpath="{.items[0].metadata.name}") -- /opt/mssql-tools18/bin/sqlcmd -S localhost -U SA -P $SA_PASSWORD -C
	```
10. Verify that database exists by executing the following:
	```bash
	kubectl exec -it $(kubectl get pods -l app=mssql -o jsonpath="{.items[0].metadata.name}") -- /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P $SA_PASSWORD -Q "SELECT name FROM sys.databases WHERE name = 'MySampleDB'" -C
	
    name
	--------------------------------------------------------------------------------------------------------------------------------
	MySampleDB

	(1 rows affected)
	```
11. Verify table existence:
	```bash
	kubectl exec -it $(kubectl get pods -l app=mssql -o jsonpath="{.items[0].metadata.name}") -- /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P $SA_PASSWORD -d MySampleDB -Q "SELECT name FROM sys.tables WHERE name = 'CountryMeasurements'" -C
	name
	--------------------------------------------------------------------------------------------------------------------------------
	CountryMeasurements

	(1 rows affected)
	```

12. Verify data in table:
	```bash
	kubectl exec -it $(kubectl get pods -l app=mssql -o jsonpath="{.items[0].metadata.name}") -- /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P $SA_PASSWORD -d MySampleDB -Q "SELECT * FROM CountryMeasurements" -C

	ID          Country Viscosity Sweetness ParticleSize Overall
	----------- ------- --------- --------- ------------ -------
			  1 us            .50       .80          .70     .40
			  2 fr            .60       .85          .75     .45
			  3 jp            .53       .83          .73     .43
			  4 uk            .51       .81          .71     .41

	(4 rows affected)
	```
### 3. Run the HTTP SQL Connector App for State Store

If helm is being used, the following steps can be skipped and a appropriate output yaml can be generated from helm.
But `values.yaml` needs to be updated with correct values before generating the output yaml. However what values need to be used it is better to go through this section.

While being in the folder `http-sql-connector-app-dotnet` directory there are 2 yamls that need to be prepopulated with the correct values

1. `console-app-secret.yaml` : This file contains base64 encoded username/password either for Node.js service or for SQL Server. Base64 encoding can be done using the following command:
	```bash
	echo -n 'myusername' | base64
	echo -n 'mysecretpassword' | base64
	```
| Variable Name  | What It Means                                 | Endpoint Type | Auth Type  | Default value       |
|----------------|-----------------------------------------------|---------------|------------|---------------------|
| `httpusername` | Base64 encoded username when endpoint is HTTP | HTTP          | httpbasic  |None                 |
| `httppassword` | Base64 encoded password when endpoint is HTTP | HTTP          | httpbasic  |None                 |
| `sqlpassword`  | Base64 encoded password when endpoint is SQL  | SQL           | sqlbasic   |None                 |
| `sqlusername`  | Base64 encoded username when endpoint is SQL  | SQL           | sqlbasic   |"sa" for default user|

If using SQL the username is always "sa" when using the default user and the password is the one set in the previous steps.
Please populate base64 encoded values accordingly if using any other user.

2.`console-app-configmap.yaml` : This file contains the configuration for the HTTP SQL Connector App for State Store. The following values need to be updated:

#### HTTP TABLE

| Variable Name              | What It Means                                                                                       | Type    | Is It Required                        | Default Value |
|----------------------------|-----------------------------------------------------------------------------------------------------|---------|---------------------------------------|---------------|
| `ENDPOINT_TYPE`            | Specifies the type of endpoint to connect to. Values are "http" or "sql".                           | string  | Yes                                   | None          |
| `AUTH_TYPE`                | Defines the authentication method. Values are "httpbasic".                                          | string  | Yes                                   | None          |
| `REQUEST_INTERVAL_SECONDS` | The interval in seconds between consecutive requests to the data source.                            | integer | No                                    | 5             |
| `DSS_KEY`                  | A key used to identify or categorize the data being processed.                                      | string  | Yes                                   | None          |
| `MQTT_HOST`                | The IP address or hostname of the MQTT broker.                                                      | string  | Yes                                   | None          |
| `MQTT_CLIENT_ID`           | The client ID used to connect to the MQTT broker. Should be unique for each client.                 | string  | Yes                                   | None          |
| `MQTT_PORT`                | Port number for the MQTT Broker if anything other than 1883 (insecure) or 8883 (secure) is chosen.  | string  | Yes                                   | 1883 or 8883  |
| `HTTP_BASE_URL`            | The base URL of the HTTP endpoint.                                                                  | string  | Yes (if `ENDPOINT_TYPE` is `http`)    | None          |
| `HTTP_PATH`                | The specific path or resource to access on the HTTP endpoint.                                       | string  | Yes (if `ENDPOINT_TYPE` is `http`)    | None          |
| `USE_TLS`                  | Enabling TLS for the broker, by default no TLS is used                                              | string  | No                                    | false         |

#### SQL SERVER TABLE

| Variable Name              | What It Means                                                                                       | Type    | Is It Required                        | Default Value |
|----------------------------|-----------------------------------------------------------------------------------------------------|---------|---------------------------------------|---------------|
| `ENDPOINT_TYPE`            | Specifies the type of endpoint to connect to. Values are "http" or "sql".                           | string  | Yes                                   | None          |
| `AUTH_TYPE`                | Defines the authentication method. Values are "sqlbasic".                                           | string  | Yes                                   | None          |
| `REQUEST_INTERVAL_SECONDS` | The interval in seconds between consecutive requests to the data source.                            | integer | No                                    | 5             |
| `DSS_KEY`                  | A key used to identify or categorize the data being processed.                                      | string  | Yes                                   | None          |
| `MQTT_HOST`                | The IP address or hostname of the MQTT broker.                                                      | string  | Yes                                   | None          |
| `MQTT_CLIENT_ID`           | The client ID used to connect to the MQTT broker. Should be unique for each client.                 | string  | Yes                                   | None          |
| `MQTT_PORT`                | Port number for the MQTT Broker if anything other than 1883 (insecure) or 8883 (secure) is chosen.  | string  | Yes                                   | 1883 or 8883  |
| `SQL_SERVER_NAME`          | The name of the SQL server to connect to.                                                           | string  | Yes (if `ENDPOINT_TYPE` is `sql`)     | None          |
| `SQL_DB_NAME`              | The name of the database to connect to on the SQL server.                                           | string  | Yes (if `ENDPOINT_TYPE` is `sql`)     | None          |
| `SQL_TABLE_NAME`           | The name of the table to access within the specified SQL database.                                  | string  | Yes (if `ENDPOINT_TYPE` is `sql`)     | None          |
| `USE_TLS`                  | Enabling TLS for the broker, by default no TLS is used                                              | string  | No                                    | false         |

NOTE : If using TLS then either service account token or x509 certificates needs to be created. 
Please refer to the official [MQTT broker documentation](https://learn.microsoft.com/en-us/azure/iot-operations/manage-mqtt-broker/howto-configure-tls-auto?tabs=test)

3. Some additional ENV VARS that are used in various secrets.

| Environment Variable       | What It Means                                                      | Data Type | Default Value         | Is It Required                                        | Obtained From      | Where It Is Used                               |
|----------------------------|--------------------------------------------------------------------|-----------|-----------------------|-------------------------------------------------------|--------------------|------------------------------------------------|
| `HTTP_USERNAME`            | The username for HTTP basic authentication.                        | string    | None                  | Yes (if `ENDPOINT_TYPE` is `http`)                    | console-app-secret | HTTP authentication for REST endpoints         |
| `HTTP_PASSWORD`            | The password for HTTP basic authentication.                        | string    | None                  | Yes (if `ENDPOINT_TYPE` is `http`)                    | console-app-secret | HTTP authentication for REST endpoints         |
| `SQL_USERNAME`             | The username for SQL basic authentication.                         | string    | "sa" for default user | Yes (if `ENDPOINT_TYPE` is `sql` and NOT default user)| console-app-secret | SQL database authentication                    |
| `SQL_PASSWORD`             | The password for SQL basic authentication.                         | string    | None                  | Yes (if `ENDPOINT_TYPE` is `sql`)                     | console-app-secret | SQL database authentication                    |
| `CA_FILE_PATH`             | The path to the CA certificate file for TLS verification.          | string    | None                  | Yes (if TLS is used)                                  | test-ca            | TLS verification for secure connections        |
| `SAT_TOKEN_PATH`           | The path to the service account token for secure authentication.   | string    | None                  | Yes (if auth is used)                                 | sat-token-secret   | Kubernetes service account authentication      |
| `CLIENT_CERT_FILE`         | The path to the client certificate file for authentication.        | string    | None                  | Yes (if TLS and auth are used)                        | x509-secret        | Client authentication using certificates in secure connections    |
| `CLIENT_KEY_FILE`          | The path to the client private key file for authentication.        | string    | None                  | Yes (if TLS and auth are used)                        | x509-secret        | Client authentication using certificates in secure connections    |
| `CLIENT_KEY_PASSWORD`      | The password for the client private key file.                      | string    | None                  | Yes (if TLS and auth are used)                        | x509-secret        | Client private key decryption using certificates in secure connections |


#### USING AUTHENTICATION FOR CLIENTS

Some secrets are needed in `console-app-deployment.yaml` when TLS is being used.
1. For using SAT authentication the deployment requires the secret `sat-token-secret` with key `token`. To create this secret with correct key one can do:
```bash
kubectl create secret generic sat-token-secret --from-literal=token=$(kubectl create token default --duration=8760h --audience=aio-mq)
```

2. For using X509 authentication the deployment requires `x509-secret` with keys `x509.crt` and `x509.key`. 
Optionally if the key is password protected `x509_password` is also needed. For creating the above secret with correct keys one can do:
```bash
kubectl create secret generic x509-secret --from-file=x509.crt=<path/to/your/client.crt> --from-file=x509.key=<path/to/your/client.key> -from-literal=x509_password=<your_actual_password_here>
```

Either 1 or 2 is needed (NOT BOTH). Specific yaml sections are to be commented and used accordingly.

Some examples of values if using the DummyService or SQL Server:
```yaml
  HTTP_BASE_URL: "http://my-backend-api-s.default.svc.cluster.local:80" # The URL of the backend API. Replace with your own value.

  SQL_SERVER_NAME: "sqlserver-service"
  SQL_DB_NAME: "MySampleDB"
  SQL_TABLE_NAME: "CountryMeasurements"
```
3. Deploy the above secret and config map before deploying the app. Run the following commands:
	```bash
	kubectl apply -f console-app-secret.yaml
	kubectl apply -f console-app-configmap.yaml
	```
4. Build the application by running the following command:
	```bash
	dotnet build
	```
6. This project contains the necessary `.csproj` to containerize the application with `dotnet publish`. Replace the registry name with the chosen registry. 
The following is an example of pushing to local registry. Skip following steps if using this method.
	```bash
	dotnet publish /t:PublishContainer HttpSqlConnector/HttpSqlConnector.csproj /p:ContainerRegistry=k3d-registry.localhost:5500
	```
7. In case of docker commands please use the Dockerfile in the project root to build and push the image.
```docker
# Use the official .NET SDK image as a build stage
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build

# Set the working directory
WORKDIR /app

# Copy the NuGet.config file
COPY NuGet.config ./

# Copy the project file and restore dependencies
COPY HttpSqlConnector/HttpSqlConnector.csproj ./HttpSqlConnector/
RUN dotnet restore ./HttpSqlConnector/HttpSqlConnector.csproj

# Copy the remaining source code and build the application
COPY HttpSqlConnector/ ./HttpSqlConnector/
RUN dotnet publish ./HttpSqlConnector/HttpSqlConnector.csproj -c Release -o out

# Use the official .NET runtime image as a runtime stage
FROM mcr.microsoft.com/dotnet/aspnet:8.0 AS runtime
WORKDIR /app
COPY --from=build /app/out .

# Set the entry point for the application
ENTRYPOINT ["dotnet", "HttpSqlConnector.dll"]
```
8. Containerize and push the application by running the following command choosing the correct registry.
	```bash
	docker build -t k3d-registry.localhost:5500/http-sql-connector-app-dotnet:latest .
    docker push k3d-registry.localhost:5500/http-sql-connector-app-dotnet:latest
	```
9. Deploy the Http Sql Connector App for State Store to Kubernetes by running the following command:
	```bash
	kubectl apply -f console-app-deployment.yaml
	```
10. On the logs of the pod, the following message should be seen with regular intervals:
	```bash
    kubectl logs -l app=console-app-deployment --all-containers=true --since=0s --tail=-1 --max-log-requests=1
	Retrieve data from at source.
	Store data in Distributed State Store.
	```

## HELM Package 

All examples are done with Docker with a version of 0.1.0 and the name being `contextualization-app`

* Helm package it by being in folder `http-sql-connector-app-dotnet` by doing:
```bash
helm package .
```
* This will create a tgz file which can be pushed to a registry. Output will look something like:
```
Successfully packaged chart and saved it to: /http-sql-connector-app-dotnet/contextualization-app-0.1.0.tgz
```
* Store the above charts in OCI-compatible registries.
```bash
helm push contextualization-app-0.1.0.tgz oci://registry-1.docker.io/<dockerhubusername> 
```
* If any authentication issues are encountered, login with credentials: 
 ```bash
helm registry login registry-1.docker.io -u yourusername 
```
* After pushing, same chart can be pulled by using: 
```bash
helm pull oci://registry-1.docker.io/dockeroliva/contextualization-app --version 0.1.0 
```
* If a Helm chart needs to be examined using helm directly, do:
```bash
helm show all contextualization-app-0.1.0.tgz 
```
* To extract and view all files in some directory (example helmextract)
```bash
tar -xvf contextualization-app-0.1.0.tgz -C helmextract 
```
* And for direct install with a release name (mytestrelease), which will only work if updated with correct values in `values.yaml`
```bash
helm install mytestrelease oci://registry-1.docker.io/dockeroliva/contextualization-app --version 0.1.0 
```
* The above command will create a pod that starts with `mytestrelease-deployment` which can be checked by running:
```bash
kubectl logs -l app=mytestrelease-deployment
```
* To uninstall do:
```bash
helm uninstall mytestrelease
```