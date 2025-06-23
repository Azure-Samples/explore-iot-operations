# Layered Networking Guidance

Within various industries such as manufacturing it is common to encounter segmented networking architectures that form a "layering" minimizing or blocking the lower level segments ability to communicate with the internet (i.e., [Purdue Network Architecture](https://en.wikipedia.org/wiki/Purdue_Enterprise_Reference_Architecture)). This guidance demonstrates one approach to navigating these networks using open and industry recognized software. 

The intention of this guidance is not to communicate a recommended practice and or the production ready implementation, configuration, and operations of the referenced services and components, please refer to their specific guidance for those specifics. Additionally this guidance does not intent to project any recommendations around networking architecture and segmentations.

 This guidance provides the following.

- Kubernetes-based configuration and compatibility with networking primitives
- Ability to connect devices in isolated networks at scale to [Azure Arc](https://learn.microsoft.com/en-us/azure/azure-arc/) for application lifecycle management and configuration of previously isolated resources remotely from a single Azure control plane
- Security and governance across network levels for devices and services with URL and IP allow lists and connection auditing
- Compatibility with all Azure IoT Operations services connection
- Bifurcation capabilities for targeted endpoints

![image-20250410105421926](.\images\image-20250410105421926.png)

## Isolated Network Environment for Implementing the Guidance

There are several ways to configure this solution to bridge the connection between clusters in the isolated network and services on Azure. The following lists example network environments and cluster scenarios this guidance can apply to.

- **A simplified virtual machine and network** - This scenario uses a single node K3s cluster running on Ubuntu 22.04 LTS in an Azure VM. You need an Azure subscription with the following resources:
  - K3s clusters for level 2, level 3, and level 4
  - An Azure VM running Ubuntu 22.04 LTS in level 1 with curl installed
- **A simplified physical isolated network** - Requires at least four devices (i.e., Small Form Factor Machine) connected to a router or smart switch that has been configured to simulate level 1 to level 4 of a Purdue network.
  - Level 1 to level 4 can communicate with their adjacent networks and only level 4 has internet access
  - K3s clusters for level 2, level 3, and level 4
  - While the choice of DNS is possible and dictated by the deployment environment this guidance focuses on the use of Core DNS

## Key Features

This guidance supports Azure IoT Operations component deployment and MQTT message transmission in isolated network environment. 

## Next Steps

1. Learn [How Azure IOT Operations Works in a Segmented Network](./aio-segmented-networks.md)
2. Learn how to use Core DNS and Envoy Proxy in [Configure the Infrastructure](./configure-infrastructure.md).
3. Learn how to [Arc enable the K3s clusters](./arc-enable-clusters.md).
4. Learn how to [deploy Azure IoT Operations](./deploy-aio.md) to the clusters.
5. Learn how to [flow asset telemetry](./asset-telemetry.md) through the deployments into Azure Event Hubs.

## Related

For lab preparation, see [prerequisites](./prerequisites.md).
