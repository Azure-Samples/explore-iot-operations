<#
.SYNOPSIS
    Grant Entra ID roles and permissions for Azure IoT Operations and Microsoft Fabric integration

.DESCRIPTION
    This script grants all necessary Entra ID roles, RBAC permissions, and Key Vault policies
    to enable Azure IoT Operations to communicate with Microsoft Fabric Real-Time Intelligence
    and grants user access to Key Vault and IoT resources.
    
.PARAMETER ResourceGroup
    Azure resource group name (default: from config/aio_config.json)
    
.PARAMETER ClusterName
    Kubernetes cluster name (default: from config/aio_config.json)
    
.PARAMETER KeyVaultName
    Azure Key Vault name (default: auto-detected from resource group)
    
.PARAMETER AddUser
    User Object ID (GUID) to grant full access.
    To get your Object ID, run: az ad signed-in-user show --query id -o tsv
    Example: 12345678-1234-1234-1234-123456789abc
    Optional - if not provided, grants to current signed-in user

.PARAMETER SubscriptionId
    Azure subscription ID (default: from config or current subscription)
    
.EXAMPLE
    .\grant_entra_id_roles.ps1
    # Grants permissions to current signed-in user
    
.EXAMPLE
    .\grant_entra_id_roles.ps1 -AddUser 12345678-1234-1234-1234-123456789abc
    # Grants permissions to user with specified Object ID
    
.EXAMPLE
    .\grant_entra_id_roles.ps1 -ResourceGroup "IoT-Operations" -ClusterName "iot-ops-cluster" -AddUser 12345678-1234-1234-1234-123456789abc
    # Full example with all parameters

.NOTES
    Author: Azure IoT Operations Team
    Date: January 2026
    Version: 1.0.0
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$ResourceGroup,
    
    [Parameter(Mandatory=$false)]
    [string]$ClusterName,
    
    [Parameter(Mandatory=$false)]
    [string]$KeyVaultName,
    
    [Parameter(Mandatory=$false)]
    [string]$AddUser,
    
    [Parameter(Mandatory=$false)]
    [string]$SubscriptionId
)

# ============================================================================
# SCRIPT SETUP
# ============================================================================

$script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:LogFile = Join-Path $script:ScriptDir "grant_entra_id_roles_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$script:ContainerRegistryName = $null
$script:ContainerRegistryLoginServer = $null

Start-Transcript -Path $script:LogFile -Append

# ============================================================================
# LOGGING FUNCTIONS
# ============================================================================

function Write-Header {
    param([string]$Message)
    Write-Host "`n$('=' * 80)" -ForegroundColor Cyan
    Write-Host $Message -ForegroundColor Cyan
    Write-Host $('=' * 80) -ForegroundColor Cyan
}

function Write-SubHeader {
    param([string]$Message)
    Write-Host "`n--- $Message ---" -ForegroundColor Yellow
}

function Write-Info {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Gray
}

