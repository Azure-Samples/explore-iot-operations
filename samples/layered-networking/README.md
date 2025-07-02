# Layered networking guidance

In industries like manufacturing, you often see segmented networking architectures that create layers. These layers minimize or block lower-level segments from connecting to the internet (for example, [Purdue Network Architecture](https://en.wikipedia.org/wiki/Purdue_Enterprise_Reference_Architecture)). This article shows one way to work with these networks by using open, industry-recognized software.

This article doesn't recommend a specific practice or provide production-ready implementation, configuration, or operations details for the referenced services and components. For those details, see their specific guidance. This article also doesn't make recommendations about networking architecture or segmentation.

This article covers:

- Kubernetes-based configuration and compatibility with networking primitives
- Connecting devices in layered networks at scale to [Azure Arc](https://learn.microsoft.com/en-us/azure/azure-arc/) for application lifecycle management and configuration of previously layered resources remotely from a single Azure control plane
- Security and governance across network levels for devices and services with URL and IP allow lists and connection auditing
- Compatibility with all Azure IoT Operations services connection
- Bifurcation capabilities for targeted endpoints

![Diagram that shows layered networking architecture for industrial layered networks.](./images/layered-network-architecture.png)

## Layered network environment for implementing the guidance

There are several ways to configure this solution to bridge the connection between clusters in the layered network and services on Azure. The following lists example network environments and cluster scenarios this guidance can apply to.

- **A simplified virtual machine and network** - This scenario uses a single-node K3s cluster running on Ubuntu 22.04 LTS in an Azure VM. You need an Azure subscription with these resources:
  - K3s clusters for level 2, level 3, and level 4
  - An Azure VM running Ubuntu 22.04 LTS in level 1 with curl installed
- **A simplified physical layered network** - This scenario requires at least four devices (for example, small form factor machines) connected to a router or smart switch set up to simulate level 1 to level 4 of a Purdue network.
  - Level 1 to level 4 can communicate with their adjacent networks, and only level 4 has internet access
  - K3s clusters for level 2, level 3, and level 4
  - While the choice of DNS depends on the deployment environment, this guidance focuses on using Core DNS

## Key features

This guidance supports deploying Azure IoT Operations components and sending MQTT messages in a layered network environment.

## Next steps

1. Learn [How Azure IoT Operations Works in a layered network](./aio-layered-network.md).
1. Learn how to use CoreDNS and Envoy Proxy in [Configure the infrastructure](./configure-infrastructure.md).
1. Learn how to Arc enable the K3s clusters in [Arc enable the K3s clusters](./arc-enable-clusters.md).
1. Learn how to deploy Azure IoT Operations to the clusters in [Deploy Azure IoT Operations](./deploy-aio.md).
1. Learn how to flow asset telemetry through the deployments into Azure Event Hubs in [Flow asset telemetry](./asset-telemetry.md).
