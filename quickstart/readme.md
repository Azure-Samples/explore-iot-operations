# Azure IoT Operations - Quick Start

Automated deployment of Azure IoT Operations (AIO) on edge devices with industrial IoT applications.

## Table of Contents

- [What You Get](#what-you-get)
- [Why not use codespaces from the docs?](#why-not-use-codespaces-from-the-docs)
- [Quick Start](#quick-start)
- [Prerequisites](#prerequisites)
  - [Hardware (Ubuntu / K3s path)](#hardware-ubuntu--k3s-path)
  - [Windows Management Machine](#windows-management-machine-required-for-all-paths)
- [Installation](#installation)
  - [Path A: Ubuntu / K3s](#path-a-ubuntu--k3s)
    - [1. Get the Repository](#1-get-the-repository)
    - [2a. Create and Complete Config File](#2a-create-and-complete-config-file--do-this-first)
    - [3. Edge Setup (Ubuntu)](#3-edge-setup-on-ubuntu-device)
    - [3b. Arc-Enable Cluster](#3b-arc-enable-cluster-on-ubuntu-device)
    - [4. Azure Configuration (Windows)](#4-azure-configuration-from-windows-machine)
    - [5. Verify Installation](#5-verify-installation)
  - [Path B: Single Windows Machine (AKS-EE)](#path-b-single-windows-machine-aks-ee)
- [Key Documentation](#key-documentation)
- [What's Included](#whats-included)
- [Configuration](#configuration)
- [Next Steps](#next-steps)
- [Support](#support)

## What You Get

- ⚡ **One-command edge setup** - Automated K3s cluster with Azure IoT Operations
- 🏭 **Industrial IoT apps** - Factory simulator, MQTT historian, data processors
- ☁️ **Cloud integration** - Dataflow pipelines to Azure (ADX, Event Hubs, Fabric) using **Managed Identity** — no secrets to manage.
- 🔧 **Production-ready** - Separation of edge and cloud configuration for security
- 💻 **Single-machine (AKS-EE)** - Run everything on one Windows laptop with session-bootstrap.ps1

> **For detailed technical information, see [README_ADVANCED.md](README_ADVANCED.md)**

## Why not use codespaces from the docs? 
The docs have a very clean "one click" deployment in the MSFT docs. It's a great first step, especially if you just want to see the tools. 
* That will live in its own environment and you won't be able to connect it to your signals or your devices. 
* This version will help you set up AIO in the actual environment where you do your IoT operations.
* This is much closer to a production-level deployment.
* This instance will last as long as you want to keep it.

As the end-goal is an IoT solution, this repo has a preference for installing on hardware over virtualization. The goal is that you can put this in your IoT environment, validate the build, and then migrate to a production version. 


# Quick Start
The goal here is to install AIO on an Ubuntu machine (like a local NUC, PC, or a VM) so that you can get working quickly on your dataflow pipelines and get data into Fabric quickly. 
* _if you are in a purely testing or validation phase you can create a quick VM using [this process](quick_vm_build.md)_
* _if you are building on a Windows machine using AKS Edge Essentials, see the [Single Windows Machine (AKS-EE)](#path-b-single-windows-machine-aks-ee) section below._

> **Using AKS Edge Essentials (Windows-based edge)?**  
> Follow the [Deploy AIO on AKS Edge Essentials](https://learn.microsoft.com/en-us/azure/aks/aksarc/aks-edge-howto-deploy-azure-iot) guide to set up your edge cluster, then **skip to step 4** (Azure Configuration from Windows Machine) below. Steps 1–3b do not apply to AKS-EE.

Once you have setup AIO via this process, you should be able to do everything that you want in the cloud without touching the Ubuntu machine again.


### The process (high level)

There are two supported paths. Choose the one that matches your setup:

**Path A — Ubuntu / K3s** (dedicated edge device):

| Step | Where | Script |
|------|-------|--------|
| [1. Edge Setup](#3-edge-setup-on-ubuntu-device) | Edge machine (Ubuntu) | `arc_build_linux/installer.sh` |
| [2. Arc-Enable Cluster](#3b-arc-enable-cluster-on-ubuntu-device) | Edge machine (Ubuntu) | `arc_build_linux/arc_enable.ps1` |
| [3. Grant Roles](#4-azure-configuration-from-windows-machine) | Windows machine | `external_configuration/grant_entra_id_roles.ps1` |
| [4. Deploy AIO](#4-azure-configuration-from-windows-machine) | Windows machine | `external_configuration/External-Configurator.ps1` |

**Path B — AKS Edge Essentials** (single Windows machine):

| Step | Where | Action |
|------|-------|--------|
| [1. Set up AKS-EE cluster](#path-b-single-windows-machine-aks-ee) | Windows machine | [Microsoft AKS-EE quickstart](https://learn.microsoft.com/en-us/azure/aks/aksarc/aks-edge-howto-deploy-azure-iot) |
| [2. Grant Roles](#path-b-single-windows-machine-aks-ee) | Windows machine | `external_configuration/grant_entra_id_roles.ps1` |
| [3. Deploy AIO](#path-b-single-windows-machine-aks-ee) | Windows machine | `external_configuration/External-Configurator.ps1` |

Specific commands for each path are in the [Installation](#installation) section below.

> **Note**: Installing AIO can vary depending on your setup. You may need to run scripts more than once or in a different order. The log messages in each script will tell you what to do next.

## Prerequisites

### Path A: Ubuntu / K3s

**Edge device:**
- Ubuntu machine with 16GB RAM, 4 CPU cores, 50GB disk
- Internet connectivity

**Windows management machine** (see below)

### Path B: AKS Edge Essentials (single Windows machine)

- Windows 10/11 or Windows Server 2019/2022
- 16GB RAM, 4 CPU cores, 50GB free disk
- [AKS Edge Essentials](https://learn.microsoft.com/en-us/azure/aks/aksarc/aks-edge-quickstart) installed
- Internet connectivity
- **Windows management machine** requirements below also apply

### Windows Management Machine (required for all paths)
- **Azure**: Active subscription with admin access
- **PowerShell 7+** (strongly recommended — 5.1 will produce a warning but may still work)  
  Download: <https://aka.ms/install-powershell>
- **Azure CLI ≥ 2.64.0**  
  Install: <https://aka.ms/installazurecliwindows>  
  Check version: `az --version`  
  Upgrade: `az upgrade`
- **Required CLI extensions** (install once, then update with `az extension update --name <ext>`):
  ```powershell
  az extension add --upgrade --name azure-iot-ops
  az extension add --upgrade --name connectedk8s
  ```
- **Execution Policy** — the scripts in this repo are unsigned. Run this once at the start of each PS session:
  ```powershell
  Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force
  ```

## Installation

### Path A: Ubuntu / K3s

### 1. Get the Repository

**Option A — Download ZIP** (no Git required):  
Click the green **Code** button on this GitHub page and choose **Download ZIP**, then extract to a local working directory.

**Option B — Clone with Git**:
```bash
# Install git if not already installed
sudo apt update && sudo apt install -y git

git clone https://github.com/Azure-Samples/explore-iot-operations.git
cd explore-iot-operations/quickstart
```

### 2a. Create and Complete Config File ⚠️ **DO THIS FIRST**

**Before running any installation scripts**, create and configure `aio_config.json`:

```bash
cd config
cp quikstart_config.template aio_config.json
```

Edit `aio_config.json` with your settings:
- Cluster name for your edge device
- Optional tools to install (k9s, mqtt-viewer, ssh, and powershell)

**This config file controls the edge deployment.** Review it carefully before proceeding.

### 3. Edge Setup (On Ubuntu Device)

```bash
cd arc_build_linux
bash installer.sh
```

**What it does**: Installs K3s, kubectl, Helm, and prepares the cluster for Azure IoT Operations  
**Time**: ~10-15 minutes  
**Output**: `config/cluster_info.json` (needed for next step)

> **Note**: System may restart during installation. This is normal. Rerun the script after restart to continue.

### 3b. Arc-Enable Cluster (On Ubuntu Device)

After installer.sh completes, connect the cluster to Azure Arc:

```bash
# Still on the edge device (PowerShell is installed by installer.sh)
pwsh ./arc_enable.ps1
```

**What it does**: 
- Logs into Azure (interactive device code flow)
- Creates resource group if needed
- Connects the K3s cluster to Azure Arc
- Enables required Arc features (custom-locations, OIDC, workload identity)
- Configures K3s to use the Arc OIDC issuer (required for Key Vault secret sync)

**Time**: ~5 minutes  
**Why on the edge device?**: Arc enablement requires kubectl access to the cluster, which isn't available remotely.


After this you should see the core arc-kubernetes components on your edge device. 


> **Note**: If you need remote access via Arc proxy, see [README_ADVANCED.md](README_ADVANCED.md#azure-arc-rbac-issues) for RBAC setup.

### 4. Azure Configuration (From Windows Machine)

> **These scripts are idempotent** — it is normal and expected to run them multiple times. Common reasons include adjusting a parameter, recovering from a partial failure, or re-running `grant_entra_id_roles.ps1` after new resources have been created by `External-Configurator.ps1`. Each run picks up where it left off.

Choose one of three ways to provide your Azure settings to the scripts:

**Option A — Paste values directly in your terminal (quickest, no file editing)**

```powershell
$env:AZURE_SUBSCRIPTION_ID    = "your-subscription-id"
$env:AZURE_LOCATION           = "eastus2"            # e.g. eastus2, westus, westeurope
$env:AZURE_RESOURCE_GROUP     = "rg-my-iot"          # created if it does not exist
$env:AKSEDGE_CLUSTER_NAME     = "my-cluster"         # must be lowercase, no spaces
$env:AZURE_CONTAINER_REGISTRY = ""                   # short name only, e.g. myregistry (leave blank to auto-generate)

# Tenant ID is optional - only needed if you have multiple Azure tenants
# $env:AZURE_TENANT_ID = "your-tenant-id"           # az account show --query tenantId -o tsv

az login   # add --tenant $env:AZURE_TENANT_ID if you have multiple tenants
az account set --subscription $env:AZURE_SUBSCRIPTION_ID

cd external_configuration
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force
.\grant_entra_id_roles.ps1
.\External-Configurator.ps1
```

> **Resource names** (Key Vault, Storage Account, Schema Registry) are not settable via environment variables — they auto-generate from the cluster/resource group name. To specify custom names, use Option C (`aio_config.json`) instead.

**Option B — Edit session-bootstrap.ps1 and run it (recommended if you do this repeatedly)**

Fill in the required variables in `external_configuration\session-bootstrap.ps1` and save. Then run it once per PS7 session — it sets all variables and logs you in automatically. This is especially useful if you open new terminal windows frequently or return to this setup over multiple sessions.
```powershell
$AZ_SUBSCRIPTION_ID    = "your-subscription-id"
$AZ_TENANT_ID          = ""   # optional - only needed if you have multiple Azure tenants
                               # az account show --query tenantId -o tsv
$AZ_LOCATION           = "eastus2"
$AZ_RESOURCE_GROUP     = "rg-my-iot"          # created if it does not exist
$AKS_EDGE_CLUSTER_NAME = "my-cluster"         # must be lowercase, no spaces
$AZ_CONTAINER_REGISTRY = ""   # short name only, e.g. myregistry (leave blank to auto-generate)

# Key Vault, Storage Account, and Schema Registry names are not
# settable here - they auto-generate. To customize them, use Option C.
```
```powershell
cd external_configuration
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force
.\session-bootstrap.ps1
.\grant_entra_id_roles.ps1
.\External-Configurator.ps1
```

**Option C — Copy aio_config.json from the edge device (Linux/K3s path default, and the only option for custom resource names)**

Transfer the `config/` folder from your edge device to your Windows management machine (or copy `aio_config.json` directly). This is also the only way to specify custom names for Key Vault, Storage Account, and Schema Registry — leave them blank to auto-generate:
```json
{
  "azure": {
    "subscription_id": "your-subscription-id",
    "resource_group": "rg-my-iot",
    "location": "eastus2",
    "cluster_name": "my-cluster",
    "storage_account_name": "",   // leave blank to auto-generate
    "key_vault_name": "",         // leave blank to auto-generate
    "container_registry": ""      // leave blank to auto-generate
  }
}
```
```powershell
cd external_configuration
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force
.\grant_entra_id_roles.ps1
.\External-Configurator.ps1
```

> **Note:** Options A and B override any values in `aio_config.json` and work for both the Linux/K3s path and the AKS-EE path.

> **Single-node or demo machine?** Add `-DemoMode` to `External-Configurator.ps1` to reduce broker RAM from ~15.8 GB to ~303 MiB — NOT for production use.

> **Grant permissions separately?** It may be that the person who has permission to assign Azure roles is different from the person deploying. Run `grant_entra_id_roles.ps1` first with the appropriate identity, then `External-Configurator.ps1` separately. To grant permissions to a specific user, pass their Object ID (not email):
> ```powershell
> # Get your Object ID: az ad signed-in-user show --query id -o tsv
> .\grant_entra_id_roles.ps1 -AddUser 12345678-1234-1234-1234-123456789abc
> ```

> **⚠️ IMPORTANT: You may need to run `grant_entra_id_roles.ps1` multiple times!**  
> The script grants permissions to resources that exist at the time it runs. If `External-Configurator.ps1` creates new resources (like Schema Registry) and then fails on role assignments, simply run `grant_entra_id_roles.ps1` again to grant permissions to the newly created resources, then re-run `External-Configurator.ps1`.

> **💡 MOST COMMON ISSUE: Moving to the next step before clusters are ready**  
> If you get errors, don't just re-run the script immediately. The error messages include troubleshooting steps - **read them carefully**. Common issues include:
> - Arc cluster showing "Not Connected" (check Arc agent pods on edge device)
> - Role assignment failures (run `grant_entra_id_roles.ps1` first)
> - IoT Operations deployment failing (ensure Arc is fully connected)
>
> Always verify the previous step completed successfully before moving on. Use `kubectl get pods -n azure-arc` on the edge device to confirm Arc agents are running.

**WARNING** the field `kubeconfig_base64` in cluster_info.json contains a secret. Be careful with that. 

**What it does**: Deploys AIO infrastructure (storage, Key Vault, schema registry) and IoT Operations  
**Time**: ~15-20 minutes  
**Note**: Arc enablement was already done on the edge device in step 3b


### 5. Verify Installation

SSH into your Linux edge device and run:

```bash
# Check pods are running
kubectl get pods -n azure-iot-operations
```

Once AIO is running, subscribe to all MQTT topics to confirm messages are flowing:

```bash
kubectl exec -it -n azure-iot-operations deploy/aio-broker-frontend -- \
  mosquitto_sub -h localhost -p 18883 -t '#' -v
```

Press `Ctrl+C` to stop. If you see messages arriving, AIO is working end-to-end.

---

### Path B: Single Windows Machine (AKS-EE)

If you are running both AKS Edge Essentials (edge) and the Azure management scripts on the **same Windows laptop**, `session-bootstrap.ps1` is an optional convenience helper — or you can skip it entirely and paste values directly in your terminal.

#### Prerequisites
- PowerShell 7+ (`winget install Microsoft.PowerShell`)
- Azure CLI ≥ 2.64.0 (`winget install Microsoft.AzureCLI`)
- `azure-iot-ops` and `connectedk8s` extensions (see [Prerequisites](#prerequisites))

#### Workflow

> **AKS Edge Essentials vs. AKS**: In this path, Kubernetes runs locally on your Windows machine via **AKS Edge Essentials (AKS-EE)** — a lightweight, Microsoft-supported K8s distribution embedded in Windows. This is different from the Ubuntu/K3s path (which uses K3s) and from cloud-hosted AKS. AKS-EE is still Arc-enabled and managed through Azure the same way, but the cluster itself lives on your local machine rather than on a separate edge device or in the cloud.

**Step 1 — Set your Azure context (choose one option)**

You can either clone the repository or download and unzip. 
```powershell
$repo     = "Azure-Samples/explore-iot-operations"
$branch   = "main"
$zipUrl   = "https://github.com/$repo/archive/refs/heads/$branch.zip"
$outZip   = ".\explore-iot-operations.zip"
$outDir   = ".\explore-iot-operations"

Invoke-WebRequest -Uri $zipUrl -OutFile $outZip -UseBasicParsing
Expand-Archive $outZip -DestinationPath . -Force
Rename-Item ".\explore-iot-operations-$branch" $outDir -Force
Remove-Item $outZip
```

_Option A — Paste values directly in your terminal (quickest, no file editing):_

> **Tip**: Option A is the fastest way to get going — just paste and run. Option B is worth the one-time setup if you return to this workflow regularly or work across multiple terminal sessions.

```powershell
$env:AZURE_SUBSCRIPTION_ID    = "your-subscription-id"
$env:AZURE_LOCATION           = "eastus2"            # e.g. eastus2, westus, westeurope
$env:AZURE_RESOURCE_GROUP     = "rg-my-iot"          # created if it does not exist
$env:AKSEDGE_CLUSTER_NAME     = "my-cluster"         # must be lowercase, no spaces
$env:AZURE_CONTAINER_REGISTRY = ""                   # short name only, e.g. myregistry (leave blank to auto-generate)

# Tenant ID is optional - only needed if you have multiple Azure tenants
# $env:AZURE_TENANT_ID = "your-tenant-id"           # az account show --query tenantId -o tsv

az login   # add --tenant $env:AZURE_TENANT_ID if you have multiple tenants
az account set --subscription $env:AZURE_SUBSCRIPTION_ID
```

> **Resource names** (Key Vault, Storage Account, Schema Registry) are not settable via environment variables — they auto-generate from the cluster/resource group name. To specify custom names, use Option B (session-bootstrap) which also reads from `aio_config.json`, or copy `aio_config.json` directly.

_Option B — Use session-bootstrap.ps1 (recommended if you do this repeatedly):_

Fill in the required variables in `external_configuration\session-bootstrap.ps1` and save. Run it once at the start of each PS7 session — it sets all variables, including the `$global:*` variables for the AKS-EE quickstart, and logs you in automatically. Especially useful if you open new terminal windows frequently.
```powershell
$AZ_SUBSCRIPTION_ID    = "your-subscription-id"
$AZ_TENANT_ID          = ""   # optional - only needed if you have multiple Azure tenants
                               # az account show --query tenantId -o tsv
$AZ_LOCATION           = "eastus2"
$AZ_RESOURCE_GROUP     = "rg-my-iot"          # created if it does not exist
$AKS_EDGE_CLUSTER_NAME = "my-cluster"         # must be lowercase, no spaces
$AZ_CONTAINER_REGISTRY = ""   # short name only, e.g. myregistry (leave blank to auto-generate)

# Key Vault, Storage Account, and Schema Registry names are not
# settable here - they auto-generate. To customize them, use aio_config.json.
```
```powershell
cd external_configuration
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force
.\session-bootstrap.ps1
```

**Step 2 — Set up your AKS-EE edge cluster**

Download the AKS-EE quickstart files, then follow the [Deploy AIO on AKS Edge Essentials](https://learn.microsoft.com/en-us/azure/aks/aksarc/aks-edge-howto-deploy-azure-iot) guide:

```powershell
$giturl = "https://raw.githubusercontent.com/Azure/AKS-Edge/main/tools"
Invoke-WebRequest -Uri "$giturl/scripts/AksEdgeQuickStart/AksEdgeQuickStartForAio.ps1" `
    -OutFile .\AksEdgeQuickStartForAio.ps1 -UseBasicParsing
Invoke-WebRequest -Uri "$giturl/aio-aide-userconfig.json" `
    -OutFile .\aio-aide-userconfig.json -UseBasicParsing
Invoke-WebRequest -Uri "$giturl/aio-aksedge-config.json" `
    -OutFile .\aio-aksedge-config.json -UseBasicParsing
Unblock-File .\AksEdgeQuickStartForAio.ps1
```

> **Note**: The AKS-EE quickstart script does **not** read environment variables. You must fill in `aio-aide-userconfig.json` and `aio-aksedge-config.json` manually before running it, even if you have set `$env:AKSEDGE_CLUSTER_NAME` etc. in your session. If you used Option B (`session-bootstrap.ps1`), the `$global:*` variables it sets are picked up automatically by the quickstart.

**Step 3 — Grant permissions and deploy AIO**

After either option above, run:
```powershell
.\grant_entra_id_roles.ps1
.\External-Configurator.ps1 -DemoMode   # -DemoMode recommended for single-machine setups
```

> To grant permissions to a specific user instead of yourself, pass their Object ID:
> ```powershell
> .\grant_entra_id_roles.ps1 -AddUser 12345678-1234-1234-1234-123456789abc
> ```

**Step 4 (Optional) — Deploy an edge module**

> **These modules are not part of AIO itself.** They are demo applications that generate simulated data or mimic industrial processes so you can see AIO working end-to-end without needing real hardware or live signals. They would not belong in a production system — replace them with your own data sources when you're ready.

Once AIO is running, you can push containerized applications to the edge cluster from your Windows machine. This step requires **Docker Desktop** running locally to build the image before pushing to ACR. 

Deploy the factory MQTT simulator (`edgemqttsim`) as a first module:

```powershell
# Deploy edgemqttsim — builds the image, pushes to ACR, and applies the K8s manifest
.\Deploy-EdgeModules.ps1 -ModuleName edgemqttsim
```

If the image is already built and in the registry (e.g. on a re-deploy), skip the Docker build step:

```powershell
.\Deploy-EdgeModules.ps1 -ModuleName edgemqttsim -SkipBuild
```

To force a fresh redeployment of a module that is already running:

```powershell
.\Deploy-EdgeModules.ps1 -ModuleName edgemqttsim -Force
```

To deploy all modules configured in `aio_config.json` at once, omit `-ModuleName`:

```powershell
.\Deploy-EdgeModules.ps1
```

**What it does**: Builds the container image on your Windows machine, pushes it to the Azure Container Registry created by `External-Configurator.ps1`, then applies the Kubernetes deployment manifest to the edge cluster via Azure Arc proxy — no direct network access to the edge device required.  
**Available modules**: `edgemqttsim`, `hello-flask`, `sputnik`, `demohistorian`  
**Note**: The ACR registry endpoint must be registered in AIO before image pulls will succeed — this is done automatically by `External-Configurator.ps1`.



## Key Documentation

### Infrastructure & Setup

- **[Config Files Guide](./config/readme.md)** - Configuration file templates and outputs
- **[Linux Build Advanced](./arc_build_linux/linux_build_steps.md)** - Advanced flags, troubleshooting, and cleanup scripts
- **`arc_build_linux/installer.sh`** - Edge device installer (local infrastructure only)
- **`external_configuration/External-Configurator.ps1`** - Remote Azure configurator (cloud resources only)
- **`external_configuration/Deploy-EdgeModules.ps1`** - Automated deployment script for edge applications

### Applications & Samples

- **[Edge MQTT Simulator](./modules/edgemqttsim/README.md)** - Comprehensive factory telemetry simulator
- **[Edge Historian](./modules/demohistorian/README.md)** - SQL-based historian with HTTP API for querying historical MQTT data
- **Fabric Integration** - See [README_ADVANCED.md](README_ADVANCED.md#fabric-integration) for connecting AIO to Microsoft Fabric

## What's Included

### Edge Applications (`modules/`)
- **edgemqttsim** - Factory equipment simulator (CNC, 3D printer, welding, etc.)
- **demohistorian** - SQL-based MQTT historian with HTTP API
- **sputnik** - Simple MQTT test publisher
- **hello-flask** - Basic web app for testing

### Key Directories
- **`arc_build_linux/`** - Edge device installation scripts (runs on Ubuntu)
- **`external_configuration/`** - Azure configuration scripts (runs on Windows)
- **`config/`** - Configuration files and cluster info outputs
- **`arm_templates/`** - ARM templates for Azure resource deployment
- **`modules/`** - Deployable edge modules

## Configuration

Customize edge deployment via `arc_build_linux/aio_config.json`:
- Cluster name for your edge device
- Optional tools (k9s, MQTT viewers, SSH)
- Azure AD principal for Arc proxy access

Customize Azure deployment via `config/aio_config.json`:
- Azure subscription and resource group settings
- Location and namespace configuration
- Key Vault settings for secret management
- `container_registry` — short name (e.g. `myregistry`) for the Azure Container Registry used by `Deploy-EdgeModules.ps1`; auto-generated if blank

## Next Steps

After installation:

1. **View MQTT messages**: See [README_ADVANCED.md](README_ADVANCED.md#monitoring-mqtt-traffic)
2. **Deploy applications**: See [README_ADVANCED.md](README_ADVANCED.md#deploying-edge-applications)
3. **Connect to Fabric**: See [README_ADVANCED.md](README_ADVANCED.md#fabric-integration)
4. **Troubleshooting**: See [README_ADVANCED.md](README_ADVANCED.md#troubleshooting)

## Documentation

- **[README_ADVANCED.md](README_ADVANCED.md)** - Detailed technical guide
- **[Application READMEs](modules/)** - Individual app documentation

## Support

- [Azure IoT Operations Docs](https://learn.microsoft.com/azure/iot-operations/)
- [K3s Documentation](https://docs.k3s.io/)
- [Issue Tracker](https://github.com/Azure-Samples/explore-iot-operations/issues)