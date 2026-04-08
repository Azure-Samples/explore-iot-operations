# Explore IoT Operations

This repo is the source of tools, samples, quickstarts, tutorials, and other resources for customers of Azure IoT Operations.

## Features

This project provides the following:

* Pre-configured codespace with [K3s](https://k3s.io/) cluster via [K3d](https://k3d.io/)
* [AIO Quickstart](./quickstart/readme.md) — automated deployment on real edge hardware (Ubuntu/K3s) or a single Windows machine (AKS Edge Essentials)
* MQTT Device Simulator
* Edge modules: factory equipment simulator, MQTT historian
* Samples for auth servers, WASM dataflow operators, custom RBAC, observability, and more

> [!IMPORTANT]
> Codespaces are easy to setup quickly and tear down later, but they're not suitable for performance evaluation or scale testing. For those scenarios, use the [AIO Quickstart](./quickstart/readme.md) or a validated environment from the official documentation.
>


## Getting Started

### Option A: GitHub Codespaces (browser-based, no local install)

1. Use this GitHub codespace to explore Azure IoT Operations in your browser without installing anything on your local machine.

   [![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/Azure-Samples/explore-iot-operations?quickstart=1)

1. (Optional) Enter your Azure details to store them as environment variables inside the codespace.

1. **Important**: Open the codespace in VS Code Desktop with **Ctrl/Cmd + Shift + P** > **Codespaces: Open in VS Code Desktop**. This is required to login to Azure CLI properly.

1. Connect your new cluster to Azure Arc.

   ```bash
   az login
   az account set -s $SUBSCRIPTION_ID
   az connectedk8s connect -n $CLUSTER_NAME -g $RESOURCE_GROUP -l $LOCATION
   ```

2. Follow [Azure IoT Operations docs](https://learn.microsoft.com/azure/iot-operations/get-started/quickstart-deploy?tabs=codespaces) to finish deploying.

3. Explore!

### Option B: AIO Quickstart (real hardware or AKS Edge Essentials)

For production-oriented deployments on actual edge devices — or a single Windows laptop — use the **[AIO Quickstart](./quickstart/readme.md)**. It provides:

- One-command edge setup on Ubuntu with K3s
- Automated Azure configuration from a Windows management machine
- Industrial IoT demo apps (factory simulator, MQTT historian)
- Dataflow pipelines to Azure (ADX, Event Hubs, Fabric) using Managed Identity

Two paths are supported:

| Path | Target | Guide |
|------|--------|-------|
| **Ubuntu / K3s** | Dedicated edge device (NUC, PC, VM) | [Quickstart README](./quickstart/readme.md) |
| **AKS Edge Essentials** | Single Windows machine | [Quickstart README — Path B](./quickstart/readme.md#path-b-single-windows-machine-aks-ee) |

See the [Advanced Guide](./quickstart/README_ADVANCED.md) for detailed technical reference, troubleshooting, and operations documentation.

## Repository Structure

```
├── quickstart/         Automated AIO deployment on edge hardware
├── samples/            Code samples and tools
├── tutorials/          Step-by-step walkthroughs
├── tools/              Utility tools (schema generator, etc.)
└── docker/             Container build assets
```

See [Organization docs](./docs/ORGANIZATION.md) for conventions and contribution guidelines.

## Contributing

Please view the developer guides in the docs directory to get started with contributions. Get started with the [Organization docs](./docs/ORGANIZATION.md) and [Code of Conduct](CODE_OF_CONDUCT.md).

## Trademark Notice

Trademarks This project may contain trademarks or logos for projects, products, or services. Authorized use of Microsoft trademarks or logos is subject to and must follow [Microsoft’s Trademark & Brand Guidelines](https://www.microsoft.com/legal/intellectualproperty/trademarks/usage/general). Use of Microsoft trademarks or logos in modified versions of this project must not cause confusion or imply Microsoft sponsorship. Any use of third-party trademarks or logos are subject to those third-party’s policies.
