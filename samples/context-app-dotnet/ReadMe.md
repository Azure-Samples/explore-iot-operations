# Steps to create a Contextual app for state store

This application reads from a endpoint that could be either a HTTP endpoint or a SQL endpoint and 
inserts the data to State Store which is running as a part of MQTT broker. The application has 3 parts:
1. A sample Node.js Service (just for testing)
2. A sample SQL Server (just for testing)
3. Contextual App for State Store in C#

Please refer to [official documentation](https://learn.microsoft.com/en-us/azure/iot-operations/manage-mqtt-broker/overview-iot-mq) for broker information and how to set up the broker.

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

All commands assume that a local registry is being used. If not, please replace the registry name with the chosen registry.

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
### 3. Run the Contextual App for State Store

While being in the folder `ContextAppForDSS` directory there are 2 yamls that need to be prepopulated with the correct values

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


2.`context-app-configmap.yaml` : This file contains the configuration for the Context App for State Store. The following values need to be updated:

| Variable Name              | What It Means                                                                                       | Type    | Is It Required                        | Default Value |
|----------------------------|-----------------------------------------------------------------------------------------------------|---------|---------------------------------------|---------------|
| `ENDPOINT_TYPE`            | Specifies the type of endpoint to connect to. Values are "http" or "sql".                           | string  | Yes                                   | None          |
| `AUTH_TYPE`                | Defines the authentication method. Values are "httpbasic" and "sqlbasic".                           | string  | Yes                                   | None          |
| `REQUEST_INTERVAL_SECONDS` | The interval in seconds between consecutive requests to the data source.                            | integer | No                                    | 5             |
| `DSS_KEY`                  | A key used to identify or categorize the data being processed.                                      | string  | Yes                                   | None          |
| `MQTT_HOST`                | The IP address or hostname of the MQTT broker.                                                      | string  | Yes                                   | None          |
| `MQTT_CLIENT_ID`           | The client ID used to connect to the MQTT broker. Should be unique for each client.                 | string  | Yes                                   | None          |
| `HTTP_BASE_URL`            | The base URL of the HTTP endpoint.                                                                  | string  | Yes (if `ENDPOINT_TYPE` is `http`)    | None          |
| `HTTP_PATH`                | The specific path or resource to access on the HTTP endpoint.                                       | string  | Yes (if `ENDPOINT_TYPE` is `http`)    | None          |
| `SQL_SERVER_NAME`          | The name of the SQL server to connect to.                                                           | string  | Yes (if `ENDPOINT_TYPE` is `sql`)     | None          |
| `SQL_DB_NAME`              | The name of the database to connect to on the SQL server.                                           | string  | Yes (if `ENDPOINT_TYPE` is `sql`)     | None          |
| `SQL_TABLE_NAME`           | The name of the table to access within the specified SQL database.                                  | string  | Yes (if `ENDPOINT_TYPE` is `sql`)     | None          |
| `USE_TLS`                  | Enabling TLS for the broker, by default no TLS is used                                              | string  | No                                    | false         |

NOTE : If using TLS then either service account token or x509 certificates needs to be created. 
Please refer to the official [MQTT broker documentation](https://learn.microsoft.com/en-us/azure/iot-operations/manage-mqtt-broker/howto-configure-tls-auto?tabs=test)

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
	kubectl apply -f context-app-configmap.yaml
	```
4. Build the application by running the following command:
	```bash
	dotnet build
	```
6. This project contains the necessary `.csproj` to containerize the application with `dotnet publish`. Replace the registry name with the chosen registry. 
The following is an example of pushing to local registry. Skip steps 5 and 6 if using this method.
	```bash
	dotnet publish /t:PublishContainer ContextAppForDSS/ContextAppForDSS.csproj /p:ContainerRegistry=localhost:5500
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
8. Containerize and push the application by running the following command choosing the correct registry.
	```bash
	docker build -t localhost:5500/context-app-for-dss .
    docker push localhost:5500/context-app-for-dss
	```
9. Deploy the Context App for State Store to Kubernetes by running the following command:
	```bash
	kubectl apply -f console-app-deployment.yaml
	```
10. On the logs of the pod, the following message should be seen with regular intervals:
	```bash
    kubectl logs -l app=console-app-deployment --all-containers=true --since=0s --tail=-1 --max-log-requests=1
	Retrieve data from at source.
	Store data in Distributed State Store.
	```