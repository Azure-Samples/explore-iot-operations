# Deploying Azure IoT Operations

In this section a basic "development" Azure IoT Operations cluster will be deployed to the previously Arc enabled clusters on level2, level3, and level4. While this will demonstrate the buildout of all levels they are not all required if the intention is not to move data to the cloud. For a production usage the deployments being done should follow the Azure IoT Operations documentation around production usage.

## Prerequisites

- The jump box has been configured as outlined previously with Azure CLI and Kubectl on it, configured to communicate with each cluster by switching context

- Contributor access to an Azure subscription where the instance is to be deployed

- Completed the Arc Enabling the Clusters steps

## Special Notes

> [!NOTE]
>
> Do to the time taken to in deployment at some of the lower levels the Azure CLI may require logging in again throughout the process. In several cases after the second deployment the "az iot ops create" command appeared to site idle, never showing the "Azure IoT Operations with Workflow Id". After this occurred cancellation of the operation, logging in (az login --use-device-code) was required (remember to check the subscription is correct before retrying).



## Deploy AIO to level4

- Set the environment variables for the level4

  ```bash
  SUBSCRIPTION_ID="<Subscription_Id>"
  
  # A list can be retrieved using 
  # az account list-locations --query "sort_by([].{Location:name}, &Location)" -o table
  LOCATION="<Azure_Location>"
  
  # The resource group the cluster was deployed to
  RESOURCE_GROUP="<Resource_Group>"
  CLUSTER_NAME="<Cluster_Name>"
  
  # Schema registry details
  STORAGE_ACCOUNT="<Storage_Account_Name>"
  CONTAINER_NAME="<Container_Name>"
  SCHEMA_REGISTRY_NAME="<Schema_Registry_Name>"
  SCHEMA_NAMESPACE="<Schema_Registry_Namespace>"
  
  # AIO Instance Deployment
  CUSTOM_LOCATION="<Custom_Location_Name>"
  AIO_INSTANCE="<AIO_Instance_Name>"
  ```

- Set Azure to the right subscription

  ```bash
  # When prompted copy the code provided and log in to Azure using the link provided
  az login --use-device-code
  
  az account set -s "${SUBSCRIPTION_ID}"
  ```

  

- Create the Schema Registry

  ```bash
  # Create a storage account in the same resource group as the cluser
  az storage account create --name "${STORAGE_ACCOUNT}" --resource-group "${RESOURCE_GROUP}" --sku Standard_LRS --kind StorageV2 --hierarchical-namespace true --allow-shared-key-access false
  
  # Create the container
  az storage container create --name "${CONTAINER_NAME}" --account-name "${STORAGE_ACCOUNT}" --auth-mode login
  
  # Create the schema registry
  az iot ops schema registry create  --subscription "${SUBSCRIPTION_ID}"  -g "${RESOURCE_GROUP}"  -n ${SCHEMA_REGISTRY_NAME}  --registry-namespace ${SCHEMA_NAMESPACE}  --sa-resource-id /subscriptions/${SUBSCRIPTION_ID}/resourcegroups/${RESOURCE_GROUP}/providers/Microsoft.Storage/storageAccounts/${STORAGE_ACCOUNT}  --sa-container ${CONTAINER_NAME}
  
  ```

  ![image-20250411122631841](.\images\image-20250411122631841.png)

- Initialize the cluster for Azure IoT Operations

  ```bash
  # Initialize the cluster for AIO
  az iot ops init  --subscription "${SUBSCRIPTION_ID}"  -g "${RESOURCE_GROUP}"  --cluster "${CLUSTER_NAME}"
  
  ```
  
  ![image-20250412111152782](.\images\image-20250412111152782.png)
  
  
  
