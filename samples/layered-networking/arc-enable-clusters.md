# Arc Enabling the Clusters

[Arc-enabled Kubernetes](https://learn.microsoft.com/en-us/azure/azure-arc/kubernetes/overview) allows you to attach Kubernetes clusters running anywhere and manage them in Azure. Managing these clusters with a single control plane provides a more consistent development and operations experience. Azure IoT Operations makes use of the valuable features provided by this service and is deployed as an Arc Extension. 

To deploy Azure IoT Operations the k3s clusters that were previously created (level2, level3, and leve4) must be Arc enabled, which requires internet access, solved through the previous steps outlining the infrastructure (Core DNS and Envoy Proxy) to allow the segmented networks to establish these connections and continue to communicate over them as they operate.

## Prerequisites

- The jump box has been configured as outlined previously with Azure CLI and Kubectl on it, configured to communicate with each cluster by switching context

- Contributor access to an Azure subscription where the clusters will be connected

- The OID for the Arc service. This requires permissions that may not be granted to all users in an enterprise, requiring another party to provide it. The easiest way to retrieve this is in the cloud shell as follows.

  - Open the cloud shell in the Azure Portal to a bash terminal (top right corner of the portal ![image-20250411082749489](.\images\image-20250411082749489.png))

  - Ensure the desired subscription is selected then query azure for the OID.

    ```bash
    # Set the subscription to the one that will be used for Arc enabled kubernetes cluster
    az account set -s "<Subscription_Id>"
    
    # Query for the OID and record the GUID
    az ad sp show --id bc313c14-388c-4e7d-a58e-70017303ee3b --query id -o tsv
    ```

    

## Set Required Kernel Parameters On Each Machine

> [!IMPORTANT]
>
> For each of the machines that host kubernetes update the the kernel parameters to at least the provided values. If overrides in place already make sure to set these without duplicates in the file. Without these settings there will be timeouts.

```bash
ssh ubuntu@192.168.10<level>.10

sudo tee -a /etc/sysctl.conf <<EOF

fs.inotify.max_user_instances=8192
fs.inotify.max_user_watches=524288
fs.file-max = 100000

EOF

sudo sysctl -p &> /dev/null

sudo systemctl restart k3s

exit
```



## Arc enable level4

- Set the environment variables for the level4 connectivity

  ```bash
  SUBSCRIPTION_ID="<Subscription_Id>"
  
  # A list can be retrieved using 
  # az account list-locations --query "sort_by([].{Location:name}, &Location)" -o table
  LOCATION="<Azure_Location>"
  RESOURCE_GROUP="<Resource_Group>"
  CLUSTER_NAME="<Cluster_Name>"
  
  # The OID retrieved in the prerequisites
  OID="<OID>"
  ```

  

- Set Azure to the right subscription and kubernetes to target the level4 cluster

  ```bash
  # When prompted copy the code provided and log in to Azure using the link provided
  az login --use-device-code
  
  az account set -s "${SUBSCRIPTION_ID}"
  
  kubectl config use-context level4
  ```

  

- Add the Azure CLI extensions and register the providers that are required for these steps and the eventual Azure IoT Operations installation

  ```bash
  az extension add --name connectedk8s && az extension add --name k8s-extension && az extension add --name customlocation && az extension add --name azure-iot-ops
  
  az provider register -n "Microsoft.ExtendedLocation" && az provider register -n "Microsoft.Kubernetes" && az provider register -n "Microsoft.KubernetesConfiguration" && az provider register -n "Microsoft.IoTOperations" && az provider register -n "Microsoft.DeviceRegistry" && az provider register -n "Microsoft.SecretSyncController"
  ```

  

- Create the resource group where the cluster will be connected then establish the connection

  ```bash
  az group create --location ${LOCATION} --resource-group ${RESOURCE_GROUP} --subscription ${SUBSCRIPTION_ID}
  
  # The timeout has been increased for lower levels but the same will be used in each for this demo (it takes several minutes)
  az connectedk8s connect -n ${CLUSTER_NAME} -g ${RESOURCE_GROUP} --custom-locations-oid ${OID} --onboarding-timeout 480 --enable-oidc-issuer --enable-workload-identity --disable-auto-upgrade
  
  az connectedk8s enable-features -n ${CLUSTER_NAME} -g ${RESOURCE_GROUP} --custom-locations-oid ${OID} --features cluster-connect custom-locations
  ```

  - During the connect the following message may be seen and ignored as the correct OID was provided manually

    ![image-20250411085421916](.\images\image-20250411085421916.png)

  - After the connect the new cluster can be seen in the portal

    > [!NOTE]
    >
    > While shown here using the portal so the extension can be seen it can also have a quick validation by running the following command: az connectedk8s list --resource-group $RESOURCE_GROUP --query '[].{name: name, distribution: distribution, infrastructure: infrastructure, status: connectivityStatus}' . It is up to the tech writer to decide

    ![image-20250411085322184](.\images\image-20250411085322184.png)

  - Clicking on the cluster displays some items to confirm (in red squares)

    - The distribution was selected correctly as k3s, the wiextension was installed, and finally the cluster is connected

    ![image-20250411090032796](.\images\image-20250411090032796.png)

    

- Reviewing the kubernetes namespaces on level4 will show that arc-workload-identity, azure-arc, and azure-arc-release are now present (Arc agentry)

  ```bash
  kubectl get namespaces
  ```

  ![image-20250411090303387](.\images\image-20250411090303387.png)



## Arc enable level3

- Set the environment variables for the level3 connectivity

  ```bash
  SUBSCRIPTION_ID="<Subscription_Id>"
  
  # A list can be retrieved using 
  # az account list-locations --query "sort_by([].{Location:name}, &Location)" -o table
  LOCATION="<Azure_Location>"
  RESOURCE_GROUP="<Resource_Group>"
  CLUSTER_NAME="<Cluster_Name>"
  
  # The OID retrieved in the prerequisites
  OID="<OID>"
  ```

  

- Set Azure to the right subscription and kubernetes to target the level3 cluster

  ```bash
  # When prompted copy the code provided and log in to Azure using the link provided
  az login --use-device-code
  
  az account set -s "${SUBSCRIPTION_ID}"
  
  kubectl config use-context level3
  ```

  

- Add the Azure CLI extensions and register the providers that are required for these steps and the eventual Azure IoT Operations installation (if using the same session and subscription does not have to be performed again)

  ```bash
  az extension add --name connectedk8s && az extension add --name k8s-extension && az extension add --name customlocation && az extension add --name azure-iot-ops
  
  az provider register -n "Microsoft.ExtendedLocation" && az provider register -n "Microsoft.Kubernetes" && az provider register -n "Microsoft.KubernetesConfiguration" && az provider register -n "Microsoft.IoTOperations" && az provider register -n "Microsoft.DeviceRegistry" && az provider register -n "Microsoft.SecretSyncController"
  ```

  

- Create the resource group where the cluster will be connected then establish the connection

  ```bash
  az group create --location ${LOCATION} --resource-group ${RESOURCE_GROUP} --subscription ${SUBSCRIPTION_ID}
  
  # The timeout has been increased for lower levels but the same will be used in each for this demo (it takes several minutes)
  az connectedk8s connect -n ${CLUSTER_NAME} -g ${RESOURCE_GROUP} --custom-locations-oid ${OID} --onboarding-timeout 960 --enable-oidc-issuer --enable-workload-identity --disable-auto-upgrade
  
  az connectedk8s enable-features -n ${CLUSTER_NAME} -g ${RESOURCE_GROUP} --custom-locations-oid ${OID} --features cluster-connect custom-locations
  ```

  - **In some of the lower level deployments it is possible to get an error due to timeout pulling images etc. If an error comes up check the directory provided** **(in one scenario I required a reboot)**

  - ![image-20250411091112425](.\images\image-20250411091112425.png)

    - **Check to contents of the cluster_diagnostic_checks_pod_description.txt. If this is the timeout retry the previous command and it should succeed. (at one point reviewed the deployment status to find 2 pods failing to pull image with 1/2 ready deleted and it recreated and immediately connected)**

      ```bash
      cat /home/chris/.azure/pre_onboarding_check_logs/cgc-cluster-level3-Fri-Apr-11-09.07.36-2025/cluster_diagnostic_checks_pod_description.txt
      ```

      ![image-20250411091250142](.\images\image-20250411091250142.png)

  - During the connect the following message may be seen and ignored as the correct OID was provided manually

    ![image-20250411085421916](.\images\image-20250411085421916.png)

  - After the connect the new cluster can be seen in the portal

    > [!NOTE]
    >
    > While shown here using the portal so the extension can be seen it can also have a quick validation by running the following command: az connectedk8s list --resource-group $RESOURCE_GROUP --query '[].{name: name, distribution: distribution, infrastructure: infrastructure, status: connectivityStatus}' . It is up to the tech writer to decide

    ![image-20250411101915341](.\images\image-20250411101915341.png)

    

  - Clicking on the cluster displays some items to confirm (in red squares)

    - The distribution was selected correctly as k3s, the wiextension was installed, and finally the cluster is connected

      ![image-20250411102110533](.\images\image-20250411102110533.png)

    

    

- Reviewing the kubernetes namespaces on level3 will show that arc-workload-identity, azure-arc, and azure-arc-release are now present (Arc agentry)

  ```bash
  kubectl get namespaces
  ```

  ![image-20250411090303387](.\images\image-20250411090303387.png)





## Arc enable level2

- Set the environment variables for the level2 connectivity

  ```bash
  SUBSCRIPTION_ID="<Subscription_Id>"
  
  # A list can be retrieved using 
  # az account list-locations --query "sort_by([].{Location:name}, &Location)" -o table
  LOCATION="<Azure_Location>"
  RESOURCE_GROUP="<Resource_Group>"
  CLUSTER_NAME="<Cluster_Name>"
  
  # The OID retrieved in the prerequisites
  OID="<OID>"
  ```

  

- Set Azure to the right subscription and kubernetes to target the level2 cluster

  ```bash
  # When prompted copy the code provided and log in to Azure using the link provided
  az login --use-device-code
  
  az account set -s "${SUBSCRIPTION_ID}"
  
  kubectl config use-context level2
  ```

  

- Add the Azure CLI extensions and register the providers that are required for these steps and the eventual Azure IoT Operations installation (if using the same session and subscription does not have to be performed again)

  ```bash
  az extension add --name connectedk8s && az extension add --name k8s-extension && az extension add --name customlocation && az extension add --name azure-iot-ops
  
  az provider register -n "Microsoft.ExtendedLocation" && az provider register -n "Microsoft.Kubernetes" && az provider register -n "Microsoft.KubernetesConfiguration" && az provider register -n "Microsoft.IoTOperations" && az provider register -n "Microsoft.DeviceRegistry" && az provider register -n "Microsoft.SecretSyncController"
  ```

  

- Create the resource group where the cluster will be connected then establish the connection

  ```bash
  az group create --location ${LOCATION} --resource-group ${RESOURCE_GROUP} --subscription ${SUBSCRIPTION_ID}
  
  # The timeout has been increased for lower levels but the same will be used in each for this demo (it takes several minutes)
  az connectedk8s connect -n ${CLUSTER_NAME} -g ${RESOURCE_GROUP} --custom-locations-oid ${OID} --onboarding-timeout 960 --enable-oidc-issuer --enable-workload-identity --disable-auto-upgrade
  
  az connectedk8s enable-features -n ${CLUSTER_NAME} -g ${RESOURCE_GROUP} --custom-locations-oid ${OID} --features cluster-connect custom-locations
  ```

  - **During the connect the following message may be seen and ignored as the correct OID was provided manually

    ![image-20250411085421916](.\images\image-20250411085421916.png)

  - After the connect the new cluster can be seen in the portal

    > [!NOTE]
    >
    > While shown here using the portal so the extension can be seen it can also have a quick validation by running the following command: az connectedk8s list --resource-group $RESOURCE_GROUP --query '[].{name: name, distribution: distribution, infrastructure: infrastructure, status: connectivityStatus}' . It is up to the tech writer to decide

    ![image-20250411105833359](.\images\image-20250411105833359.png)

    

    

  - Clicking on the cluster displays some items to confirm (in red squares)

    - The distribution was selected correctly as k3s, the wiextension was installed, and finally the cluster is connected

      ![image-20250411110044342](.\images\image-20250411110044342.png)

      

    

    

- Reviewing the kubernetes namespaces on level2 will show that arc-workload-identity, azure-arc, and azure-arc-release are now present (Arc agentry)

  ```bash
  kubectl get namespaces
  ```

  ![image-20250411090303387](.\images\image-20250411090303387.png)

## Previous Steps

1. [Overview](./README.md)
1. Learn [How Azure IOT Operations Works in a Segmented Network](./How Does AIO Work in Segmented Networks.md)
3. Learn how to use Core DNS and Envoy Proxy in [Configure the Infrastructure](./Configure the Infrastructure.md).

## Next Steps

1. Learn how to [deploy Azure IoT Operations](./Deploying AIO.md) to the clusters.
5. Learn how to [flow asset telemetry](./Asset Telemetry.md) through the deployments into Azure Event Hubs.

## Related

- For MS Internal lab preparation the [Prework](./Prework.md) may be of help