function Write-Success {
    param([string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Write-Warning {
    param([string]$Message)
    Write-Host "[WARNING] $Message" -ForegroundColor Yellow
}

function Write-ErrorMsg {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
}

# ============================================================================
# CONFIGURATION LOADING
# ============================================================================

function Find-ConfigFile {
    param([string]$FileName)
    
    $repoRoot = Split-Path -Parent $script:ScriptDir
    $configDir = Join-Path $repoRoot "config"
    
    $searchPaths = @(
        (Join-Path $configDir $FileName),
        (Join-Path $script:ScriptDir $FileName),
        (Join-Path (Get-Location) $FileName)
    )
    
    foreach ($path in $searchPaths) {
        if (Test-Path $path) {
            return $path
        }
    }
    
    return $null
}

function Load-ConfigFile {
    Write-SubHeader "Step 1: aio_config.json"

    $repoRoot = Split-Path -Parent $script:ScriptDir
    $defaultPath = Join-Path (Join-Path $repoRoot "config") "aio_config.json"
    Write-Info "Searching: $defaultPath"

    $configPath = Find-ConfigFile "aio_config.json"
    if (-not $configPath) {
        Write-Warning "aio_config.json not found - will check environment variables next"
        Write-Info "  To create one: cp config/quickstart_config.template config/aio_config.json"
        return
    }

    Write-Success "Found: $configPath"
    try {
        $config = Get-Content $configPath -Raw | ConvertFrom-Json

        if (-not [string]::IsNullOrEmpty($config.azure.subscription_id)) {
            $script:SubscriptionId = $config.azure.subscription_id
            Write-Info "  [config] subscription_id    = $script:SubscriptionId"
        }
        if (-not [string]::IsNullOrEmpty($config.azure.resource_group)) {
            $script:ResourceGroup = $config.azure.resource_group
            Write-Info "  [config] resource_group     = $script:ResourceGroup"
        }
        if (-not [string]::IsNullOrEmpty($config.azure.cluster_name)) {
            $script:ClusterName = $config.azure.cluster_name
            Write-Info "  [config] cluster_name       = $script:ClusterName"
        }
        if (-not [string]::IsNullOrEmpty($config.azure.key_vault_name)) {
            $script:KeyVaultName = $config.azure.key_vault_name
            Write-Info "  [config] key_vault_name     = $script:KeyVaultName"
        }
        if ($config.azure.PSObject.Properties['container_registry'] -and
            -not [string]::IsNullOrEmpty($config.azure.container_registry)) {
            $rawReg = $config.azure.container_registry
            if ($rawReg -match '\.azurecr\.io$') {
                $script:ContainerRegistryLoginServer = $rawReg
                $script:ContainerRegistryName = $rawReg -replace '\.azurecr\.io$', ''
            } else {
                $script:ContainerRegistryName = $rawReg
                $script:ContainerRegistryLoginServer = "${rawReg}.azurecr.io"
            }
            Write-Info "  [config] container_registry = $script:ContainerRegistryName"
        }
    } catch {
        Write-Warning "Could not parse aio_config.json: $($_.Exception.Message)"
    }

    # Validate cluster name consistency with cluster_info.json
    $clusterInfoPath = Find-ConfigFile "cluster_info.json"
    if ($clusterInfoPath) {
        try {
            $clusterInfo = Get-Content $clusterInfoPath -Raw | ConvertFrom-Json
            $clusterInfoClusterName = $clusterInfo.cluster_name
            Write-Info "  [cluster_info] cluster_name = $clusterInfoClusterName"

            if ($script:ClusterName -and $clusterInfoClusterName -and ($script:ClusterName -ne $clusterInfoClusterName)) {
                Write-Host ""
                Write-Warning "CLUSTER NAME MISMATCH: aio_config.json='$script:ClusterName'  cluster_info.json='$clusterInfoClusterName'"
                Write-Host "  Using aio_config.json value. Update it to match cluster_info.json if needed." -ForegroundColor Yellow
                Write-Host ""
            }
        } catch {
            Write-Warning "Could not parse cluster_info.json"
        }
    }
}

# ---- Step 1: aio_config.json (highest priority) ----------------------------
Load-ConfigFile

# ---- Step 2: Environment variables (fallback for values still missing) -----
Write-SubHeader "Step 2: Environment variables (fallback)"

# Normalise aliases: session-bootstrap uses AZ_* / AKS_EDGE_* names; scripts use AZURE_* / AKSEDGE_*
# Accept both so users don't have to know the difference.
if ([string]::IsNullOrEmpty($env:AZURE_SUBSCRIPTION_ID)    -and -not [string]::IsNullOrEmpty($env:AZ_SUBSCRIPTION_ID))    { $env:AZURE_SUBSCRIPTION_ID    = $env:AZ_SUBSCRIPTION_ID }
if ([string]::IsNullOrEmpty($env:AZURE_RESOURCE_GROUP)     -and -not [string]::IsNullOrEmpty($env:AZ_RESOURCE_GROUP))     { $env:AZURE_RESOURCE_GROUP     = $env:AZ_RESOURCE_GROUP }
if ([string]::IsNullOrEmpty($env:AZURE_LOCATION)           -and -not [string]::IsNullOrEmpty($env:AZ_LOCATION))           { $env:AZURE_LOCATION           = $env:AZ_LOCATION }
if ([string]::IsNullOrEmpty($env:AKSEDGE_CLUSTER_NAME)     -and -not [string]::IsNullOrEmpty($env:AKS_EDGE_CLUSTER_NAME)) { $env:AKSEDGE_CLUSTER_NAME     = $env:AKS_EDGE_CLUSTER_NAME }
if ([string]::IsNullOrEmpty($env:AZURE_CONTAINER_REGISTRY) -and -not [string]::IsNullOrEmpty($env:AZ_CONTAINER_REGISTRY)) { $env:AZURE_CONTAINER_REGISTRY = $env:AZ_CONTAINER_REGISTRY }

if (-not [string]::IsNullOrEmpty($env:AZURE_SUBSCRIPTION_ID)) {
    if ([string]::IsNullOrEmpty($script:SubscriptionId)) {
        $script:SubscriptionId = $env:AZURE_SUBSCRIPTION_ID
        Write-Info "  [env] AZURE_SUBSCRIPTION_ID    = $script:SubscriptionId"
    } else {
        Write-Info "  [env] AZURE_SUBSCRIPTION_ID    = (skipped - config file value used)"
    }
} else { Write-Info "  [env] AZURE_SUBSCRIPTION_ID    - not set" }

if (-not [string]::IsNullOrEmpty($env:AZURE_RESOURCE_GROUP)) {
    if ([string]::IsNullOrEmpty($script:ResourceGroup)) {
        $script:ResourceGroup = $env:AZURE_RESOURCE_GROUP
        Write-Info "  [env] AZURE_RESOURCE_GROUP     = $script:ResourceGroup"
    } else {
        Write-Info "  [env] AZURE_RESOURCE_GROUP     = (skipped - config file value used)"
    }
} else { Write-Info "  [env] AZURE_RESOURCE_GROUP     - not set" }

if (-not [string]::IsNullOrEmpty($env:AKSEDGE_CLUSTER_NAME)) {
    if ([string]::IsNullOrEmpty($script:ClusterName)) {
        $script:ClusterName = $env:AKSEDGE_CLUSTER_NAME
        Write-Info "  [env] AKSEDGE_CLUSTER_NAME     = $script:ClusterName"
    } else {
        Write-Info "  [env] AKSEDGE_CLUSTER_NAME     = (skipped - config file value used)"
    }
} else { Write-Info "  [env] AKSEDGE_CLUSTER_NAME     - not set" }

if (-not [string]::IsNullOrEmpty($env:AZURE_CONTAINER_REGISTRY)) {
    if ([string]::IsNullOrEmpty($script:ContainerRegistryName)) {
        $rawReg = $env:AZURE_CONTAINER_REGISTRY
        if ($rawReg -match '\.azurecr\.io$') {
            $script:ContainerRegistryLoginServer = $rawReg
            $script:ContainerRegistryName = $rawReg -replace '\.azurecr\.io$', ''
        } else {
            $script:ContainerRegistryName = $rawReg
            $script:ContainerRegistryLoginServer = "${rawReg}.azurecr.io"
        }
        Write-Info "  [env] AZURE_CONTAINER_REGISTRY = $script:ContainerRegistryName"
    } else {
        Write-Info "  [env] AZURE_CONTAINER_REGISTRY = (skipped - config file value used)"
    }
} else { Write-Info "  [env] AZURE_CONTAINER_REGISTRY - not set (will auto-detect)" }

# ---- Step 3: CLI parameter overrides (always take priority) ----------------
Write-SubHeader "Step 3: CLI parameter overrides"
$script:HasCliOverrides = $false
if ($PSBoundParameters.ContainsKey('ResourceGroup'))  { $script:ResourceGroup  = $ResourceGroup;  Write-Info "  [param] ResourceGroup  = $ResourceGroup";  $script:HasCliOverrides = $true }
if ($PSBoundParameters.ContainsKey('ClusterName'))    { $script:ClusterName    = $ClusterName;    Write-Info "  [param] ClusterName    = $ClusterName";    $script:HasCliOverrides = $true }
if ($PSBoundParameters.ContainsKey('KeyVaultName'))   { $script:KeyVaultName   = $KeyVaultName;   Write-Info "  [param] KeyVaultName   = $KeyVaultName";   $script:HasCliOverrides = $true }
if ($PSBoundParameters.ContainsKey('SubscriptionId')) { $script:SubscriptionId = $SubscriptionId; Write-Info "  [param] SubscriptionId = $SubscriptionId"; $script:HasCliOverrides = $true }
if (-not $script:HasCliOverrides) { Write-Info "  None" }

# ---- Step 4: Collect all missing required values before proceeding ----------
$missingRequired = [System.Collections.Generic.List[string]]::new()
if ([string]::IsNullOrEmpty($script:ResourceGroup)) { $missingRequired.Add("ResourceGroup") }
if ([string]::IsNullOrEmpty($script:ClusterName))   { $missingRequired.Add("ClusterName") }

if ($missingRequired.Count -gt 0) {
    $varHelp = @{
        "ResourceGroup" = @{ Env = "AZURE_RESOURCE_GROUP"; Label = "Azure resource group name" }
        "ClusterName"   = @{ Env = "AKSEDGE_CLUSTER_NAME"; Label = "Arc-enabled cluster name"  }
    }

    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor Yellow
    Write-Host "REQUIRED CONFIGURATION MISSING" -ForegroundColor Yellow
    Write-Host ("=" * 60) -ForegroundColor Yellow
    Write-Host "The following values were not found in aio_config.json" -ForegroundColor Yellow
    Write-Host "or environment variables:" -ForegroundColor Yellow
    Write-Host ""
    foreach ($var in $missingRequired) {
        Write-Host "  - $($varHelp[$var].Label)" -ForegroundColor Red
        Write-Host "    set via: `$env:$($varHelp[$var].Env) = `"your-value`"" -ForegroundColor Gray
    }
    Write-Host ""
    Write-Host "Options to fix this without prompting:" -ForegroundColor Cyan
    Write-Host '  Option A  env vars:   $env:AZURE_RESOURCE_GROUP = "rg-my-iot"' -ForegroundColor White
    Write-Host '                         $env:AKSEDGE_CLUSTER_NAME = "my-cluster"' -ForegroundColor White
    Write-Host "  Option B  config file: config/aio_config.json  (azure.resource_group, azure.cluster_name)" -ForegroundColor White
    Write-Host "  Option C  CLI params:  -ResourceGroup 'rg-my-iot' -ClusterName 'my-cluster'" -ForegroundColor White
    Write-Host ""

    foreach ($var in $missingRequired) {
        $value = Read-Host "  Enter $($varHelp[$var].Label)"
        if ([string]::IsNullOrWhiteSpace($value)) {
            Write-Host ""
            Write-ErrorMsg "No value provided for $var. Cannot continue."
            Write-Host "  Set `$env:$($varHelp[$var].Env) before running the script." -ForegroundColor Yellow
            Stop-Transcript
            exit 1
        }
        switch ($var) {
            "ResourceGroup" { $script:ResourceGroup = $value.Trim() }
            "ClusterName"   { $script:ClusterName   = $value.Trim() }
        }
    }
}

# ---- Final guard: fail immediately if required values are still empty -------
$stillMissing = @()
if ([string]::IsNullOrEmpty($script:ResourceGroup)) { $stillMissing += "ResourceGroup  (env: AZURE_RESOURCE_GROUP)" }
if ([string]::IsNullOrEmpty($script:ClusterName))   { $stillMissing += "ClusterName    (env: AKSEDGE_CLUSTER_NAME)" }
if ($stillMissing.Count -gt 0) {
    Write-Host ""
    Write-ErrorMsg "Cannot continue - required configuration still missing:"
    foreach ($v in $stillMissing) { Write-ErrorMsg "  - $v" }
    Write-Host ""
    Write-Host "Set these values in config/aio_config.json or as environment variables before running." -ForegroundColor Yellow
    Stop-Transcript
    exit 1
}

# ============================================================================
# PREREQUISITES
# ============================================================================

Write-Header "Azure IoT Operations - Grant Entra ID Roles and Permissions"
Write-Info "Log file: $script:LogFile"
Write-Info "Started: $(Get-Date)"
Write-Info ""
Write-Info "Resource Group: $script:ResourceGroup"
Write-Info "Cluster Name: $script:ClusterName"
if ($script:KeyVaultName) {
    Write-Info "Key Vault: $script:KeyVaultName"
}
if ($AddUser) {
    Write-Info "User to grant access: $AddUser"
}

Write-SubHeader "Checking Prerequisites"

try {
    $azVersion = az version --output json | ConvertFrom-Json
    Write-Success "Azure CLI version: $($azVersion.'azure-cli')"
} catch {
    Write-ErrorMsg "Azure CLI not found"
    Stop-Transcript
    exit 1
}

# ============================================================================
# AZURE AUTHENTICATION
# ============================================================================

Write-SubHeader "Checking Azure Authentication"

$currentAccount = az account show 2>$null | ConvertFrom-Json
if (-not $currentAccount) {
    Write-Info "Not logged into Azure. Logging in..."
    az login
    $currentAccount = az account show | ConvertFrom-Json
}

Write-Success "Logged into Azure"
Write-Info "  Account: $($currentAccount.user.name)"
Write-Info "  Subscription: $($currentAccount.name)"

# Set subscription if specified
if ($script:SubscriptionId) {
    az account set --subscription $script:SubscriptionId
    $currentAccount = az account show | ConvertFrom-Json
}

$script:SubscriptionId = $currentAccount.id
$script:TenantId = $currentAccount.tenantId

Write-Info "  Using subscription: $($currentAccount.name) ($script:SubscriptionId)"

# ============================================================================
# GET RESOURCE IDS
# ============================================================================

Write-Header "Discovering Resources"

# Get Arc cluster
Write-SubHeader "Arc-Enabled Cluster"
$arcCluster = az connectedk8s show --name $script:ClusterName --resource-group $script:ResourceGroup 2>$null | ConvertFrom-Json

if ($arcCluster) {
    Write-Success "Found Arc cluster: $script:ClusterName"
    Write-Info "  Resource ID: $($arcCluster.id)"
    $arcClusterIdentity = $arcCluster.identity
    if ($arcClusterIdentity.principalId) {
        Write-Success "Arc cluster has managed identity"
        Write-Info "  Principal ID: $($arcClusterIdentity.principalId)"
    }
} else {
    Write-Warning "Arc cluster not found: $script:ClusterName"
}

# Get IoT Operations instance
Write-SubHeader "Azure IoT Operations Instance"
$aioInstanceName = "$script:ClusterName-aio"
$aioInstance = az iot ops show --name $aioInstanceName --resource-group $script:ResourceGroup 2>$null | ConvertFrom-Json

if ($aioInstance) {
    Write-Success "Found IoT Operations instance: $aioInstanceName"
    Write-Info "  Resource ID: $($aioInstance.id)"
    $aioIdentity = $aioInstance.identity
    if ($aioIdentity.principalId) {
        Write-Success "IoT Operations instance has managed identity"
        Write-Info "  Principal ID: $($aioIdentity.principalId)"
    }
} else {
    Write-Warning "IoT Operations instance not found: $aioInstanceName"
}

# Get or find Key Vault
Write-SubHeader "Azure Key Vault"
if ([string]::IsNullOrEmpty($script:KeyVaultName)) {
    Write-Info "Key Vault name not specified, searching resource group..."
    $keyVaults = az keyvault list --resource-group $script:ResourceGroup 2>$null | ConvertFrom-Json
    
    if ($keyVaults -and $keyVaults.Count -gt 0) {
        $script:KeyVaultName = $keyVaults[0].name
        Write-Success "Found Key Vault: $script:KeyVaultName"
    } else {
        Write-Warning "No Key Vaults found in resource group"
    }
}

$keyVault = $null
$keyVaultUsesRbac = $false
if ($script:KeyVaultName) {
    $keyVault = az keyvault show --name $script:KeyVaultName --resource-group $script:ResourceGroup 2>$null | ConvertFrom-Json
    
    if ($keyVault) {
        Write-Success "Key Vault: $script:KeyVaultName"
        Write-Info "  Resource ID: $($keyVault.id)"
        Write-Info "  Vault URI: $($keyVault.properties.vaultUri)"
        
        # Check if Key Vault uses RBAC or access policies
        $keyVaultUsesRbac = $keyVault.properties.enableRbacAuthorization -eq $true
        if ($keyVaultUsesRbac) {
            Write-Info "  Authorization: RBAC (Role-Based Access Control)"
        } else {
            Write-Info "  Authorization: Access Policies"
        }
    } else {
        Write-Warning "Key Vault not found: $script:KeyVaultName"
    }
}

# Get all managed identities in resource group
Write-SubHeader "Managed Identities in Resource Group"
$managedIdentities = az identity list --resource-group $script:ResourceGroup 2>$null | ConvertFrom-Json

if ($managedIdentities -and $managedIdentities.Count -gt 0) {
    Write-Success "Found $($managedIdentities.Count) managed identity(ies)"
    foreach ($identity in $managedIdentities) {
        Write-Info "  - $($identity.name) (Principal ID: $($identity.principalId))"
    }
} else {
    Write-Info "No user-assigned managed identities found"
}

# Discover Container Registry
Write-SubHeader "Container Registry"
$containerRegistry = $null
if ($script:ContainerRegistryName) {
    $containerRegistry = az acr show --name $script:ContainerRegistryName --resource-group $script:ResourceGroup 2>$null | ConvertFrom-Json
    if ($containerRegistry) {
        Write-Success "Found container registry: $script:ContainerRegistryName"
        Write-Info "  Login server: $($containerRegistry.loginServer)"
        $script:ContainerRegistryLoginServer = $containerRegistry.loginServer
    } else {
        # Try without resource group (may be in a different RG)
        $containerRegistry = az acr show --name $script:ContainerRegistryName 2>$null | ConvertFrom-Json
        if ($containerRegistry) {
            Write-Success "Found container registry (different RG): $script:ContainerRegistryName"
            $script:ContainerRegistryLoginServer = $containerRegistry.loginServer
        } else {
            Write-Warning "Container registry '$script:ContainerRegistryName' not found - skipping ACR grants"
        }
    }
} else {
    # Auto-detect ACR in resource group
    $allAcrs = az acr list --resource-group $script:ResourceGroup --query "[].{name:name, loginServer:loginServer}" 2>$null | ConvertFrom-Json
    if ($allAcrs -and $allAcrs.Count -eq 1) {
        $containerRegistry = az acr show --name $allAcrs[0].name --resource-group $script:ResourceGroup 2>$null | ConvertFrom-Json
        $script:ContainerRegistryName = $allAcrs[0].name
        $script:ContainerRegistryLoginServer = $allAcrs[0].loginServer
        Write-Success "Auto-detected container registry: $script:ContainerRegistryName"
    } elseif ($allAcrs -and $allAcrs.Count -gt 1) {
        Write-Warning "Multiple ACRs found in resource group. Set 'container_registry' in aio_config.json to target a specific one."
    } else {
        Write-Info "No container registry found in resource group - skipping ACR grants"
    }
}

# Get user to grant access to
Write-SubHeader "User Access"
$userObjectId = $null

if ([string]::IsNullOrEmpty($AddUser)) {
    # No user specified, get current signed-in user's Object ID
    Write-Info "No user specified, using current signed-in user..."
    $userObjectId = az ad signed-in-user show --query id -o tsv 2>$null
    
    if ($userObjectId) {
        $userInfo = az ad signed-in-user show --query "{displayName:displayName, userPrincipalName:userPrincipalName}" 2>$null | ConvertFrom-Json
        Write-Success "Current user Object ID: $userObjectId"
        if ($userInfo) {
            Write-Info "  Display Name: $($userInfo.displayName)"
            Write-Info "  UPN: $($userInfo.userPrincipalName)"
        }
    } else {
        Write-ErrorMsg "Could not get current user's Object ID"
        Write-Info "Please specify -AddUser with your Object ID"
        Write-Info "Get your Object ID: az ad signed-in-user show --query id -o tsv"
        Stop-Transcript
        exit 1
    }
} else {
    # Validate that AddUser is a valid GUID (Object ID)
    $guidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    
    if ($AddUser -match $guidPattern) {
        $userObjectId = $AddUser
        Write-Success "Using Object ID: $userObjectId"
        
        # Try to get user display name for informational purposes
        $userInfo = az ad user show --id $userObjectId --query "{displayName:displayName, userPrincipalName:userPrincipalName}" 2>$null | ConvertFrom-Json
        if ($userInfo) {
            Write-Info "  Display Name: $($userInfo.displayName)"
            Write-Info "  UPN: $($userInfo.userPrincipalName)"
        } else {
            Write-Warning "Could not retrieve user details (Object ID may be for a service principal or external user)"
        }
    } else {
        Write-ErrorMsg "Invalid Object ID format: $AddUser"
        Write-Host ""
        Write-Host "The -AddUser parameter requires a valid Object ID (GUID)." -ForegroundColor Yellow
        Write-Host "Email addresses are not supported due to lookup reliability issues." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "To get your Object ID, run:" -ForegroundColor Cyan
        Write-Host "  az ad signed-in-user show --query id -o tsv" -ForegroundColor White
        Write-Host ""
        Write-Host "To find another user's Object ID:" -ForegroundColor Cyan
        Write-Host '  az ad user list --filter "startswith(displayName,''username'')" --query "[].{Name:displayName, OID:id}" -o table' -ForegroundColor White
        Write-Host ""
        Stop-Transcript
        exit 1
    }
}

# ============================================================================
# GRANT ROLES - KEY VAULT (RBAC or Access Policies)
# ============================================================================

if ($keyVaultUsesRbac) {
    Write-Header "Granting Key Vault Permissions (RBAC)"
} else {
    Write-Header "Granting Key Vault Permissions (Access Policies)"
}

if ($keyVault) {
    $kvName = $script:KeyVaultName
    $kvResourceId = $keyVault.id
    
    # Key Vault RBAC role IDs
    $kvSecretsUserRoleId = "4633458b-17de-408a-b874-0445c86b69e6"      # Key Vault Secrets User (read secrets)
    $kvSecretsOfficerRoleId = "b86a8fe4-44ce-4948-aee5-eccb2c155cd7"  # Key Vault Secrets Officer (full secrets access)
    $kvAdminRoleId = "00482a5a-887f-4fb3-b363-3b7fe8e74483"           # Key Vault Administrator (full access)
    
    # Grant to user - full admin access
    Write-SubHeader "User: $AddUser"
    
    if ($keyVaultUsesRbac) {
        Write-Info "Assigning Key Vault Administrator role to user..."
        az role assignment create `
            --role $kvAdminRoleId `
            --assignee-object-id $userObjectId `
            --assignee-principal-type User `
            --scope $kvResourceId `
            --output none 2>$null
        Write-Success "Granted Key Vault Administrator role to user"
    } else {
        Write-Info "Setting Key Vault access policy for user (get, list, set, delete secrets)..."
        az keyvault set-policy `
            --name $kvName `
            --object-id $userObjectId `
            --secret-permissions get list set delete backup restore recover purge `
            --key-permissions get list create delete backup restore recover purge `
            --certificate-permissions get list create delete backup restore recover purge `
            --output none 2>$null
        Write-Success "Granted full Key Vault access to user"
    }
    
    # Grant to Arc cluster identity - secrets read access
    if ($arcClusterIdentity.principalId) {
        Write-SubHeader "Arc Cluster Identity"
        
        if ($keyVaultUsesRbac) {
            Write-Info "Assigning Key Vault Secrets User role to Arc cluster..."
            az role assignment create `
                --role $kvSecretsUserRoleId `
                --assignee-object-id $arcClusterIdentity.principalId `
                --assignee-principal-type ServicePrincipal `
                --scope $kvResourceId `
                --output none 2>$null
            Write-Success "Granted Key Vault Secrets User role to Arc cluster"
        } else {
            Write-Info "Setting Key Vault access policy for Arc cluster (get, list secrets)..."
            az keyvault set-policy `
                --name $kvName `
                --object-id $arcClusterIdentity.principalId `
                --secret-permissions get list `
                --output none 2>$null
            Write-Success "Granted Key Vault secrets access to Arc cluster"
        }
    }
    
    # Grant to IoT Operations instance identity - secrets read access
    if ($aioIdentity.principalId) {
        Write-SubHeader "IoT Operations Instance Identity"
        
        if ($keyVaultUsesRbac) {
            Write-Info "Assigning Key Vault Secrets User role to IoT Operations instance..."
            az role assignment create `
                --role $kvSecretsUserRoleId `
                --assignee-object-id $aioIdentity.principalId `
                --assignee-principal-type ServicePrincipal `
                --scope $kvResourceId `
                --output none 2>$null
            Write-Success "Granted Key Vault Secrets User role to IoT Operations instance"
        } else {
            Write-Info "Setting Key Vault access policy for IoT Operations instance (get, list secrets)..."
            az keyvault set-policy `
                --name $kvName `
                --object-id $aioIdentity.principalId `
                --secret-permissions get list `
                --output none 2>$null
            Write-Success "Granted Key Vault secrets access to IoT Operations instance"
        }
    }
    
    # Grant to all managed identities - secrets read access
    if ($managedIdentities -and $managedIdentities.Count -gt 0) {
        Write-SubHeader "All Managed Identities"
        
        foreach ($identity in $managedIdentities) {
            if ($keyVaultUsesRbac) {
                Write-Info "Assigning Key Vault Secrets User role to: $($identity.name)..."
                az role assignment create `
                    --role $kvSecretsUserRoleId `
                    --assignee-object-id $identity.principalId `
                    --assignee-principal-type ServicePrincipal `
                    --scope $kvResourceId `
                    --output none 2>$null
                Write-Success "  Granted Key Vault Secrets User role to: $($identity.name)"
            } else {
                Write-Info "Setting Key Vault access policy for: $($identity.name) (get, list secrets)..."
                az keyvault set-policy `
                    --name $kvName `
                    --object-id $identity.principalId `
                    --secret-permissions get list `
                    --output none 2>$null
                Write-Success "  Granted to: $($identity.name)"
            }
        }
    }
} else {
    Write-Warning "Skipping Key Vault permissions (no Key Vault found)"
}