- Deploy Azure IoT Operations to the cluster

  ```bash
  # Deploy AIO
  az iot ops create  --subscription "${SUBSCRIPTION_ID}"  -g "${RESOURCE_GROUP}"  --cluster "${CLUSTER_NAME}"  --custom-location ${CUSTOM_LOCATION}  -n ${AIO_INSTANCE}  --sr-resource-id /subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.DeviceRegistry/schemaRegistries/${SCHEMA_REGISTRY_NAME}  --broker-frontend-replicas 1  --broker-frontend-workers 1  --broker-backend-part 1  --broker-backend-workers 1  --broker-backend-rf 2  --broker-mem-profile Low  
  ```

  ![image-20250412124215901](.\images\image-20250412124215901.png)

  

  

- 

## Deploy AIO to level3

- Set the environment variables for the level3

  ```bash
  SUBSCRIPTION_ID="<Subscription_Id>"
  
  # A list can be retrieved using 
  # az account list-locations --query "sort_by([].{Location:name}, &Location)" -o table
  LOCATION="<Azure_Location>"
  
  # The resource group the cluster was deployed to
  RESOURCE_GROUP="<Resource_Group>"
  CLUSTER_NAME="<Cluster_Name>"
  
  # Schema registry details
  STORAGE_ACCOUNT="<Storage_Account_Name>"
  CONTAINER_NAME="<Container_Name>"
  SCHEMA_REGISTRY_NAME="<Schema_Registry_Name>"
  SCHEMA_NAMESPACE="<Schema_Registry_Namespace>"
  
  # AIO Instance Deployment
  CUSTOM_LOCATION="<Custom_Location_Name>"
  AIO_INSTANCE="<AIO_Instance_Name>"
  ```

- Set Azure to the right subscription

  ```bash
  # When prompted copy the code provided and log in to Azure using the link provided
  az login --use-device-code
  
  az account set -s "${SUBSCRIPTION_ID}"
  ```

  

- Create the Schema Registry

  ```bash
  # Create a storage account in the same resource group as the cluser
  az storage account create --name "${STORAGE_ACCOUNT}" --resource-group "${RESOURCE_GROUP}" --sku Standard_LRS --kind StorageV2 --hierarchical-namespace true
  
  # Create the container
  az storage container create --name "${CONTAINER_NAME}" --account-name "${STORAGE_ACCOUNT}" --auth-mode login
  
  # Create the schema registry
  az iot ops schema registry create  --subscription "${SUBSCRIPTION_ID}"  -g "${RESOURCE_GROUP}"  -n ${SCHEMA_REGISTRY_NAME}  --registry-namespace ${SCHEMA_NAMESPACE}  --sa-resource-id /subscriptions/${SUBSCRIPTION_ID}/resourcegroups/${RESOURCE_GROUP}/providers/Microsoft.Storage/storageAccounts/${STORAGE_ACCOUNT}  --sa-container ${CONTAINER_NAME}
  
  ```

  ![image-20250411170830830](.\images\image-20250411170830830.png)

  

- Initialize the cluster for Azure IoT Operations

  ```bash
  # Initialize the cluster for AIO
  az iot ops init  --subscription "${SUBSCRIPTION_ID}"  -g "${RESOURCE_GROUP}"  --cluster "${CLUSTER_NAME}"
  
  ```
  
  ![image-20250412131036940](.\images\image-20250412131036940.png)
  
  
  
  
  
- Deploy Azure IoT Operations to the cluster

  ```bash
  # Deploy AIO
  az iot ops create  --subscription "${SUBSCRIPTION_ID}"  -g "${RESOURCE_GROUP}"  --cluster "${CLUSTER_NAME}"  --custom-location ${CUSTOM_LOCATION}  -n ${AIO_INSTANCE}  --sr-resource-id /subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.DeviceRegistry/schemaRegistries/${SCHEMA_REGISTRY_NAME}  --broker-frontend-replicas 1  --broker-frontend-workers 1  --broker-backend-part 1  --broker-backend-workers 1  --broker-backend-rf 2  --broker-mem-profile Low  
  ```

  ![image-20250412134320834](.\images\image-20250412134320834.png)

  

- t







## Deploy AIO to level2

