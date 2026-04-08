# IoT Operations Applications

This directory contains containerized applications designed to be deployed to Azure IoT Operations (AIO) Kubernetes clusters running on edge devices.

These are for demo purposes mostly but can be used to test and validate your AIO build. 

## Available Applications

### � sputnik
An MQTT publisher that sends periodic "beep" messages to the Azure IoT Operations MQTT broker.

**Features:**
- MQTT v5 with ServiceAccountToken (K8S-SAT) authentication
- Sends timestamped beep messages every 5 seconds
- Demonstrates in-cluster MQTT publishing
- Auto-reconnection and error handling

**Quick Deploy:** Automatically deployed via GitHub Actions when pushing to `dev` branch
  
[📖 Read the docs →](./sputnik/README.md)

### 👂 mosquitto-sub
An MQTT subscriber that displays messages from the Azure IoT Operations MQTT broker in real-time.
 
**Features:**
- Subscribe to any MQTT topic (with wildcard support)
- Uses official eclipse-mosquitto image (no build needed)
- Same K8S-SAT authentication as Sputnik
- Perfect for testing and debugging MQTT message flow

**Quick Deploy:** Automatically deployed via GitHub Actions when pushing to `dev` branch

**View Messages:** `kubectl logs -n default -l app=mosquitto-sub -f`
  
[📖 Read the docs →](./mosquitto-sub/README.md) | [⚡ Quick Start →](./mosquitto-sub/QUICKSTART.md)

### �📦 hello-flask
A simple Flask "Hello World" REST API that demonstrates:
- Container deployment to IoT Operations
- Remote deployment from Windows to edge devices
- Using `uv` for Python dependency management
- Kubernetes service exposure on local networks
- Health checks and monitoring

**Quick Deploy:** `.\Deploy-ToIoTEdge.ps1 -AppFolder "hello-flask" -RegistryName "your-username"`
  
[📖 Read the docs →](./hello-flask/README.md)

## Deployment Scripts

This folder contains three modular PowerShell deployment scripts that work with any application in the `iotopps` folder:

### 📤 Deploy-ToIoTEdge.ps1
Deploy applications to remote IoT Operations clusters via Azure Arc.

**Usage:**
```powershell
.\Deploy-ToIoTEdge.ps1 -AppFolder "hello-flask" -RegistryName "your-username"
.\Deploy-ToIoTEdge.ps1 -AppFolder "my-app" -RegistryName "myacr" -RegistryType "acr" -ImageTag "v1.0"
```

**Parameters:**
- `-AppFolder` (Required): Name of the app folder to deploy
- `-RegistryName` (Required): Docker Hub username or ACR name
- `-RegistryType`: `dockerhub` or `acr` (default: dockerhub)
- `-ImageTag`: Image tag (default: latest)
- `-SkipBuild`: Skip Docker build/push (use existing image)
- `-EdgeDeviceIP`: Direct SSH connection fallback
- `-ConfigPath`: Override default config location

### 🏠 Deploy-Local.ps1
Run applications locally for development and testing.

**Usage:**
```powershell
.\Deploy-Local.ps1 -AppFolder "hello-flask"
.\Deploy-Local.ps1 -AppFolder "my-app" -Mode docker -Port 8080
.\Deploy-Local.ps1 -AppFolder "hello-flask" -Mode python -Clean
```

**Parameters:**
- `-AppFolder` (Required): Name of the app folder to run
- `-Mode`: `python`, `docker`, `uv`, or `auto` (default: auto)
- `-Port`: Local port (default: 5000)
- `-Build`: Force Docker rebuild
- `-Clean`: Clean Python venv before setup

### 🔍 Deploy-Check.ps1
Check deployment status and health of deployed applications.

**Usage:**
```powershell
.\Deploy-Check.ps1 -AppFolder "hello-flask"
.\Deploy-Check.ps1 -AppFolder "my-app" -EdgeDeviceIP "192.168.1.100"
```

**Parameters:**
- `-AppFolder` (Required): Name of the app folder to check
- `-EdgeDeviceIP`: Direct connection to edge device
- `-ConfigPath`: Override default config location

## Deployment Workflows

### Two-Machine Workflow (Docker on one machine, Kubernetes access on another)

If you have Docker and Kubernetes access on separate machines:

**On the machine with Docker:**
1. Build and push your container image to Docker Hub or ACR (see "Build and Push Container Images Manually" section below)
2. Note the full image name (e.g., `username/hello-flask:latest`)