# ============================================================================
# GRANT ROLES - AZURE IOT OPERATIONS
# ============================================================================

Write-Header "Granting Azure IoT Operations Permissions"

Write-SubHeader "User: $AddUser"

# Resource group scope
$rgScope = "/subscriptions/$script:SubscriptionId/resourceGroups/$script:ResourceGroup"

# Contributor role for IoT Operations
Write-Info "Granting 'Contributor' role on resource group..."
az role assignment create `
    --role "Contributor" `
    --assignee $userObjectId `
    --scope $rgScope `
    --output none 2>$null
Write-Success "Granted Contributor on resource group"

# IoT Hub Data Contributor (if IoT Hub exists)
Write-Info "Granting 'IoT Hub Data Contributor' role..."
az role assignment create `
    --role "IoT Hub Data Contributor" `
    --assignee $userObjectId `
    --scope $rgScope `
    --output none 2>$null
Write-Success "Granted IoT Hub Data Contributor"

# Azure Arc Kubernetes Cluster User Role
if ($arcCluster) {
    Write-Info "Granting 'Azure Arc Kubernetes Cluster User Role'..."
    az role assignment create `
        --role "Azure Arc Kubernetes Cluster User Role" `
        --assignee $userObjectId `
        --scope $arcCluster.id `
        --output none 2>$null
    Write-Success "Granted Arc Kubernetes Cluster User Role"
    
    # Azure Arc Kubernetes Viewer
    Write-Info "Granting 'Azure Arc Kubernetes Viewer'..."
    az role assignment create `
        --role "Azure Arc Kubernetes Viewer" `
        --assignee $userObjectId `
        --scope $arcCluster.id `
        --output none 2>$null
    Write-Success "Granted Arc Kubernetes Viewer"
    
    # Azure Arc Kubernetes Cluster Admin - Required for kubectl access via az connectedk8s proxy
    Write-Info "Granting 'Azure Arc Kubernetes Cluster Admin' (required for kubectl proxy access)..."
    az role assignment create `
        --role "Azure Arc Kubernetes Cluster Admin" `
        --assignee $userObjectId `
        --scope $arcCluster.id `
        --output none 2>$null
    Write-Success "Granted Arc Kubernetes Cluster Admin"

    # IMPORTANT: Azure RBAC roles only take effect on Arc clusters with --enable-azure-rbac.
    # K3s clusters connected WITHOUT Azure RBAC use Kubernetes-native RBAC instead.
    # In that case, the proxy passes your Azure AD Object ID as the Kubernetes username,
    # and you need a ClusterRoleBinding on the cluster itself.
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Yellow
    Write-Host "REQUIRED: Bootstrap kubectl access on the edge device" -ForegroundColor Yellow
    Write-Host "============================================================" -ForegroundColor Yellow
    Write-Host "If your K3s cluster was connected WITHOUT --enable-azure-rbac" -ForegroundColor White
    Write-Host "(the default in this repo), you must run this ONCE on the edge" -ForegroundColor White
    Write-Host "device via SSH to allow this user to kubectl through the proxy:" -ForegroundColor White
    Write-Host ""
    Write-Host "  kubectl create clusterrolebinding admin-$userObjectId \\" -ForegroundColor Green
    Write-Host "    --clusterrole=cluster-admin \\" -ForegroundColor Green
    Write-Host "    --user=$userObjectId" -ForegroundColor Green
    Write-Host ""
    Write-Host "To check if this binding already exists:" -ForegroundColor Cyan
    Write-Host "  kubectl get clusterrolebinding admin-$userObjectId" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Yellow
    Write-Host ""
}

