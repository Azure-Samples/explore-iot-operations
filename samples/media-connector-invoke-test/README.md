# Azure IoT Operations (AIO) Media Connector Demo

## Introduction

This document describes the AIO Media Connector demo package.

The AIO Media Connector is part of the AIO platform.
It is designed to be secure, scalable and fault-tolerant.
It is responsible for the ingestion, storage, and distribution of media content; it also takes care of the management of media metadata and the generation of media thumbnails.

## Demo environment diagram

The demo environment consists of the following components:

![Demo environment diagram](media-connector-demo.png)

The dotted lines represent connections and components that are possible but not show in the demo package.

## Getting started

0) The scripts are designed to run on PowerShell 7 or newer.
   You can test if you have the necessary prerequisites by running `Test-Prerequisites.ps1`.
   The *Installation of prerequisites* section below has useful relevant information.
   The demo should be in a path without spaces.
1) [Deploy AIO](https://aka.ms/getAIO).
   The AIO Kubernetes cluster should be configured as the `kubectl` current context.
2) Upgrade the public preview components by running the script `Update-AioMediaConnector.ps1` under `update-aio/` directory.
3) Install the media server using the files in the `media-server/` directory.
4) You should have a listener without TLS configured on port 1883.
   You can verify by calling the `Update-AioMqEndpointFile.ps1` script.
   You can use the files under `broker-listener/` to deploy this.
5) Then you can run each of the test scripts `Invoke-Test*.ps1` to run different test scenarios:
   `Invoke-TestSnapshotToMqttAutostart.ps1` takes snapshots from the demo stream and publishes them to the MQTT broker.
   `Invoke-TestSnapshotToFsAutostart.ps1` takes snapshots from the demo stream and writes them as files to the file system.
   `Invoke-TestClipToFsAutostart.ps1` creates clips at regular intervals from the demo stream and writes them as files to the file system.
   `Invoke-TestStreamToRtspAutostart.ps1` pushes the demo stream to a media server, from where it can be retrieved.
   The scripts deploy the endpoint and asset and monitors their activity. Use `Ctrl+C` to end the monitoring, remove the endpoint and asset and terminate the script.

## Installation of prerequisites

To install the prerequisites you can follow the instructions below.
These might not be the preferred installation procedure for your system and IT environment.
Check with your administrator before installing tools.

### Windows

Run these commands from the command line:

`winget install -e --id Microsoft.PowerShell`
`winget install -e --id Kubernetes.kubectl`
`winget install -e --id Microsoft.AzureCLI`
`winget install -e --id Helm.Helm`
`winget install -e --id EclipseFoundation.Mosquitto`

You might need to add C:\Program Files\mosquitto and helm.exe to your PATH.

### Ubuntu GNU/Linux

Run this command from the terminal:

Follow the official documentation to install:
-[PowerShell](https://learn.microsoft.com/en-us/powershell/scripting/install/install-ubuntu)
-[Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli-linux)
-[Helm](https://helm.sh/docs/intro/install/)
-kubectl(depends on your system)

You can install the mosquitto clients by running:
`sudo apt install mosquitto-clients`

## Changes since AIO M2/M3

- Additional test scripts have been added to demonstrate the capabilities of the AIO Media Connector.
- Using PowerShell scripts instead of Polyglot notebooks.

## Limitations

The AIO Media Connector has the following limitations:
- No discovery, will be implemented by the ONVIF connector, currently under development
- Limits on the number of concurrent connections and the file system use are not enforced
- Performance and footprint are not optimized
- The mRPC API is not publicly documented yet and is subject to change

## Description of package contents:

- **README.md**: This file.
- **Overview.md**: General information about AIO and the AIO Media Connector.
- **media-connector-demo.mermaid and produced .png and .svg**: Diagram of the demo environment.
- **Broker listener (broker-listener/)**: This directory contains PowerShell scripts and kuberentes resources that show how to deploy an open (non-TLS) listener for MQ.
- **Media Server (media-server/)**: This directory contains scripts and yaml files that demonstrates how to deploy a media server in a kubernetes cluster.
- **resources/aep-*.yaml**: Example Asset Endpoint Profiles (AEPs) that can be used to configure the media connector.
- **resources/asset-*.yaml**: Example assets that can be used to configure the media connector.
- **Install-ResourceFile.ps1**: This PowerShell script installs a kubernetes resource file for the AIO Media Connector.
- **Uninstall-ResourceFile.ps1**: This PowerShell script uninstalls a kubernetes resource file for the AIO Media Connector.
- **Invoke-Test*.ps1**: These PowerShell scripts run different test scenarios for the AIO Media Connector.
- **Start-InteractiveSession.ps1**: This PowerShell script starts an interactive session in the AIO Media Connector container.
- **Start-MqttListener.ps1**: This PowerShell script starts an MQTT listener on the AIO MQTT broker.
- **Start-FileSystemMonitor.ps1**: This PowerShell script start monitoring for file changes on the AIO Media Connector container.
- **Start-RtspStreamViewer.ps1**: This PowerShell script start the default browser to look at streaming RTPS from the default media server.