**On the machine with Kubernetes/Arc access:**
1. Run the deployment script with `-SkipBuild` to deploy the pre-built image:
   ```powershell
   .\Deploy-ToIoTEdge.ps1 -AppFolder "hello-flask" -RegistryName "your-username" -SkipBuild
   ```

The script will detect if Docker is missing and provide instructions for manual image building.

### Remote Deployment (Windows → Edge Device)
Deploy applications from your Windows development machine to remote IoT Operations clusters:

1. Configure your cluster in `../config/aio_config.json`
2. From the `iotopps` folder, run the deployment script:
   ```powershell
   .\Deploy-ToIoTEdge.ps1 -AppFolder "hello-flask" -RegistryName "your-registry"
   ```

The script handles:
- ✓ Building Docker images
- ✓ Pushing to container registry
- ✓ Connecting to Arc-enabled clusters
- ✓ Deploying to Kubernetes
- ✓ Verifying deployment status

### Local Development
Test applications locally before deploying:

1. From the `iotopps` folder, run:
   ```powershell
   .\Deploy-Local.ps1 -AppFolder "hello-flask"
   ```
2. Access at `http://localhost:5000`

### Check Deployment Status
Monitor your deployed applications:

```powershell
.\Deploy-Check.ps1 -AppFolder "hello-flask"
```

## Prerequisites

### For Remote Deployment
- **Docker Desktop (Windows/Mac)** - Optional if using two-machine workflow (see below)
- Azure CLI (`az`)
- kubectl
- Access to container registry (Docker Hub or ACR)
- Azure IoT Operations deployed and Arc-connected

**Two-Machine Setup:**
- Machine 1 (Build): Docker Desktop for building images
- Machine 2 (Deploy): Azure CLI + kubectl for deployment (no Docker needed)
- Both machines need access to the same container registry

### For Local Development
- Python 3.8+ OR Docker OR uv
- Application dependencies (see app-specific requirements.txt)

## Project Structure

```
iotopps/
├── README.md                    # This file
├── Deploy-ToIoTEdge.ps1        # Modular remote deployment script
├── Deploy-Local.ps1             # Modular local development script
├── Deploy-Check.ps1             # Modular deployment status checker
├── .vscode/
│   └── settings.json           # VS Code settings (uses uv for Python)
└── hello-flask/                # Flask Hello World app
    ├── app.py                  # Flask application
    ├── Dockerfile              # Container definition (uses uv)
    ├── requirements.txt        # Python dependencies
    ├── deployment.yaml         # Kubernetes manifest
    ├── hello_flask_config.json # App-specific configuration (optional)
    ├── README.md               # Full documentation
    ├── QUICKSTART.md           # Quick start guide
    └── FILE-GUIDE.md           # File descriptions
```

## Configuration

### Cluster Configuration
Your IoT Operations cluster configuration is stored in:
```
../config/aio_config.json
```

This file contains:
- Azure subscription details
- Resource group name
- Cluster name and location
- Deployment preferences

All deployment scripts automatically read this configuration.

### Application Configuration (Optional)
Each application can have its own config file (e.g., `hello_flask_config.json`) containing:
- Registry settings (type, name)
- Image tags
- Development preferences (port, runtime mode)

## Common Commands

### Build and Push Container Images Manually

If you have Docker on a separate machine from your Kubernetes cluster access, you can build and push images manually:

#### For Docker Hub:
```bash
# Navigate to your app folder
cd iotopps/hello-flask

# Build the image
docker build -t hello-flask:latest .

# Tag for your registry
docker tag hello-flask:latest YOUR-DOCKERHUB-USERNAME/hello-flask:latest

# Login to Docker Hub
docker login

# Push to Docker Hub
docker push YOUR-DOCKERHUB-USERNAME/hello-flask:latest
```

#### For Azure Container Registry (ACR):
```bash
# Navigate to your app folder
cd iotopps/hello-flask

# Build the image
docker build -t hello-flask:latest .

# Tag for ACR
docker tag hello-flask:latest YOUR-ACR-NAME.azurecr.io/hello-flask:latest

# Login to ACR (requires Azure CLI)
az acr login --name YOUR-ACR-NAME

# Push to ACR
docker push YOUR-ACR-NAME.azurecr.io/hello-flask:latest
```

After pushing the image, you can deploy it from a machine without Docker using:
```powershell
.\Deploy-ToIoTEdge.ps1 -AppFolder "hello-flask" -RegistryName "YOUR-USERNAME" -SkipBuild
```