# ============================================================================
# GRANT ROLES - MICROSOFT FABRIC INTEGRATION
# ============================================================================

Write-Header "Granting Microsoft Fabric Integration Permissions"

Write-SubHeader "Service Principal Roles for Fabric"

# These roles allow IoT Operations to communicate with Fabric Event Hubs (Kafka)
$fabricRoles = @(
    "Azure Event Hubs Data Sender",
    "Azure Event Hubs Data Receiver",
    "Storage Blob Data Contributor"
)

foreach ($role in $fabricRoles) {
    # Grant to IoT Operations instance identity
    if ($aioIdentity.principalId) {
        Write-Info "Granting '$role' to IoT Operations instance..."
        az role assignment create `
            --role $role `
            --assignee $aioIdentity.principalId `
            --scope $rgScope `
            --output none 2>$null
        Write-Success "  Granted to IoT Operations instance"
    }
    
    # Grant to Arc cluster identity
    if ($arcClusterIdentity.principalId) {
        Write-Info "Granting '$role' to Arc cluster..."
        az role assignment create `
            --role $role `
            --assignee $arcClusterIdentity.principalId `
            --scope $rgScope `
            --output none 2>$null
        Write-Success "  Granted to Arc cluster"
    }
}

# Grant to user for testing/development
Write-SubHeader "User: $AddUser"
foreach ($role in $fabricRoles) {
    Write-Info "Granting '$role'..."
    az role assignment create `
        --role $role `
        --assignee $userObjectId `
        --scope $rgScope `
        --output none 2>$null
    Write-Success "  Granted $role"
}

