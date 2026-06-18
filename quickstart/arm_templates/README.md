# ARM Templates for Azure IoT Operations

This folder contains ARM (Azure Resource Manager) templates for deploying Azure IoT Operations infrastructure as code.

## Templates

| Template | Description |
|----------|-------------|
| `resourceGroup.json` | Creates the resource group (subscription-level deployment) |
| `storageAccount.json` | Creates storage account for schema registry with HNS enabled |
| `keyVault.json` | Creates Azure Key Vault with RBAC authorization |
| `deviceRegistryNamespace.json` | Creates Device Registry namespace |
| `schemaRegistry.json` | Creates IoT Operations schema registry |
| `managedIdentity.json` | Creates user-assigned managed identity for secret sync |
| `storageRoleAssignment.json` | Assigns Storage Blob Data Contributor role |
| `keyVaultRoleAssignment.json` | Assigns Key Vault Secrets User role |

## Parameters

Copy `parameters.template.json` to `parameters.json` and fill in your values:

```bash
cp parameters.template.json parameters.json
```

**Important**: `parameters.json` is git-ignored to prevent committing sensitive values.

## Deployment Order

The templates should be deployed in this order:

1. **Resource Group** (subscription-level)
   ```powershell
   az deployment sub create --location eastus --template-file resourceGroup.json --parameters resourceGroupName=rg-iot-ops location=eastus
   ```

2. **Storage Account**
   ```powershell
   az deployment group create -g rg-iot-ops --template-file storageAccount.json --parameters storageAccountName=aioschemas123
   ```

3. **Key Vault**
   ```powershell
   az deployment group create -g rg-iot-ops --template-file keyVault.json --parameters keyVaultName=aio-kv-123
   ```

4. **Device Registry Namespace**
   ```powershell
   az deployment group create -g rg-iot-ops --template-file deviceRegistryNamespace.json --parameters namespaceName=iot-operations-ns
   ```

5. **Schema Registry** (requires storage account)
   ```powershell
   az deployment group create -g rg-iot-ops --template-file schemaRegistry.json --parameters schemaRegistryName=aio-schema-reg storageAccountName=aioschemas123
   ```

6. **Storage Role Assignment** (assigns schema registry identity to storage)
   ```powershell
   # Get principal ID from schema registry deployment output
   az deployment group create -g rg-iot-ops --template-file storageRoleAssignment.json --parameters storageAccountName=aioschemas123 principalId=<schema-registry-principal-id>
   ```

7. **Managed Identity** (for secret sync)
   ```powershell
   az deployment group create -g rg-iot-ops --template-file managedIdentity.json --parameters managedIdentityName=aio-secretsync-mi
   ```

8. **Key Vault Role Assignment**
   ```powershell
   az deployment group create -g rg-iot-ops --template-file keyVaultRoleAssignment.json --parameters keyVaultName=aio-kv-123 principalId=<managed-identity-principal-id>
   ```

## Automated Deployment

Use `External-Configurator.ps1` to automate this deployment sequence:

```powershell
cd external_configuration
.\External-Configurator.ps1
```

The script reads configuration from `config/aio_config.json` and cluster info from `config/cluster_info.json`.

## Notes

- **Arc Enablement**: Azure Arc connection and IoT Operations instance creation still require Azure CLI commands (`az connectedk8s`, `az iot ops`) as these involve cluster-side operations
- **What-If**: Always validate deployments first:
  ```powershell
  az deployment group what-if -g rg-iot-ops --template-file <template>.json --parameters <params>
  ```
- **API Versions**: Templates use latest stable API versions as of January 2026
