# Azure IoT Operations Dev Toolbox

This repo is the source of tools, samples, and other resources for customers of Azure IoT Operations.

## Features

This project provides the following tools:

* Pre-configured codespace with [K3s](https://k3s.io/) cluster via [K3d](https://k3d.io/)
* Krill MQTT Data Simulator
* HTTP Callout Server
* GRPC Callout Server

> [!IMPORTANT]
> Codespaces are easy to setup quickly and tear down later, but they're not suitable for performance evaluation or scale testing. For those scenarios, use a validated environment from the official documentation.
>
> Azure IoT Operations is currently in preview and not recommended for production use no matter the environment.

## Getting Started

1. Use this GitHub codespace to explore Azure IoT Operations in your browser without installing anything on your local machine.

   [![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/Azure-Samples/aio-dev-toolbox?quickstart=1)

1. (Optional) Enter your Azure details to store them as environment variables inside the codespace. 

1. Wait for the post creation commands to finish, then connect your new cluster to Azure Arc.

   ```bash
   az connectedk8s connect --name $CLUSTER_NAME --resource-group $RESOURCE_GROUP  --subscription $SUBSCRIPTION_ID --location $REGION
   ```

1. Follow Azure IoT Operations docs to finish deploying.

1. (Add Krill and other instructions)

## Resources

(Any additional resources or related projects)

- Link to supporting information
- Link to similar sample
- ...

## Contributing

Please view the developer guides in the docs directory to get started with contributions. Get started with the [Organization docs](./docs/ORGANIZATION.md).