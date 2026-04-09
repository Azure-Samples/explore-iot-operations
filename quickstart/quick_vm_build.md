# Quick Test VM: Azure CLI Commands

## Prerequisites
```bash
# Login and set subscription
az login
az account set --subscription "<your-subscription-id>"
```

## 1. Create Resource Group
```bash
az group create --name rg-test-vm --location eastus
```

## 2. Create the VM
This is the most basic VM that can run IoT Operations. 
```bash
az vm create --resource-group rg-test-vm --name test-vm-01 --image Ubuntu2204 --size Standard_D4s_v3 --admin-username azureuser --generate-ssh-keys --output table
```

> This outputs the public IP. `--generate-ssh-keys` creates a key pair in `~/.ssh/` if one doesn't exist.

## 3. Connect via SSH

**Option A — Key-based (simple, works immediately):**
```bash
az ssh vm --resource-group rg-test-vm --name test-vm-01 --local-user azureuser
```

> Requires the `ssh` Azure CLI extension: `az extension add --name ssh`
> Uses the SSH key generated during VM creation (`~/.ssh/id_rsa`).

**Option B — Entra ID login (no key needed, but requires extra setup first):**

Install the AAD SSH extension on the VM:
```bash
az vm extension set --publisher Microsoft.Azure.ActiveDirectory --name AADSSHLoginForLinux --resource-group rg-test-vm --vm-name test-vm-01
```

Grant yourself the login role (use your own Object ID from `az ad signed-in-user show --query id -o tsv`):
```bash
az role assignment create --role "Virtual Machine Administrator Login" --scope $(az vm show --resource-group rg-test-vm --name test-vm-01 --query id -o tsv) --assignee <your-object-id>
```

Then connect:
```bash
az ssh vm --resource-group rg-test-vm --name test-vm-01
```

## 4. (Optional) Open a Port
```bash
az vm open-port --resource-group rg-test-vm --name test-vm-01 --port 80
```

---

## Destroy Everything

Since the VM and all its resources (NIC, disk, public IP, NSG) are in a dedicated resource group, deleting the group nukes everything cleanly:

```bash
az group delete --name rg-test-vm --yes --no-wait
```

> `--yes` skips the confirmation prompt. `--no-wait` returns immediately without blocking.

To confirm deletion is complete:
```bash
az group show --name rg-test-vm
# Returns an error when fully deleted
```

---

**Cost note**: `Standard_D4s_v3` (~$0.19/hr) has 4 vCPUs and 16 GB RAM, meeting the [IoT Operations minimum requirements](https://learn.microsoft.com/en-us/azure/iot-operations/deploy-iot-ops/overview-deploy#supported-environments) (4 CPU cores, 16 GB RAM). Remember to delete the resource group when done — the resource group approach guarantees no orphaned resources (disks, NICs, IPs) are left behind billed.
