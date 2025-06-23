# Asset Telemetry

This document describes how to use MQ and Data Flows to move application telemetry through the Purdue network configured previously. This will start with an Asset being deployed in Purdue level2 and move the data from cluster to cluster, eventually landing in the cloud. At each cluster a new piece of information will be added using a transformation to demonstrate how to layers of contextualization can be added throughout the system. Consider an asset that is sending information from The Panels Creation Manufacturing Cell but the Asset itself does not know this context, adding it at the cluster can be a good option.

This is not meant to be a definitive guide, nor is it meant to state a production configuration, instead reference the core [Azure IoT Operations documentation](https://learn.microsoft.com/en-us/azure/iot-operations/discover-manage-assets/overview-manage-assets) for this.

## Prerequisites

To complete this article there are prerequisites that must be in place.

- Event Hubs Namespace was created with the following configurations
  - Local Authentication: Enabled
  - Pricing Tier: Standard in use (others should not be an issue)
  - Event Hubs: the target Event Hubs must be created within the namespace
  - User must have access to the Azure Portal with rights to add users to the Azure Event Hubs Data Sender role
  - Networking: Public Access (All networks was used but should be limited to selected networks)
  - Event Hub status must be enabled

## Add the AIO Deployments to a Single Site

This article has been focused on demonstrating the techniques that can be used to setup a layered network and as such they represent the clusters in a single factory called site-1. For the purposes of this article the administrator had previously created a site called site-1 that was scoped to the entire subscription making all of the clusters deployed (because they were in the same subscription) part of that site as seen here.

- Navigate to the [Azure IoT Operations](https://iotoperations.azure.com/) portal

  ![Azure IoT Operations portal main dashboard showing site navigation](.\images\aio-portal-dashboard.png)

  - If the site has not already been created you may find your clusters under the unassigned instances

    ![Azure IoT Operations portal showing unassigned instances section](.\images\aio-portal-unassigned-instances.png)

- Selecting site-1 will expose the clusters that were just created on level2, level3, and level4

  ![Azure IoT Operations site-1 showing all three cluster levels](.\images\aio-site1-cluster-list.png)

- When the following steps say navigate to the cluster it means to choose the link with the instance name below it to show the following screen for the identified cluster.

  ![Azure IoT Operations cluster detail view showing instance overview](.\images\aio-cluster-detail-view.png)

## Deploying the Sample Asset on level2

The level2 cluster will have the OPC PLC simulator deployed to it to generate the required telemetry data that will be sent up through the parent clusters eventually landing in the cloud.

- To deploy the OPC PLC simulator for use in sending telemetry to the cloud run the following commands from the jump box.

  ```bash
  kubectl config use-context level2
    kubectl apply -f https://raw.githubusercontent.com/Azure-Samples/explore-iot-operations/main/samples/quickstarts/opc-plc-deployment.yaml
  ```

  

  ![Terminal output showing successful deployment of OPC PLC simulator](.\images\kubectl-opc-plc-deployment-output.png)

  > [!NOTE]
  >
  > It is important to note that this configuration uses a self-signed application instance certificate. Don't use this configuration in a production environment. To learn more, see [Configure OPC UA certificates infrastructure for the connector for OPC UA](https://learn.microsoft.com/en-gb/azure/iot-operations/discover-manage-assets/howto-configure-opcua-certificates-infrastructure).

- Navigate to the level2 cluster in the Azure IoT Operations portal and choose Asset endpoints

  ![Azure IoT Operations level2 cluster navigation showing Asset endpoints option](.\images\aio-level2-asset-endpoints-menu.png)

  

  

- To configure the OPC UA connector to subscribe to the data from the OPC UA PLC Simulator we must first create an endpoint. Select "Create new asset endpoint"

  - Asset endpoint name: oven-plc
  - OPC UA server URL: opc.tcp://opcplc-000000:50000
  - User authentication mode: Anonymous

  ![Create asset endpoint form with OPC UA server configuration settings](.\images\create-asset-endpoint-form.png)

  - Click generate to deploy the new endpoint, wait for the notification that it is complete (top right corner of the portal) 

    ![Azure portal success notification showing endpoint deployment completion](.\images\endpoint-deployment-success-notification.png)

  - Clicking refresh will display the endpoint

    ![Asset endpoints list showing the newly created oven-plc endpoint](.\images\asset-endpoints-list-with-oven-plc.png)

    

    

- Select Assets in the left menu and then "Create new asset"

  - Select asset endpoint (the one previously created)

  - Asset name: oven1

  - Default MQTT topic: clusterl2/data/oven1

  - Description: Bran Flakes oven 1

  - Documentation URL: https://www.contoso.com/guides/oven/cts123

  - Hardware version: 232.122223

  - Manufacturer: contoso

  - Manufacturer URL: https://www.contoso.com

  - Model: cts123

  - Serial Number: contAIO1234

  - Software version: v1.3
  - Delete the other Custom properties

    ![Create asset form showing asset configuration including name, topic, and properties](.\images\create-asset-oven1-form.png)

    

  

- Selecting next provides the screen that the tags will be added to. 

- Add the following tags before selecting next by clicking the Add Tag under the drop down:

  ![Asset tag configuration interface with dropdown menu for adding tags](.\images\asset-tag-configuration-interface.png)

  - Tag Name: Temperature, Node Id: ns=3;s=SpikeData, Sampling Interval: 500, Queue size: 1
  - Tag Name: EnergyUse, Node Id: ns=3;s=FastUInt10, Sampling Interval: 500, Queue size: 1
  - Tag Name: Weight, Node Id: ns=3;s=FastUInt9, Sampling Interval: 500, Queue size: 1

  ![Asset tag list showing Temperature, EnergyUse, and Weight tags with their configurations](.\images\asset-tags-temperature-energy-weight.png)

  

  ![Asset creation review screen showing all configured tags and properties](.\images\asset-creation-review-screen.png)

- Select Next then do not add any events for this demo. Select Next

  ![Asset events configuration screen with no events added](.\images\asset-events-configuration-empty.png)

- Click Create then after it is complete selecting refresh should show the new oven1 asset in the list

  ![Assets list showing the newly created oven1 asset with running status](.\images\assets-list-with-oven1.png)

  

- After the deployment completes from the jump box using level2 context perform the following query to see the asset at the edge

  ```bash
  kubectl get asset -n azure-iot-operations -o yaml
  ```

  ![Terminal output showing kubectl asset query results in YAML format](.\images\kubectl-get-asset-yaml-output.png)



## View the level2 MQTT Asset Telemetry

The following section uses an insecure MQTT client connection and configuration to review the messages. It is recommended that this is not used in production and is for demonstration purposes only.

- In the Azure portal navigate to the level2 Azure IoT Operations instance

  ![Azure IoT Operations level2 instance overview page](.\images\aio-level2-instance-overview.png)

  

- In the left menu selection Components -> MQTT broker

  ![Azure IoT Operations MQTT broker component page showing configuration options](.\images\aio-mqtt-broker-components.png)

  

- Create a new MQTT broker listener for LoadBalancer

  - Enter the name as publiclistener
  - Service name is blank

- Enter the following for ports

  - Port: 1883

  - Authentication: none

  - Authorization: none

  - Protocol: MQTT
  - Do not add TLS

    ![MQTT broker listener configuration form showing port 1883 with no authentication](.\images\mqtt-broker-listener-config-form.png)

  

- Create Listener and then view it after it completes deployment by running the following command on the jump box against the level2 context

  ```bash
  kubectl config use-context level2
  
  kubectl get service publiclistener -n azure-iot-operations -o yaml
  ```

  ![Terminal output showing publiclistener service configuration in YAML format](.\images\kubectl-publiclistener-service-yaml.png)

- On the jump box targeting level2 context run the following script to deploy the MQTT client pod

  ```bash
  wget https://raw.githubusercontent.com/Azure-Samples/explore-iot-operations/main/samples/quickstarts/mqtt-client.yaml -O mqtt-client.yaml
  
  kubectl apply -f mqtt-client.yaml
  ```

  

- On the jump box use the mqttui client to inspect the level2 broker

  ```bash
  mqttui --broker mqtt://192.168.102.10:1883
  ```

  

- Navigate in the left pane to clusterl2/data/oven1

  ![MQTTUI client interface showing telemetry data from oven1 asset on level2](.\images\mqttui-level2-oven1-telemetry.png)

  



## Configure level3 to Listen for Incoming MQTT Connections

The following section uses an insecure MQTT client connection and configuration to review the messages. It is recommended that this is not used in production and is for demonstration purposes only. The listener should be limited to specific hosts and authentication/authorization such as mTLS enabled. 

The following section uses an insecure MQTT client connection and configuration to review the messages. It is recommended that this is not used in production and is for demonstration purposes only.

- In the Azure portal navigate to the level3 Azure IoT Operations instance

  ![Azure IoT Operations level3 instance overview page](.\images\aio-level3-instance-overview.png)

  

  

- In the left menu selection Components -> MQTT broker

  ![Azure IoT Operations level3 MQTT broker component configuration page](.\images\aio-level3-mqtt-broker-components.png)

  

  

- Create a new MQTT broker listener for LoadBalancer

  - Enter the name as publiclistener
  - Service name is blank

- Enter the following for ports

  - Port: 1883

  - Authentication: none

  - Authorization: none

  - Protocol: MQTT
  - Do not add TLS

    ![MQTT broker listener configuration for level3 with port 1883 settings](.\images\mqtt-broker-level3-listener-config.png)

    

  

- Create Listener and then view it after it completes deployment by running the following command on the jump box against the level3 context

  ```bash
  kubectl config use-context level3
  
  kubectl get service publiclistener -n azure-iot-operations -o yaml
  ```

  ![Terminal output showing level3 publiclistener service configuration](.\images\kubectl-level3-publiclistener-yaml.png)

  



## Configure level4 to Listen for Incoming MQTT Connections

The following section uses an insecure MQTT client connection and configuration to review the messages. It is recommended that this is not used in production and is for demonstration purposes only. The listener should be limited to specific hosts and authentication/authorization such as mTLS enabled. 

The following section uses an insecure MQTT client connection and configuration to review the messages. It is recommended that this is not used in production and is for demonstration purposes only.

- In the Azure portal navigate to the level4 Azure IoT Operations instance

  ![Azure IoT Operations level4 instance overview page](.\images\aio-level4-instance-overview.png)

  

  

- In the left menu selection Components -> MQTT broker

  ![Azure IoT Operations level4 MQTT broker component configuration page](.\images\aio-level4-mqtt-broker-components.png)

  

  

- Create a new MQTT broker listener for LoadBalancer

  - Enter the name as publiclistener
  - Service name is blank

- Enter the following for ports

  - Port: 1883

  - Authentication: none

  - Authorization: none

  - Protocol: MQTT
  - Do not add TLS

    ![MQTT broker listener configuration for level4 with port 1883 settings](.\images\mqtt-broker-level4-listener-config.png)

    

    

- Create Listener and then view it after it completes deployment by running the following command on the jump box against the level4 context

  ```bash
  kubectl config use-context level4
  
  kubectl get service publiclistener -n azure-iot-operations -o yaml
  ```

  ![Terminal output showing level4 publiclistener service configuration](.\images\kubectl-level4-publiclistener-yaml.png)

  

  

## Configure level2 to Transform the Message and Send to level3

In this section the oven1 messages will have an additional piece of data added that indicates the current product being produced and then forwards it to level3. As this is not a Data Flow tutorial it will used a simplified "hard coded" technique to adding the product details. In production this would typically be a secondary stream etc.

- In the Azure IoT Operations portal navigate to the level2 cluster then select "Data flow endpoints"

  ![Azure IoT Operations level2 data flow endpoints configuration page](.\images\aio-level2-dataflow-endpoints.png)

  

- Select Custom MQTT Broker to expose the blade and enter the details of the level3 broker (upstream)

  - Name: level3

  - Host: 192.168.103.10:1883

  - Authentication method: None

    ![Custom MQTT broker configuration form for level3 connection](.\images\custom-mqtt-broker-level3-config.png)

- Click Apply and wait for the creation to complete

- Select "Data flows" from the left pane

  ![Azure IoT Operations data flows navigation menu on level2](.\images\aio-level2-dataflows-menu.png)

  

- Create a new data flow to display the data flow canvas

  ![Data flow canvas creation interface showing blank workspace](.\images\dataflow-canvas-blank.png)

  

- Click on Select Source and choose Asset / Oven and click apply

  ![Data flow source selection showing Asset/Oven option](.\images\dataflow-source-asset-oven-selection.png)

- Click on Select data flow endpoint, then select level3 and Proceed to make the data flow target the public listening endpoint of the level3 cluster

  ![Data flow endpoint selection showing level3 target configuration](.\images\dataflow-endpoint-level3-selection.png)

- The MQTT topic to use is /l2in/data/oven1 indicating where the data will land in the level3 broker, click Apply

  ![MQTT topic configuration showing /l2in/data/oven1 destination](.\images\mqtt-topic-l2in-data-oven1.png)

- Click on Add transform (optional) to expose the Transform choices where New property should be selected

  ![Data flow transform options showing New property selection](.\images\dataflow-transform-new-property-option.png)

- Enter the details

  - Property key: product

  - Property value: flakes
  - Description: Added flakes as product

    ![Transform configuration form showing product property set to flakes](.\images\transform-config-product-flakes.png)

- After clicking apply the flow should look as follows

  ![Complete data flow showing source, transform, and destination components](.\images\dataflow-level2-to-level3-complete.png)

- Select the Edit option beside Data flow enabled and add a new pipeline name called level2-to-level3. Ensure Enable data flow is checked and click Apply

  ![Data flow pipeline configuration showing level2-to-level3 name and enabled state](.\images\dataflow-pipeline-level2-to-level3-config.png)

- Select the "save" button and wait for it to complete the deployment

  ![Data flow save confirmation showing successful deployment status](.\images\dataflow-save-deployment-success.png)

  

- On the jump box use the mqttui client to inspect the level3 broker

  ```bash
  mqttui --broker mqtt://192.168.103.10:1883
  ```

  

- Navigate in the left pane to /l2in/data/oven1

  ![MQTTUI client showing level3 broker with transformed data including product field](.\images\mqttui-level3-oven1-with-product.png)

  

  - In the right pane at the top it can be seen that the product is flakes



## Configure level3 to Transform the Message and Send to level4

In this section the oven1 transformed messages will have an additional piece of data added that indicates the current configuration of  line is cereal production then forwards it to level4. As this is not a Data Flow tutorial it will used a simplified "hard coded" technique to adding the product details. In production this would typically be a secondary stream etc.

- In the Azure IoT Operations portal navigate to the level3 cluster then select "Data flow endpoints"

  ![Azure IoT Operations level3 data flow endpoints configuration page](.\images\aio-level3-dataflow-endpoints.png)

  

  

- Select Custom MQTT Broker to expose the blade and enter the details of the level4 broker (upstream)

  - Name: level4

  - Host: 192.168.104.10:1883

  - Authentication method: None

    ![Custom MQTT broker configuration form for level4 connection](.\images\custom-mqtt-broker-level4-config.png)

    

- Click Apply and wait for the creation to complete

- Navigate to the [Schema Gen helper](https://azure-samples.github.io/explore-iot-operations/schema-gen-helper/) to define the source schema (this level does not know about the other levels assets)

  ![Schema Generation Helper tool interface for creating JSON schemas](.\images\schema-gen-helper-interface.png)

- On the jump box use mosquitto_sub to retrieve some samples of the message or use the example file contents that follow

  ```bash
  mosquitto_sub --host 192.168.103.10 --port 1883 -t "/l2in/data/oven1"
  ```

  ```json
  {
    "EnergyUse": {
      "SourceTimestamp": "2025-04-05T15:55:05.991129Z",
      "Value": 212
    },
    "Temperature": {
      "SourceTimestamp": "2025-04-05T15:55:06.6915356Z",
      "Value": 98.22872507286884
    },
    "Weight": {
      "SourceTimestamp": "2025-04-05T15:55:05.9910467Z",
      "Value": 229
    },
    "product": "flakes"
  }
  ```

  

- Select JSON Schema (Draft-07) schema and set all fields to be nullable

- Click "Generate" to review the schema

- Click "Download" and name it level2inschema.json

- Select "Data flows" from the left pane

  ![Azure IoT Operations level3 data flows navigation menu](.\images\aio-level3-dataflows-menu.png)

  

  

- Create a new data flow to display the data flow canvas

  ![Data flow canvas creation interface for level3 to level4](.\images\dataflow-canvas-level3-blank.png)

  

  

- Click on Select Source and note that no Assets are present here as they do not know about the "downstream asset", so "Message broker" must be used.

  - Data flow endpoint: default

  - Topic: /l2in/data/oven1

  - Message Schema: Click upload and browse to the level2inschema.json file (slight delay while it uploads)

    ![Data flow source configuration using message broker with schema upload](.\images\dataflow-source-message-broker-schema.png)

- Click on Select data flow endpoint, then select level4 and Proceed to make the data flow target the public listening endpoint of the level4 cluster

  ![Data flow endpoint selection for level4 target configuration](.\images\dataflow-endpoint-level4-selection.png)

  

- The MQTT topic to use is /l3in/data/oven1 indicating where the data will land in the level3 broker, click Apply

  ![MQTT topic configuration showing /l3in/data/oven1 destination](.\images\mqtt-topic-l3in-data-oven1.png)

  

- Click on Add transform (optional) to expose the Transform choices where New property should be selected

  ![Data flow transform options for adding line-config property](.\images\dataflow-transform-new-property-option.png)

- Enter the details

  - Property key: line-config

  - Property value: cereal
  - Description: Line configured for cereal production

    ![Transform configuration form showing line-config property set to cereal](.\images\transform-config-line-config-cereal.png)

    

- After clicking apply the flow should look as follows

  ![Complete data flow from level3 to level4 with line-config transform](.\images\dataflow-level3-to-level4-complete.png)

  

- Select the Edit option beside Data flow enabled and add a new pipeline name called level3-to-level4. Ensure Enable data flow is checked and click Apply

  ![Data flow pipeline configuration for level3-to-level4 with enabled state](.\images\dataflow-pipeline-level3-to-level4-config.png)

  

- Select the "save" button and wait for it to complete the deployment

  ![Data flow save confirmation for level3 to level4 deployment](.\images\dataflow-level3-save-deployment-success.png)

  

- On the jump box use the mqttui client to inspect the level4 broker. It may be found that it takes some time until this appears. It started moving data several minutes later after the schema was received at the edge (several minutes after the apply had taken place). The following MQTT topic on level3 showed the receipt of the schema. Once received the command that follows should show messages coming into level4.

  ```bash
  mqttui --broker mqtt://192.168.104.10:1883
  ```




- Navigate in the left pane to /l3in/data/oven1

  ![MQTTUI client showing level4 broker with data including product and line-config fields](.\images\mqttui-level4-oven1-with-line-config.png)

  

  - In the right pane at the top it can be seen that the product is flakes and the line-configuration is cereal



## Configure level4 to Transform the Message and Send to Event Hub

In this section the oven1 transformed messages will have an additional piece of data added that indicates the factory number then forwards it to an Event Hubs. As this is not a Data Flow tutorial it will used a simplified "hard coded" technique to adding the product details. In production this would typically be a secondary stream etc.

- This will not guide through the creation of the Event Hubs and assumes it is already available. 

- Assign permissions to the Event Hub for the managed identity of the level4 cluster
  - In the Azure Portal navigate to the Azure IoT Instance for level4 and select Overview and copy the name of the extension

    ![Azure IoT Operations level4 instance overview showing extension name for managed identity](.\images\aio-level4-extension-name-overview.png)

    

    

  - Copy the name of the extension as it has the same name as the system assigned managed identity

- Navigate to the Event Hubs namespace -> Access control (IAM) -> Add role assignment

  ![Event Hubs namespace Access Control (IAM) page for adding role assignments](.\images\event-hubs-iam-add-role-assignment.png)

- Add a role assignment

  - Role: Azure Event Hubs Data Sender

  - Assign access to: User, group, or service principal
  - Select Members: The managed identity of the Azure IoT Operations found above (Arc extension name)

  

- In the Azure IoT Operations portal navigate to the level4 cluster then select "Data flow endpoints"

  ![Azure IoT Operations level4 data flow endpoints configuration page](.\images\aio-level4-dataflow-endpoints.png)

  

  

- Select Azure Event Hubs and enter the following

  - Name: event-hubs-target

  - Host: Search for the Event Hubs Namespace by name and select it

  - Authentication method: System assigned managed identity

    ![Azure Event Hubs data flow endpoint configuration with managed identity](.\images\event-hubs-dataflow-endpoint-config.png)

    

- Click Apply and wait for the creation to complete

- Navigate to the [Schema Gen helper](https://azure-samples.github.io/explore-iot-operations/schema-gen-helper/) to define the source schema (this level does not know about the other levels assets)

  ![Schema Generation Helper tool for creating level3 input schema](.\images\schema-gen-helper-level3-schema.png)

- On the jump box use mosquitto_sub to retrieve some samples of the message or use the example file contents that follow

  ```bash
  mosquitto_sub --host 192.168.104.10 --port 1883 -t "/l3in/data/oven1"
  ```

  ```json
  {
    "EnergyUse": {
      "SourceTimestamp": "2025-04-05T16:42:50.9882087Z",
      "Value": 232
    },
    "Temperature": {
      "SourceTimestamp": "2025-04-05T16:42:51.7943136Z",
      "Value": 99.80267284282716
    },
    "Weight": {
      "SourceTimestamp": "2025-04-05T16:42:50.9881744Z",
      "Value": 272
    },
    "line-config": "cereal",
    "product": "flakes"
  }
  ```

  

- Select JSON Schema (Draft-07) schema and set all fields to be nullable

- Click "Generate" to review the schema

- Click "Download" and name it level3inschema.json

- Select "Data flows" from the left pane

  ![Azure IoT Operations level4 data flows navigation menu](.\images\aio-level4-dataflows-menu.png)

  

  

  

- Create a new data flow to display the data flow canvas

  ![Data flow canvas creation interface for level4 to Event Hub](.\images\dataflow-canvas-level4-blank.png)

  

  

  

- Click on Select Source and note that no Assets are present here as they do not know about the "downstream asset", so "Message broker" must be used.

  - Data flow endpoint: default

  - Topic: /l3in/data/oven1

  - Message Schema: Click upload and browse to the level3inschema.json file (slight delay while it uploads)

    ![Data flow source configuration for level4 using message broker with level3 schema](.\images\dataflow-source-level4-message-broker-schema.png)

    

- Click on Select data flow endpoint, then select event-hubs-target target created in the previous step

  ![Data flow endpoint selection showing Event Hubs target configuration](.\images\dataflow-endpoint-event-hubs-selection.png)

  

  

- The Topic to enter when prompted is the name of the Event Hubs (not namespace), then click Apply

  ![Event Hub topic name configuration for data flow destination](.\images\event-hub-topic-name-config.png)

  

- Click on Add transform (optional) to expose the Transform choices where New property should be selected

  ![Data flow transform options for adding factory-code property](.\images\dataflow-transform-new-property-option.png)

- Enter the details

  - Property key: factory-code

  - Property value: 1032
  - Description: The id of the factory

    ![Transform configuration form showing factory-code property set to 1032](.\images\transform-config-factory-code-1032.png)

    

    

- After clicking apply the flow should look as follows

  ![Complete data flow from level4 to Event Hub with factory-code transform](.\images\dataflow-level4-to-event-hub-complete.png)

  

  

  

- Select the Edit option beside Data flow enabled and add a new pipeline name called level4-to-cloud. Ensure Enable data flow is checked and click Apply

  ![Data flow pipeline configuration for level4-to-cloud with enabled state](.\images\dataflow-pipeline-level4-to-cloud-config.png)

  

  

- Select the "save" button and wait for it to complete the deployment

  ![Data flow save confirmation for level4 to cloud deployment](.\images\dataflow-level4-save-deployment-success.png)

- Review the stats in the Event Hub (destinationeh) to see the messages are arriving (Incoming Messages (Sum), cgc-eh-cluster)

  ![Event Hub metrics dashboard showing incoming messages statistics](.\images\event-hub-metrics-incoming-messages.png)

  

- See the details of the messages that are arriving by selecting "Data Explorer" and then "View Events"

  ![Event Hub Data Explorer interface for viewing message details](.\images\event-hub-data-explorer-view-events.png)

- Selecting one of the messages in the list displays the information received in the Event Hub

  ![Event Hub message detail view showing telemetry data with all transform properties](.\images\event-hub-message-detail-telemetry.png)

## Previous Steps

1. [Overview](./README.md)
1. Learn [How Azure IOT Operations Works in a Segmented Network](./aio-segmented-networks.md)
3. Learn how to use Core DNS and Envoy Proxy in [Configure the Infrastructure](./configure-infrastructure.md).
4. Learn how to [Arc enable the K3s clusters](./arc-enable-clusters.md).
5. Learn how to [deploy Azure IoT Operations](./deploy-aio.md) to the clusters.

## Next Steps

1. 

## Related

For lab preparation, see [prework](./prework.md).