- Set the environment variables for the level2

  ```bash
  SUBSCRIPTION_ID="<Subscription_Id>"
  
  # A list can be retrieved using 
  # az account list-locations --query "sort_by([].{Location:name}, &Location)" -o table
  LOCATION="<Azure_Location>"
  
  # The resource group the cluster was deployed to
  RESOURCE_GROUP="<Resource_Group>"
  CLUSTER_NAME="<Cluster_Name>"
  
  # Schema registry details
  STORAGE_ACCOUNT="<Storage_Account_Name>"
  CONTAINER_NAME="<Container_Name>"
  SCHEMA_REGISTRY_NAME="<Schema_Registry_Name>"
  SCHEMA_NAMESPACE="<Schema_Registry_Namespace>"
  
  # AIO Instance Deployment
  CUSTOM_LOCATION="<Custom_Location_Name>"
  AIO_INSTANCE="<AIO_Instance_Name>"
  ```

- Set Azure to the right subscription

  ```bash
  # When prompted copy the code provided and log in to Azure using the link provided
  az login --use-device-code
  
  az account set -s "${SUBSCRIPTION_ID}"
  ```

  

- Create the Schema Registry

  ```bash
  # Create a storage account in the same resource group as the cluser
  az storage account create --name "${STORAGE_ACCOUNT}" --resource-group "${RESOURCE_GROUP}" --sku Standard_LRS --kind StorageV2 --hierarchical-namespace true
  
  # Create the container
  az storage container create --name "${CONTAINER_NAME}" --account-name "${STORAGE_ACCOUNT}" --auth-mode login
  
  # Create the schema registry
  az iot ops schema registry create  --subscription "${SUBSCRIPTION_ID}"  -g "${RESOURCE_GROUP}"  -n ${SCHEMA_REGISTRY_NAME}  --registry-namespace ${SCHEMA_NAMESPACE}  --sa-resource-id /subscriptions/${SUBSCRIPTION_ID}/resourcegroups/${RESOURCE_GROUP}/providers/Microsoft.Storage/storageAccounts/${STORAGE_ACCOUNT}  --sa-container ${CONTAINER_NAME}
  
  ```

  ![image-20250411193447400](.\images\image-20250411193447400.png)

  

  

- Initialize the cluster for Azure IoT Operations

  ```bash
  
  # Initialize the cluster for AIO
  az iot ops init  --subscription "${SUBSCRIPTION_ID}"  -g "${RESOURCE_GROUP}"  --cluster "${CLUSTER_NAME}"
  
  ```
  
  ![image-20250412140637107](.\images\image-20250412140637107.png)
  
  
  
  Deploy Azure IoT Operations to the cluster
  
  ```bash
  # Deploy AIO
  az iot ops create  --subscription "${SUBSCRIPTION_ID}"  -g "${RESOURCE_GROUP}"  --cluster "${CLUSTER_NAME}"  --custom-location ${CUSTOM_LOCATION}  -n ${AIO_INSTANCE}  --sr-resource-id /subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.DeviceRegistry/schemaRegistries/${SCHEMA_REGISTRY_NAME}  --broker-frontend-replicas 1  --broker-frontend-workers 1  --broker-backend-part 1  --broker-backend-workers 1  --broker-backend-rf 2  --broker-mem-profile Low  
  ```
  
  ![image-20250412170828808](.\images\image-20250412170828808.png)
  
  
  
  ## Previous Steps
  
  1. [Overview](./README.md)
  1. Learn [How Azure IOT Operations Works in a Segmented Network](./How Does AIO Work in Segmented Networks.md)
  3. Learn how to use Core DNS and Envoy Proxy in [Configure the Infrastructure](./Configure the Infrastructure.md).
  4. Learn how to [Arc enable the K3s clusters](./Arc Enabling the Clusters.md).
  
  ## Next Steps
  
  1. Learn how to [flow asset telemetry](./Asset Telemetry.md) through the deployments into Azure Event Hubs.
  
  ## Related
  
  For lab preparation, see [prerequisites](./prerequisites.md).