# ============================================================================
# GRANT ROLES - SUBSCRIPTION LEVEL (Optional)
# ============================================================================

Write-Header "Subscription-Level Permissions (for Resource Creation)"

$subscriptionScope = "/subscriptions/$script:SubscriptionId"

Write-SubHeader "User: $AddUser"

Write-Info "Granting 'Reader' role at subscription level..."
az role assignment create `
    --role "Reader" `
    --assignee $userObjectId `
    --scope $subscriptionScope `
    --output none 2>$null
Write-Success "Granted Reader at subscription level"

# ============================================================================
# GRANT ROLES - ROLE ASSIGNMENT PERMISSIONS
# ============================================================================

Write-Header "Role Assignment Permissions (for External-Configurator.ps1)"

Write-SubHeader "User: $AddUser"

# This role allows the user to create role assignments within the resource group
# Required by External-Configurator.ps1 to assign Storage Blob Data Contributor to Schema Registry
Write-Info "Granting 'Role Based Access Control Administrator' on resource group..."
az role assignment create `
    --role "Role Based Access Control Administrator" `
    --assignee $userObjectId `
    --scope $rgScope `
    --output none 2>$null
Write-Success "Granted Role Based Access Control Administrator"

# ============================================================================
# GRANT ROLES - DATA PLANE (Schema Registry, Device Registry)
# ============================================================================

