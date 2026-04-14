# Linux Build Scripts - Advanced Reference

> **For basic installation, see [readme.md](../readme.md)**. This document covers advanced features, flags, and troubleshooting.

## External Configuration Steps (Steps 4+)

After `installer.sh` and `arc_enable.ps1` complete on the Linux edge device, the remaining steps run **from a Windows machine** using PowerShell. You need to provide your Azure configuration values to those scripts. There are two ways to do this:

---

### Option A: Copy aio_config.json (Recommended)

If you already filled in `config/aio_config.json` on the Linux machine, copy it to the same path on the Windows machine. The `External-Configurator.ps1` script reads it automatically.

Required fields in `aio_config.json`:
```json
{
  "azure": {
    "subscription_id": "your-subscription-id",
    "resource_group":  "rg-my-iot",
    "location":        "eastus2",
    "cluster_name":    "my-cluster"
  }
}
```

---

### Option B: Fill in session-bootstrap.ps1 (Zero-JSON workflow)

On the Windows machine, open `external_configuration\session-bootstrap.ps1` and fill in the required values at the top:

```powershell
$AZ_SUBSCRIPTION_ID    = "your-subscription-id"
$AZ_TENANT_ID          = "your-tenant-id"
$AZ_LOCATION           = "eastus2"      # or your preferred region
$AZ_RESOURCE_GROUP     = "rg-my-iot"   # created if it doesn't exist
$AKS_EDGE_CLUSTER_NAME = "my-cluster"  # must match cluster_name in aio_config.json
$CUSTOM_LOCATIONS_OID  = ""            # see below
$AZ_CONTAINER_REGISTRY = ""            # short name, e.g. myregistry (optional)
```

To get `CUSTOM_LOCATIONS_OID`, run once in any Azure CLI session:
```bash
az ad sp show --id bc313c14-388c-4e7d-a58e-70017303ee3b --query id -o tsv
```

Then run the bootstrap script once at the start of each PowerShell session before any other scripts:
```powershell
cd external_configuration
.\session-bootstrap.ps1

# Then proceed with:
.\External-Configurator.ps1
.\grant_entra_id_roles.ps1
```

---



### installer.sh

| Flag | Description |
|------|-------------|
| `--force-reinstall` | Complete reinstall - removes K3s, Arc registration, and starts fresh |
| `--skip-system-update` | Skip apt update/upgrade for faster runs (use with caution) |

```bash
# Force complete reinstall
./installer.sh --force-reinstall

# Complete cleanup without reinstall
./linux_aio_cleanup.sh
```

### arc_enable.ps1

Runs after `installer.sh` to connect the cluster to Azure Arc and enable custom-locations. Requires PowerShell (installed automatically by installer.sh).

```bash
pwsh ./arc_enable.ps1

# Verify custom-locations is enabled:
helm get values azure-arc -n azure-arc-release -o json | jq '.systemDefaultValues.customLocations'
```

**Note**: The script now runs `helm upgrade` automatically to enable custom-locations (previously this was a separate manual step).

## Color-Coded Output

- **Green**: Success
- **Yellow**: Warnings (review but may be OK)
- **Red**: Errors (action required)

## Advanced Troubleshooting

### Config File Cluster Name Mismatch

The cluster name must match between config files:
```bash
# Check both files
cat ../config/aio_config.json | grep cluster_name
cat ../config/cluster_info.json | grep cluster_name
```

### Stale Arc Registration

If your cluster was previously Arc-enabled with a different name or resource group:
```bash
# installer.sh detects and fixes this automatically
# For manual cleanup:
./installer.sh --force-reinstall
```

### Arc Proxy RBAC Issues

If `Deploy-EdgeModules.ps1` fails with "Forbidden" errors, you need to create a ClusterRoleBinding:

```bash
# On the edge device, run:
kubectl create clusterrolebinding azure-user-admin \
  --clusterrole=cluster-admin \
  --user=<YOUR_ENTRA_ID_OBJECT_ID>
```

To automate this for future installs, add `manage_principal` to your `aio_config.json`:
```json
{
  "azure": {
    "manage_principal": "<YOUR_ENTRA_ID_OBJECT_ID>"
  }
}
```

### Custom Locations Not Enabled

If `az iot ops create` fails with "resource provider does not have required permissions":

```bash
# Re-run arc_enable.ps1 - it now runs helm upgrade automatically
pwsh ./arc_enable.ps1

# Or run the helm command manually:
helm upgrade azure-arc azure-arc \
  --namespace azure-arc-release \
  --reuse-values \
  --set systemDefaultValues.customLocations.enabled=true \
  --set systemDefaultValues.customLocations.oid=<your-custom-locations-oid> \
  --wait
```

This is needed because `Az.ConnectedKubernetes` registers the OID with ARM but doesn't update the Helm chart.

### View Detailed Logs

```bash
# Installer logs (timestamped)
cat linuxAIO_*.log

# K3s service status
sudo systemctl status k3s
journalctl -u k3s -f

# Arc agent logs
kubectl logs -n azure-arc -l app.kubernetes.io/component=connect-agent
```

### Manual Component Verification

```bash
# K3s running
sudo systemctl status k3s

# Nodes ready
kubectl get nodes

# Arc agents healthy (should be 12+ pods Running)
kubectl get pods -n azure-arc

# IoT Operations pods
kubectl get pods -n azure-iot-operations

# CSI Secret Store driver
kubectl get pods -n kube-system | grep secrets-store
```

## Cleanup Scripts

### linux_aio_cleanup.sh

Removes everything for a fresh start:
- Uninstalls K3s
- Removes Azure Arc registration
- Cleans up kubectl config
- Removes generated files

```bash
chmod +x linux_aio_cleanup.sh
./linux_aio_cleanup.sh
```

## Files Generated by installer.sh

| File | Location | Purpose |
|------|----------|---------|
| `cluster_info.json` | `../config/` | Cluster details for External-Configurator.ps1 |

| `linuxAIO_*.log` | Current dir | Detailed installation logs |
