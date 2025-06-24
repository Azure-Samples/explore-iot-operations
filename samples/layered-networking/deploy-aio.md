# Deploying Azure IoT Operations

In this section a basic "development" Azure IoT Operations cluster will be deployed to the previously Arc enabled clusters on level2, level3, and level4. While this will demonstrate the buildout of all levels they are not all required if the intention is not to move data to the cloud. For a production usage the deployments being done should follow the Azure IoT Operations documentation around production usage.

## Prerequisites

- The jump box has been configured as outlined [preparing the jump box](./prerequisites.md#preparing-the-jump-box). Make sure it's set up to communicate with each cluster by switching context.

- Contributor access to an Azure subscription where the instance is to be deployed

- Completed [Arc enable the K3s clusters](./arc-enable-clusters.md)

## Special Notes

> [!NOTE]
>
> Do to the time taken to in deployment at some of the lower levels the Azure CLI may require logging in again throughout the process. In several cases after the second deployment the `az iot ops create` command appeared to site idle, never showing the "Azure IoT Operations with Workflow Id". After this occurred cancellation of the operation, logging in (az login --use-device-code) was required. Remember to check the subscription is correct before retrying.

## Deploy AIO to level4

1. Set the environment variables for the level4.

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

1. Sign in to your subscription.

    ```bash
    # When prompted copy the code provided and log in to Azure using the link provided
    az login --use-device-code
    
    az account set -s "${SUBSCRIPTION_ID}"
    ```

1. Create the schema registry.

    ```bash
    # Create a storage account in the same resource group as the cluser
    az storage account create --name "${STORAGE_ACCOUNT}" --resource-group "${RESOURCE_GROUP}" --sku Standard_LRS --kind StorageV2 --hierarchical-namespace true --allow-shared-key-access false
    
    # Create the container
    az storage container create --name "${CONTAINER_NAME}" --account-name "${STORAGE_ACCOUNT}" --auth-mode login
    
    # Create the schema registry
    az iot ops schema registry create  --subscription "${SUBSCRIPTION_ID}"  -g "${RESOURCE_GROUP}"  -n ${SCHEMA_REGISTRY_NAME}  --registry-namespace ${SCHEMA_NAMESPACE}  --sa-resource-id /subscriptions/${SUBSCRIPTION_ID}/resourcegroups/${RESOURCE_GROUP}/providers/Microsoft.Storage/storageAccounts/${STORAGE_ACCOUNT}  --sa-container ${CONTAINER_NAME}
    
    ```

    ![Screenshot of Azure CLI output for schema registry creation at level4](./images/azure-cli-schema-registry-level4.png)


1. Initialize the cluster for Azure IoT Operations

    ```bash
    # Initialize the cluster for AIO
    az iot ops init  --subscription "${SUBSCRIPTION_ID}"  -g "${RESOURCE_GROUP}"  --cluster "${CLUSTER_NAME}"
    
    ```

    ![Screenshot of Azure CLI output for AIO cluster initialization at level4](./images/azure-cli-init-level4.png)

1. Deploy Azure IoT Operations to the cluster.

    ```bash
    # Deploy AIO
    az iot ops create  --subscription "${SUBSCRIPTION_ID}"  -g "${RESOURCE_GROUP}"  --cluster "${CLUSTER_NAME}"  --custom-location ${CUSTOM_LOCATION}  -n ${AIO_INSTANCE}  --sr-resource-id /subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.DeviceRegistry/schemaRegistries/${SCHEMA_REGISTRY_NAME}  --broker-frontend-replicas 1  --broker-frontend-workers 1  --broker-backend-part 1  --broker-backend-workers 1  --broker-backend-rf 2  --broker-mem-profile Low  
    ```

    ![Screenshot of Azure CLI output for AIO deployment at level4](./images/azure-cli-deploy-level4.png)

## Deploy AIO to level3

1. Set the environment variables for the level3

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

1. Set Azure to the right subscription.

    ```bash
    # When prompted copy the code provided and log in to Azure using the link provided
    az login --use-device-code
    
    az account set -s "${SUBSCRIPTION_ID}"
    ```

1. Create the schema registry.

    ```bash
    # Create a storage account in the same resource group as the cluser
    az storage account create --name "${STORAGE_ACCOUNT}" --resource-group "${RESOURCE_GROUP}" --sku Standard_LRS --kind StorageV2 --hierarchical-namespace true
    
    # Create the container
    az storage container create --name "${CONTAINER_NAME}" --account-name "${STORAGE_ACCOUNT}" --auth-mode login
    
    # Create the schema registry
    az iot ops schema registry create  --subscription "${SUBSCRIPTION_ID}"  -g "${RESOURCE_GROUP}"  -n ${SCHEMA_REGISTRY_NAME}  --registry-namespace ${SCHEMA_NAMESPACE}  --sa-resource-id /subscriptions/${SUBSCRIPTION_ID}/resourcegroups/${RESOURCE_GROUP}/providers/Microsoft.Storage/storageAccounts/${STORAGE_ACCOUNT}  --sa-container ${CONTAINER_NAME}
    
    ```

    ![Screenshot of Azure CLI output for schema registry creation](./images/azure-cli-schema-registry-level3.png)

1. Initialize the cluster for Azure IoT Operations.

    ```bash
    # Initialize the cluster for AIO
    az iot ops init  --subscription "${SUBSCRIPTION_ID}"  -g "${RESOURCE_GROUP}"  --cluster "${CLUSTER_NAME}"
    ```

    ![Screenshot of Azure CLI output for AIO cluster initialization](./images/azure-cli-init-level3.png)

1. Deploy Azure IoT Operations to the cluster.

    ```bash
    # Deploy AIO
    az iot ops create  --subscription "${SUBSCRIPTION_ID}"  -g "${RESOURCE_GROUP}"  --cluster "${CLUSTER_NAME}"  --custom-location ${CUSTOM_LOCATION}  -n ${AIO_INSTANCE}  --sr-resource-id /subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.DeviceRegistry/schemaRegistries/${SCHEMA_REGISTRY_NAME}  --broker-frontend-replicas 1  --broker-frontend-workers 1  --broker-backend-part 1  --broker-backend-workers 1  --broker-backend-rf 2  --broker-mem-profile Low  
    ```

    ![Screenshot of Azure CLI output for AIO deployment](./images/azure-cli-deploy-level3.png)

## Deploy AIO to level2

1. Set the environment variables for the level2.

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

1. Sign in to your subscription.

    ```bash
    # When prompted copy the code provided and log in to Azure using the link provided
    az login --use-device-code
    
    az account set -s "${SUBSCRIPTION_ID}"
    ```

1. Create the schema registry.

    ```bash
    # Create a storage account in the same resource group as the cluser
    az storage account create --name "${STORAGE_ACCOUNT}" --resource-group "${RESOURCE_GROUP}" --sku Standard_LRS --kind StorageV2 --hierarchical-namespace true
    
    # Create the container
    az storage container create --name "${CONTAINER_NAME}" --account-name "${STORAGE_ACCOUNT}" --auth-mode login
    
    # Create the schema registry
    az iot ops schema registry create  --subscription "${SUBSCRIPTION_ID}"  -g "${RESOURCE_GROUP}"  -n ${SCHEMA_REGISTRY_NAME}  --registry-namespace ${SCHEMA_NAMESPACE}  --sa-resource-id /subscriptions/${SUBSCRIPTION_ID}/resourcegroups/${RESOURCE_GROUP}/providers/Microsoft.Storage/storageAccounts/${STORAGE_ACCOUNT}  --sa-container ${CONTAINER_NAME}
    ```

    ![Screenshot of Azure CLI output for schema registry creation](./images/azure-cli-schema-registry-level2.png)

1. Initialize the cluster for Azure IoT Operations.

    ```bash
    
    # Initialize the cluster for AIO
    az iot ops init  --subscription "${SUBSCRIPTION_ID}"  -g "${RESOURCE_GROUP}"  --cluster "${CLUSTER_NAME}"
    
    ```
    
    ![Screenshot of Azure CLI output for AIO cluster initialization](./images/azure-cli-init-level2.png)
  
1. Deploy Azure IoT Operations to the cluster.

    ```bash
    # Deploy AIO
    az iot ops create  --subscription "${SUBSCRIPTION_ID}"  -g "${RESOURCE_GROUP}"  --cluster "${CLUSTER_NAME}"  --custom-location ${CUSTOM_LOCATION}  -n ${AIO_INSTANCE}  --sr-resource-id /subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.DeviceRegistry/schemaRegistries/${SCHEMA_REGISTRY_NAME}  --broker-frontend-replicas 1  --broker-frontend-workers 1  --broker-backend-part 1  --broker-backend-workers 1  --broker-backend-rf 2  --broker-mem-profile Low  
    ```
    
    ![Screenshot of Azure CLI output for AIO deployment](./images/azure-cli-deploy-level2.png)
  
## Next Steps

Learn how to flow asset telemetry through the deployments into Azure Event Hubs in [Flow asset telemetry](./asset-telemetry.md).