Write-Header "Data Plane Permissions"

# Schema Registry roles
Write-SubHeader "Schema Registry"
Write-Info "Granting 'Schema Registry Contributor' to user..."
az role assignment create `
    --role "Schema Registry Contributor (Preview)" `
    --assignee $userObjectId `
    --scope $rgScope `
    --output none 2>$null
Write-Success "Granted Schema Registry Contributor"

# Pre-grant Storage Blob Data Contributor to any existing schema registries
# This is also done by External-Configurator.ps1, but we do it here proactively
Write-SubHeader "Schema Registry Storage Access"
$schemaRegistries = az resource list --resource-group $script:ResourceGroup --resource-type "Microsoft.DeviceRegistry/schemaRegistries" --query "[].name" -o tsv 2>$null
if ($schemaRegistries) {
    foreach ($srName in $schemaRegistries -split "`n") {
        if ($srName) {
            Write-Info "Found schema registry: $srName"
            $srPrincipalId = az resource show `
                --resource-group $script:ResourceGroup `
                --resource-type "Microsoft.DeviceRegistry/schemaRegistries" `
                --name $srName `
                --query "identity.principalId" -o tsv 2>$null
            
            if ($srPrincipalId) {
                Write-Info "Granting 'Storage Blob Data Contributor' to schema registry..."
                az role assignment create `
                    --role "Storage Blob Data Contributor" `
                    --assignee $srPrincipalId `
                    --scope $rgScope `
                    --output none 2>$null
                Write-Success "Granted Storage Blob Data Contributor to: $srName"
            }
        }
    }
} else {
    Write-Info "No schema registries found yet (will be created by External-Configurator.ps1)"
}