### Deploy an Application
```powershell
# Deploy to IoT Edge cluster
.\Deploy-ToIoTEdge.ps1 -AppFolder "hello-flask" -RegistryName "myusername"

# Deploy with custom tag
.\Deploy-ToIoTEdge.ps1 -AppFolder "hello-flask" -RegistryName "myusername" -ImageTag "v1.0"
```

### Check Application Status
```powershell
.\Deploy-Check.ps1 -AppFolder "hello-flask"
```

### Run Locally
```powershell
# Auto-detect runtime (uv > docker > python)
.\Deploy-Local.ps1 -AppFolder "hello-flask"

# Specify runtime
.\Deploy-Local.ps1 -AppFolder "hello-flask" -Mode docker
```

### View Application Logs
```bash
kubectl logs -l app=hello-flask
```

### Access Applications
Applications are exposed via NodePort on the edge device's network:
```
http://<edge-device-ip>:30080
```

### Update Application
1. Modify source code in the app folder
2. Redeploy with new tag:
   ```powershell
   .\Deploy-ToIoTEdge.ps1 -AppFolder "hello-flask" -RegistryName "your-username" -ImageTag "v1.1"
   ```

## Adding New Applications

To add a new application to this directory:

1. **Create Application Folder**
   ```powershell
   mkdir iotopps\my-new-app
   cd iotopps\my-new-app
   ```

2. **Add Required Files**
   - Application code (e.g., `app.py`, `main.py`)
   - `Dockerfile` - Container definition
   - `deployment.yaml` - Kubernetes manifest
   - `requirements.txt` - Dependencies (if Python)

3. **Create Kubernetes Deployment Manifest**
   ```yaml
   # deployment.yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: my-new-app
   spec:
     replicas: 1
     selector:
       matchLabels:
         app: my-new-app
     template:
       metadata:
         labels:
           app: my-new-app
       spec:
         containers:
         - name: my-new-app
           image: <YOUR_REGISTRY>/my-new-app:latest
           ports:
           - containerPort: 5000
   ---
   apiVersion: v1
   kind: Service
   metadata:
     name: my-new-app-service
   spec:
     type: NodePort
     selector:
       app: my-new-app
     ports:
     - port: 80
       targetPort: 5000
       nodePort: 30081
   ```

4. **Optional: Add App Config**
   Create `my_new_app_config.json` for default settings:
   ```json
   {
     "registry": {
       "type": "dockerhub",
       "name": "your-username"
     },
     "image": {
       "tag": "latest"
     },
     "development": {
       "localPort": 5000,
       "preferredRuntime": "auto"
     }
   }
   ```

5. **Deploy Your Application**
   ```powershell
   # From iotopps folder
   .\Deploy-Local.ps1 -AppFolder "my-new-app"
   .\Deploy-ToIoTEdge.ps1 -AppFolder "my-new-app" -RegistryName "your-username"
   ```

6. **Update Documentation**
   - Add your app to the "Available Applications" section in this README
   - Create an app-specific README in your app folder

### Application Requirements
- **Dockerfile**: Must expose the application port
- **deployment.yaml**: Must use `<YOUR_REGISTRY>` placeholder for registry name
- **Service naming**: Use `{app-name}-service` convention
- **Labels**: Use `app: {app-name}` for pod selection

## Technology Stack

- **Container Runtime**: Docker
- **Orchestration**: Kubernetes (K3s)
- **Python Package Manager**: `uv` (fast, modern)
- **Edge Platform**: Azure IoT Operations
- **Cloud Integration**: Azure Arc

## Related Documentation

- [Linux Build Steps](../../linux_build/linux_build_steps.md) - Setting up IoT Operations
- [K3s Troubleshooting](../../linux_build/K3S_TROUBLESHOOTING_GUIDE.md) - Cluster issues
- [Project README](../../readme.md) - Overall project documentation

## Next Steps

- ✅ Deploy your first application (hello-flask)
- 🔄 Integrate with MQTT broker for IoT messaging
- 📊 Add monitoring and observability
- 🔒 Implement security best practices
- 🚀 Set up CI/CD pipelines
- 📦 Create additional applications

## Support

For issues or questions:
1. Check application-specific README files
2. Review troubleshooting guides in `linux_build/`
3. Check Azure IoT Operations documentation
4. Review Kubernetes logs and events