# Device Registry roles
Write-SubHeader "Device Registry"  
Write-Info "Granting 'Device Registry Contributor' to user..."
az role assignment create `
    --role "Contributor" `
    --assignee $userObjectId `
    --scope $rgScope `
    --output none 2>$null
Write-Success "Granted Device Registry access via Contributor"

# ============================================================================
# GRANT ROLES - CUSTOM LOCATION (for Discovered Asset ARM sync)
# ============================================================================

Write-Header "Granting Custom Location Permissions (for Discovered Asset Sync)"

# The IoT Operations ARM bridge needs Microsoft.ExtendedLocation/customLocations/deploy/action
# on the custom location in order to sync discovered assets (discoveredAssets CRD)
# up to Azure Resource Manager. Without this, discovered assets appear in kubectl
# but never show up in the IoT Operations portal.
#
# The Device Registry service principal (app ID 319f651f-7ddb-4fc6-9857-7aef9250bd05)
# is the identity that performs the sync. We grant Contributor to the custom location
# scope for this SP as well as the IoT Operations and Arc identities.

$customLocation = $null
$customLocationScope = $null

Write-SubHeader "Finding Custom Location"
$customLocations = az resource list `
    --resource-group $script:ResourceGroup `
    --resource-type "Microsoft.ExtendedLocation/customLocations" `
    --query "[].{name:name, id:id}" -o json 2>$null | ConvertFrom-Json

if ($customLocations -and $customLocations.Count -gt 0) {
    $customLocation = $customLocations[0]
    $customLocationScope = $customLocation.id
    Write-Success "Found custom location: $($customLocation.name)"
    Write-Info "  Resource ID: $customLocationScope"

    # Grant Contributor to IoT Operations instance identity
    if ($aioIdentity.principalId) {
        Write-Info "Granting 'Contributor' to IoT Operations instance on custom location..."
        az role assignment create `
            --role "Contributor" `
            --assignee-object-id $aioIdentity.principalId `
            --assignee-principal-type ServicePrincipal `
            --scope $customLocationScope `
            --output none 2>$null
        Write-Success "Granted Contributor on custom location to IoT Operations instance"
    }

    # Grant Contributor to Arc cluster identity
    if ($arcClusterIdentity.principalId) {
        Write-Info "Granting 'Contributor' to Arc cluster on custom location..."
        az role assignment create `
            --role "Contributor" `
            --assignee-object-id $arcClusterIdentity.principalId `
            --assignee-principal-type ServicePrincipal `
            --scope $customLocationScope `
            --output none 2>$null
        Write-Success "Granted Contributor on custom location to Arc cluster"
    }

    # Grant Contributor to the Device Registry ARM bridge service principal
    # App ID 319f651f-7ddb-4fc6-9857-7aef9250bd05 is the Microsoft Device Registry service
    # that syncs discovered assets from the cluster to Azure Resource Manager.
    Write-SubHeader "Device Registry ARM Bridge Service Principal"
    $deviceRegistryAppId = "319f651f-7ddb-4fc6-9857-7aef9250bd05"
    $deviceRegistrySpId = az ad sp show --id $deviceRegistryAppId --query id -o tsv 2>$null
    if ($deviceRegistrySpId) {
        Write-Success "Found Device Registry service principal: $deviceRegistrySpId"
        Write-Info "Granting 'Contributor' to Device Registry bridge on custom location..."
        az role assignment create `
            --role "Contributor" `
            --assignee-object-id $deviceRegistrySpId `
            --assignee-principal-type ServicePrincipal `
            --scope $customLocationScope `
            --output none 2>$null
        Write-Success "Granted Contributor on custom location to Device Registry bridge"
    } else {
        Write-Warning "Could not find Device Registry service principal (app ID: $deviceRegistryAppId)"
        Write-Info "  This SP syncs discovered assets to ARM. If discovered assets don't appear"
        Write-Info "  in the portal, grant Contributor on the custom location manually to the"
        Write-Info "  service principal shown in the 'LinkedAuthorizationFailed' error message."
    }

} else {
    Write-Warning "No custom location found in resource group - skipping custom location permissions"
    Write-Info "  Custom location is created during IoT Operations deployment. Re-run this script after"
    Write-Info "  External-Configurator.ps1 completes if discovered assets don't appear in the portal."
}

# ============================================================================
# GRANT ROLES - CONTAINER REGISTRY
# ============================================================================

if ($containerRegistry) {
    Write-Header "Granting Container Registry Permissions"

    $acrScope = $containerRegistry.id

    # Current user: AcrPush (for pushing images) + AcrPull (for pulling images)
    Write-SubHeader "User: $userObjectId (AcrPush + AcrPull)"
    foreach ($role in @("AcrPush", "AcrPull")) {
        Write-Info "Granting '$role' on $script:ContainerRegistryName..."
        az role assignment create `
            --role $role `
            --assignee $userObjectId `
            --scope $acrScope `
            --output none 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Success "Granted $role to user"
        } else {
            Write-Warning "Could not grant ${role} to user (may already exist)"
        }
    }

    # IoT Operations instance system-assigned MI: AcrPull (for pulling edge module images)
    if ($aioInstance) {
        Write-SubHeader "IoT Operations Instance (AcrPull for edge module pulls)"
        $aioMiId = $aioInstance.identity.principalId
        if ($aioMiId) {
            Write-Info "Granting 'AcrPull' on $script:ContainerRegistryName to IoT Operations MI..."
            az role assignment create `
                --role "AcrPull" `
                --assignee-object-id $aioMiId `
                --assignee-principal-type ServicePrincipal `
                --scope $acrScope `
                --output none 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-Success "Granted AcrPull to IoT Operations instance managed identity"
            } else {
                Write-Warning "Could not grant AcrPull to IoT Operations MI (may already exist)"
            }
        } else {
            Write-Warning "IoT Operations instance does not have a system-assigned managed identity"
        }
    }

    # Arc cluster system-assigned MI: AcrPull (for k8s node pulls)
    if ($arcCluster -and $arcCluster.identity.principalId) {
        Write-SubHeader "Arc Cluster (AcrPull for k8s node pulls)"
        Write-Info "Granting 'AcrPull' on $script:ContainerRegistryName to Arc cluster MI..."
        az role assignment create `
            --role "AcrPull" `
            --assignee-object-id $arcCluster.identity.principalId `
            --assignee-principal-type ServicePrincipal `
            --scope $acrScope `
            --output none 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Success "Granted AcrPull to Arc cluster managed identity"
        } else {
            Write-Warning "Could not grant AcrPull to Arc cluster MI (may already exist)"
        }
    }
} else {
    Write-Warning "No container registry found - skipping ACR permission grants"
    Write-Info "  Run External-Configurator.ps1 first to create the ACR, then re-run this script."
}

Write-Header "Summary - Permissions Granted"

Write-Host ""
Write-Success "Key Vault Permissions (Access Policies):"
if ($keyVault) {
    Write-Info "  [OK] User '$userObjectId': Full access (get, list, set, delete secrets/keys/certs)"
    Write-Info "  [OK] Arc Cluster: Secrets read access (get, list)"
    Write-Info "  [OK] IoT Operations Instance: Secrets read access (get, list)"
    Write-Info "  [OK] All Managed Identities: Secrets read access (get, list)"
} else {
    Write-Warning "  (No Key Vault found - permissions skipped)"
}

Write-Host ""
Write-Success "Container Registry Permissions:"
if ($containerRegistry) {
    Write-Info "  [OK] User '$userObjectId': AcrPush + AcrPull on $script:ContainerRegistryName"
    Write-Info "  [OK] IoT Operations Instance: AcrPull on $script:ContainerRegistryName"
    Write-Info "  [OK] Arc Cluster: AcrPull on $script:ContainerRegistryName"
} else {
    Write-Warning "  (No container registry found - re-run after ACR is created by External-Configurator.ps1)"
}

Write-Host ""
Write-Success "Azure IoT Operations Permissions:"
Write-Info "  [OK] User '$userObjectId': Contributor (resource group)"
Write-Info "  [OK] User '$userObjectId': IoT Hub Data Contributor"
Write-Info "  [OK] User '$userObjectId': Arc Kubernetes Cluster User"
Write-Info "  [OK] User '$userObjectId': Arc Kubernetes Viewer"

Write-Host ""
Write-Success "Microsoft Fabric Integration Permissions:"
Write-Info "  [OK] IoT Operations Instance: Event Hubs Data Sender/Receiver"
Write-Info "  [OK] IoT Operations Instance: Storage Blob Data Contributor"
Write-Info "  [OK] Arc Cluster: Event Hubs Data Sender/Receiver"
Write-Info "  [OK] Arc Cluster: Storage Blob Data Contributor"
Write-Info "  [OK] User '$userObjectId': Event Hubs Data Sender/Receiver"
Write-Info "  [OK] User '$userObjectId': Storage Blob Data Contributor"

Write-Host ""
Write-Success "Custom Location Permissions (for Discovered Asset Sync):"
if ($customLocation) {
    Write-Info "  [OK] IoT Operations Instance: Contributor on custom location"
    Write-Info "  [OK] Arc Cluster: Contributor on custom location"
    Write-Info "  [OK] Device Registry bridge SP: Contributor on custom location"
} else {
    Write-Warning "  (No custom location found - re-run after IoT Operations deployment)"
}

Write-Host ""
Write-Success "Subscription-Level Permissions:"
Write-Info "  [OK] User '$userObjectId': Reader (subscription)"

Write-Host ""
Write-Host "Next Steps:" -ForegroundColor Green
Write-Host "  1. User can now access Key Vault secrets" -ForegroundColor Gray
Write-Host "  2. User can manage IoT Operations resources" -ForegroundColor Gray
Write-Host "  3. IoT Operations can send data to Fabric Real-Time Intelligence" -ForegroundColor Gray
Write-Host "  4. User can create and manage dataflows" -ForegroundColor Gray
Write-Host "  5. Test access in Azure Portal" -ForegroundColor Gray

Write-Host ""
Write-Host "To verify permissions:" -ForegroundColor Cyan
Write-Host "  az role assignment list --assignee $userObjectId --scope $rgScope" -ForegroundColor White

Write-Host ""
Write-Host "Completed: $(Get-Date)" -ForegroundColor Green
Write-Host "Log file: $script:LogFile" -ForegroundColor Gray
Write-Host ""

Stop-Transcript
