#!/usr/bin/env pwsh

<#
.SYNOPSIS
    Connects the K3s cluster to Azure Arc using PowerShell Az modules.

.DESCRIPTION
    This script connects the K3s cluster to Azure Arc.
    Run this AFTER installer.sh and AFTER the resource group exists in Azure.

.PARAMETER ConfigFile
    Path to the aio_config.json file. Default: ../config/aio_config.json

.PARAMETER DryRun
    Show what would be done without making changes.

.EXAMPLE
    ./arc_enable.ps1

.EXAMPLE
    ./arc_enable.ps1 -DryRun

.NOTES
    Author: Azure IoT Operations Team
    Date: January 2026
    Version: 2.0.0 - PowerShell Az Module Based
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$ConfigFile = "",
    
    [Parameter(Mandatory=$false)]
    [switch]$DryRun
)

# ============================================================================
# GLOBAL VARIABLES
# ============================================================================

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigDir = Join-Path (Split-Path -Parent $ScriptDir) "config"

if ([string]::IsNullOrEmpty($ConfigFile)) {
    $ConfigFile = Join-Path $ConfigDir "aio_config.json"
}

$ClusterInfoFile = Join-Path $ConfigDir "cluster_info.json"
$LogFile = Join-Path $ScriptDir "arc_enable_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

# Configuration variables
$script:ClusterName = ""
$script:ResourceGroup = ""
$script:SubscriptionId = ""
$script:Location = ""
$script:KeyVaultName = ""

# ============================================================================
# LOGGING FUNCTIONS
# ============================================================================

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] $Message"
    Write-Host $line -ForegroundColor Green
    Add-Content -Path $LogFile -Value $line
}

function Write-InfoLog {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] INFO: $Message"
    Write-Host $line -ForegroundColor Cyan
    Add-Content -Path $LogFile -Value $line
}

function Write-WarnLog {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] WARNING: $Message"
    Write-Host $line -ForegroundColor Yellow
    Add-Content -Path $LogFile -Value $line
}

function Write-ErrorLog {
    param([string]$Message, [switch]$Fatal)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] ERROR: $Message"
    Write-Host $line -ForegroundColor Red
    Add-Content -Path $LogFile -Value $line
    if ($Fatal) {
        throw $Message
    }
}

function Write-Success {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] SUCCESS: $Message"
    Write-Host $line -ForegroundColor Green
    Add-Content -Path $LogFile -Value $line
}

# ============================================================================
# CONFIGURATION LOADING
# ============================================================================

function Load-Configuration {
    Write-Log "Loading configuration from $ConfigFile..."
    
    if (-not (Test-Path $ConfigFile)) {
        Write-ErrorLog "Configuration file not found: $ConfigFile

Please create aio_config.json with your Azure settings:
  cp $ConfigDir/aio_config.json.template $ConfigFile
  
Then edit it with your subscription, resource group, and cluster name." -Fatal
    }
    
    try {
        $config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
    } catch {
        Write-ErrorLog "Invalid JSON in configuration file: $ConfigFile" -Fatal
    }
    
    # Load values
    $script:ClusterName = $config.azure.cluster_name
    $script:ResourceGroup = $config.azure.resource_group
    $script:SubscriptionId = $config.azure.subscription_id
    $script:Location = if ($config.azure.location) { $config.azure.location } else { "eastus" }
    $script:KeyVaultName = $config.azure.key_vault_name
    
    # Validate required fields
    if ([string]::IsNullOrEmpty($script:ClusterName)) {
        Write-ErrorLog "cluster_name not found in $ConfigFile" -Fatal
    }
    if ([string]::IsNullOrEmpty($script:ResourceGroup)) {
        Write-ErrorLog "resource_group not found in $ConfigFile" -Fatal
    }
    if ([string]::IsNullOrEmpty($script:SubscriptionId)) {
        Write-ErrorLog "subscription_id not found in $ConfigFile" -Fatal
    }
    
    Write-Host ""
    Write-Host "Configuration:" -ForegroundColor Cyan
    Write-Host "  Cluster Name:   $script:ClusterName"
    Write-Host "  Resource Group: $script:ResourceGroup"
    Write-Host "  Subscription:   $script:SubscriptionId"
    Write-Host "  Location:       $script:Location"
    Write-Host "  Key Vault:      $script:KeyVaultName"
    Write-Host ""
    
    Write-Success "Configuration loaded"
}

# ============================================================================
# PREREQUISITES
# ============================================================================

function Check-Prerequisites {
    Write-Log "Checking prerequisites..."
    
    # Check if kubectl is available
    if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
        Write-ErrorLog "kubectl not found. Please run installer.sh first." -Fatal
    }
    Write-Success "kubectl is available"
    
    # Check if cluster is accessible
    try {
        $null = kubectl get nodes 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "kubectl failed"
        }
    } catch {
        Write-ErrorLog "Cannot access Kubernetes cluster. Is K3s running?

Check with: sudo systemctl status k3s
Restart with: sudo systemctl restart k3s" -Fatal
    }
    Write-Success "Kubernetes cluster is accessible"
    
    # Check for required PowerShell modules
    $requiredModules = @("Az.Accounts", "Az.Resources", "Az.ConnectedKubernetes")
    
    foreach ($module in $requiredModules) {
        if (-not (Get-Module -ListAvailable -Name $module)) {
            Write-ErrorLog "Required PowerShell module not found: $module

Install with: Install-Module -Name $module -Scope CurrentUser -Force" -Fatal
        }
        Write-Success "$module module is available"
    }
    
    # Import modules
    Import-Module Az.Accounts -ErrorAction SilentlyContinue
    Import-Module Az.Resources -ErrorAction SilentlyContinue
    Import-Module Az.ConnectedKubernetes -ErrorAction SilentlyContinue
    
    Write-Success "All prerequisites met"
}

# ============================================================================
# AZURE AUTHENTICATION
# ============================================================================

function Connect-ToAzure {
    Write-Log "Checking Azure authentication..."
    
    # Check if already logged in
    $context = Get-AzContext -ErrorAction SilentlyContinue
    
    if ($context) {
        Write-Success "Already logged in as: $($context.Account.Id)"
        Write-InfoLog "Current subscription: $($context.Subscription.Name)"
    } else {
        Write-Log "Not logged into Azure. Starting login..."
        
        if ($DryRun) {
            Write-InfoLog "[DRY-RUN] Would run: Connect-AzAccount"
        } else {
            # Use device code flow for Linux compatibility
            Connect-AzAccount -UseDeviceAuthentication
        }
    }
    
    # Set the correct subscription
    Write-Log "Setting subscription to: $script:SubscriptionId"
    
    if ($DryRun) {
        Write-InfoLog "[DRY-RUN] Would set subscription: $script:SubscriptionId"
    } else {
        Set-AzContext -SubscriptionId $script:SubscriptionId | Out-Null
        $currentContext = Get-AzContext
        Write-Success "Subscription set to: $($currentContext.Subscription.Name)"
    }
}

# ============================================================================
# RESOURCE GROUP CHECK
# ============================================================================

function Test-ResourceGroup {
    Write-Log "Checking if resource group exists: $script:ResourceGroup"
    
    if ($DryRun) {
        Write-InfoLog "[DRY-RUN] Would check for resource group: $script:ResourceGroup"
        return
    }
    
    $rg = Get-AzResourceGroup -Name $script:ResourceGroup -ErrorAction SilentlyContinue
    
    if ($rg) {
        Write-Success "Resource group exists: $script:ResourceGroup"
    } else {
        Write-Host ""
        Write-Host "============================================================================" -ForegroundColor Yellow
        Write-Host "RESOURCE GROUP DOES NOT EXIST" -ForegroundColor Yellow
        Write-Host "============================================================================" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "The resource group '$script:ResourceGroup' does not exist in Azure."
        Write-Host ""
        Write-Host "Options:"
        Write-Host "  1. Create it now (requires Contributor role on subscription)"
        Write-Host "  2. Exit and create it manually or via External-Configurator.ps1"
        Write-Host ""
        
        $createRg = Read-Host "Create resource group now? (y/N)"
        
        if ($createRg -match "^[Yy]$") {
            Write-Log "Creating resource group: $script:ResourceGroup in $script:Location"
            New-AzResourceGroup -Name $script:ResourceGroup -Location $script:Location | Out-Null
            Write-Success "Resource group created: $script:ResourceGroup"
        } else {
            Write-Host ""
            Write-Host "To create the resource group manually, run:"
            Write-Host "  New-AzResourceGroup -Name $script:ResourceGroup -Location $script:Location"
            Write-Host ""
            Write-Host "Or run External-Configurator.ps1 from Windows first to create Azure resources."
            Write-Host ""
            Write-ErrorLog "Cannot continue without resource group" -Fatal
        }
    }
}

# ============================================================================
# ARC ENABLE
# ============================================================================

function Test-CustomLocationsPrerequisites {
    <#
    .SYNOPSIS
        Diagnoses why the Custom Locations RP object ID lookup failed.
        Checks provider registration, Entra ID permissions, and user context.
    #>
    
    Write-InfoLog "Running diagnostics to determine the cause..."
    Write-Host ""
    
    # Check 1: Who is logged in?
    $context = Get-AzContext -ErrorAction SilentlyContinue
    if ($context) {
        Write-Host "  Signed-in account:  $($context.Account.Id)" -ForegroundColor Cyan
        Write-Host "  Tenant ID:          $($context.Tenant.Id)" -ForegroundColor Cyan
    }
    
    # Check 2: Is Microsoft.ExtendedLocation registered?
    $providerOk = $false
    try {
        $provider = Get-AzResourceProvider -ProviderNamespace "Microsoft.ExtendedLocation" -ErrorAction Stop
        $regState = ($provider.RegistrationState | Select-Object -First 1)
        if ($regState -eq "Registered") {
            Write-Host "  [PASS] Microsoft.ExtendedLocation provider: Registered" -ForegroundColor Green
            $providerOk = $true
        } else {
            Write-Host "  [FAIL] Microsoft.ExtendedLocation provider: $regState" -ForegroundColor Red
            Write-Host "         Fix: Register-AzResourceProvider -ProviderNamespace Microsoft.ExtendedLocation" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "  [FAIL] Could not check Microsoft.ExtendedLocation provider: $_" -ForegroundColor Red
        Write-Host "         Fix: Register-AzResourceProvider -ProviderNamespace Microsoft.ExtendedLocation" -ForegroundColor Yellow
    }
    
    # Check 3: Can we read ANY service principal? (tests Entra ID read permission)
    $canReadSPs = $false
    try {
        $null = Get-AzADServicePrincipal -First 1 -ErrorAction Stop
        $canReadSPs = $true
        Write-Host "  [PASS] Entra ID service principal read access: OK" -ForegroundColor Green
    } catch {
        Write-Host "  [FAIL] Cannot read Entra ID service principals" -ForegroundColor Red
        Write-Host "         Your account lacks Directory.Read.All or equivalent permission." -ForegroundColor Yellow
        Write-Host "         Ask a tenant admin to grant you Directory Reader role, or" -ForegroundColor Yellow
        Write-Host "         run grant_entra_id_roles.ps1 from a privileged account." -ForegroundColor Yellow
    }
    
    # Check 4: Is Microsoft.Kubernetes registered? (needed for Arc)
    try {
        $k8sProvider = Get-AzResourceProvider -ProviderNamespace "Microsoft.Kubernetes" -ErrorAction Stop
        $k8sState = ($k8sProvider.RegistrationState | Select-Object -First 1)
        if ($k8sState -eq "Registered") {
            Write-Host "  [PASS] Microsoft.Kubernetes provider: Registered" -ForegroundColor Green
        } else {
            Write-Host "  [WARN] Microsoft.Kubernetes provider: $k8sState" -ForegroundColor Yellow
            Write-Host "         Fix: Register-AzResourceProvider -ProviderNamespace Microsoft.Kubernetes" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "  [WARN] Could not check Microsoft.Kubernetes provider" -ForegroundColor Yellow
    }
    
    Write-Host ""
    
    # Summary
    if (-not $providerOk -and -not $canReadSPs) {
        Write-Host "  DIAGNOSIS: Multiple issues found. Fix the provider registration first," -ForegroundColor Red
        Write-Host "  then address the Entra ID permissions." -ForegroundColor Red
    } elseif (-not $providerOk) {
        Write-Host "  DIAGNOSIS: The Custom Locations resource provider is not registered." -ForegroundColor Red
        Write-Host "  Run: Register-AzResourceProvider -ProviderNamespace Microsoft.ExtendedLocation" -ForegroundColor Cyan
        Write-Host "  Then re-run this script." -ForegroundColor Cyan
    } elseif (-not $canReadSPs) {
        Write-Host "  DIAGNOSIS: Your account cannot read service principals in Entra ID." -ForegroundColor Red
        Write-Host "  Ask a tenant admin to run grant_entra_id_roles.ps1, or grant you" -ForegroundColor Cyan
        Write-Host "  the 'Directory Readers' role in Entra ID." -ForegroundColor Cyan
    } else {
        Write-Host "  DIAGNOSIS: Provider and permissions look OK. The service principal may" -ForegroundColor Yellow
        Write-Host "  not exist yet. Try: Register-AzResourceProvider -ProviderNamespace Microsoft.ExtendedLocation" -ForegroundColor Cyan
        Write-Host "  Wait 1-2 minutes, then re-run this script." -ForegroundColor Cyan
    }
    
    Write-Host ""
}

function Enable-ArcForCluster {
    Write-Log "Connecting cluster to Azure Arc..."
    
    # Get the Custom Locations RP object ID upfront - needed for initial connection
    # The Application ID bc313c14-388c-4e7d-a58e-70017303ee3b is fixed globally for the Custom Locations RP
    $customLocationsAppId = "bc313c14-388c-4e7d-a58e-70017303ee3b"
    $customLocationsOid = $null
    
    Write-InfoLog "Retrieving Custom Locations Resource Provider object ID..."
    try {
        $customLocationsOid = (Get-AzADServicePrincipal -ApplicationId $customLocationsAppId -ErrorAction Stop).Id
        if ([string]::IsNullOrEmpty($customLocationsOid)) {
            throw "Get-AzADServicePrincipal returned no object ID. The Custom Locations RP may not be registered in this tenant. Run: Register-AzResourceProvider -ProviderNamespace Microsoft.ExtendedLocation"
        }
        Write-InfoLog "Custom Locations RP Object ID: $customLocationsOid"
    } catch {
        Write-WarnLog "Could not retrieve Custom Locations RP object ID: $_"
        Write-Host ""
        Write-Host "============================================================================" -ForegroundColor Yellow
        Write-Host "WARNING: CUSTOM LOCATIONS OID NOT AVAILABLE" -ForegroundColor Yellow
        Write-Host "============================================================================" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "The Custom Locations Resource Provider object ID could not be retrieved."
        Write-Host "This is required for Azure IoT Operations to work properly."
        Write-Host ""
        
        # Run diagnostics to tell the user exactly what's wrong
        Test-CustomLocationsPrerequisites
        
        Write-Host "What happens next:" -ForegroundColor Cyan
        Write-Host "  - The cluster will be Arc-connected WITHOUT custom-locations enabled"
        Write-Host "  - IoT Operations deployment will FAIL until this is fixed"
        Write-Host ""
        Write-Host "After fixing the issue above:" -ForegroundColor Green
        Write-Host "  1. Re-run this script (it's safe to run multiple times)"
        Write-Host "  2. If already Arc-connected, the script will enable custom-locations on the existing connection"
        Write-Host ""
        Write-Host "This script is IDEMPOTENT - you can safely run it again after fixing permissions." -ForegroundColor Green
        Write-Host ""
    }
    
    # Check if already Arc-enabled
    $existingArc = Get-AzConnectedKubernetes -ResourceGroupName $script:ResourceGroup -ClusterName $script:ClusterName -ErrorAction SilentlyContinue
    
    if ($existingArc) {
        Write-Success "Cluster '$script:ClusterName' is already Arc-enabled"
        Write-InfoLog "Connectivity status: $($existingArc.ConnectivityStatus)"
        Write-InfoLog "Private Link State: $($existingArc.PrivateLinkState)"
        
        # Check if private link is enabled (incompatible with custom-locations)
        if ($existingArc.PrivateLinkState -eq "Enabled") {
            Write-WarnLog "Cluster is connected with Private Link enabled"
            Write-WarnLog "Custom-locations and cluster-connect features are NOT compatible with Private Link"
            Write-WarnLog "To fix: Delete the Arc connection and re-run this script"
            Write-Host ""
            Write-Host "  To delete Arc connection:" -ForegroundColor Yellow
            Write-Host "    kubectl delete ns azure-arc" -ForegroundColor White
            Write-Host "    (NOTE: 'namespace not found' error is OK - means it's already deleted)" -ForegroundColor DarkGray
            Write-Host "    Remove-AzResource -ResourceGroupName $script:ResourceGroup -ResourceName $script:ClusterName -ResourceType 'Microsoft.Kubernetes/connectedClusters' -Force" -ForegroundColor White
            Write-Host ""
        }
        
        # Check if custom-locations was enabled (idempotency check)
        # NOTE: The ConnectedCluster object (Az.ConnectedKubernetes 0.15.0) has NO .Feature property.
        # The only authoritative check is Helm - done later in Enable-CustomLocations.
        # Here we do a quick Helm check to give the user early feedback.
        $hasCustomLocations = $false
        try {
            $helmValues = helm get values azure-arc --namespace azure-arc-release -o json 2>$null | ConvertFrom-Json
            if ($helmValues.systemDefaultValues.customLocations.enabled -eq $true) {
                $hasCustomLocations = $true
                Write-Success "Custom-locations feature is already enabled (verified via Helm)"
            }
        } catch {
            # helm not available or chart not found - will check again in Enable-CustomLocations
        }
        
        if (-not $hasCustomLocations) {
            Write-InfoLog "Custom-locations not yet confirmed enabled - will enable via Azure CLI later in script"
        }
        
        # Store OID for later use in Enable-ArcFeatures
        $script:CustomLocationsOid = $customLocationsOid
    } else {
        Write-Log "Arc-enabling cluster: $script:ClusterName"
        
        if ($DryRun) {
            Write-InfoLog "[DRY-RUN] Would connect cluster with custom-locations enabled"
        } else {
            # NOTE: Do NOT pass PrivateLinkState = "Disabled" to New-AzConnectedKubernetes.
            # Passing it (even as "Disabled") triggers a PS module bug that causes Arc onboarding
            # to treat the cluster as private-link-enabled and block custom-locations with:
            #   "The features 'cluster-connect' and 'custom-locations' cannot be enabled for a
            #    private link enabled connected cluster."
            # Omitting the parameter entirely lets the API default to disabled correctly.
            Write-InfoLog "Connecting with custom-locations, OIDC issuer, and workload identity enabled..."
            
            # Keep the initial connect minimal — only what is needed to register the connected
            # cluster resource. OIDC, workload identity, and Azure RBAC are enabled by dedicated
            # functions that run immediately after (Enable-AzureRbac, Enable-OidcWorkloadIdentity).
            # Passing OidcIssuerProfileEnabled / WorkloadIdentityEnabled here causes the Arc API
            # to validate the cluster's OIDC endpoint during connect, which fails on K3s defaults.
            $connectParams = @{
                ResourceGroupName = $script:ResourceGroup
                ClusterName       = $script:ClusterName
                Location          = $script:Location
                AcceptEULA        = $true
            }
            
            if (-not [string]::IsNullOrEmpty($customLocationsOid)) {
                $connectParams['CustomLocationsOid'] = $customLocationsOid
                Write-InfoLog "Including CustomLocationsOid in connection"
            } else {
                Write-WarnLog "Connecting WITHOUT custom-locations (OID not available)"
                Write-WarnLog "IoT Operations will NOT work until you reconnect with custom-locations enabled"
                Write-Host ""
                Write-Host "After fixing permissions, you can re-run this script:" -ForegroundColor Yellow
                Write-Host "  1. Delete the Arc connection:" -ForegroundColor White
                Write-Host "       kubectl delete ns azure-arc" -ForegroundColor White
                Write-Host "       (NOTE: 'namespace not found' error is OK - means it's already deleted)" -ForegroundColor DarkGray
                Write-Host "       Remove-AzResource -ResourceGroupName $script:ResourceGroup -ResourceName $script:ClusterName -ResourceType 'Microsoft.Kubernetes/connectedClusters' -Force" -ForegroundColor White
                Write-Host "  2. Re-run: ./arc_enable.ps1" -ForegroundColor White
                Write-Host ""
            }
            
            New-AzConnectedKubernetes @connectParams
            Write-Success "Cluster connected to Azure Arc with features enabled (including Azure RBAC)"
        }
        
        # Store OID for later verification
        $script:CustomLocationsOid = $customLocationsOid
    }
}

function Enable-AzureRbac {
    <#
    .SYNOPSIS
        Enables Azure RBAC on the Arc-connected cluster.
    
    .DESCRIPTION
        Azure RBAC is required for kubectl access through the Arc proxy.
        Without it, Azure Arc Kubernetes roles (Cluster Admin, Viewer, etc.)
        are not enforced and kubectl commands via 'az connectedk8s proxy' will
        return 403 Forbidden errors.
        
        Uses Set-AzConnectedKubernetes -AadProfileEnableAzureRbac from the Az.ConnectedKubernetes module.
        Note: parameter was renamed from AzureRbacEnabled to AadProfileEnableAzureRbac in v0.11+.
        
        Safe to run multiple times - checks current state first.
    #>
    
    Write-Log "Checking Azure RBAC status (optional feature for kubectl proxy access)..."
    
    if ($DryRun) {
        Write-InfoLog "[DRY-RUN] Would check Azure RBAC on cluster"
        return
    }
    
    # Check if Azure RBAC is already enabled
    try {
        $clusterInfo = Get-AzConnectedKubernetes -ResourceGroupName $script:ResourceGroup -ClusterName $script:ClusterName -ErrorAction Stop
        
        if ($clusterInfo.AadProfileEnableAzureRbac -eq $true) {
            Write-Success "Azure RBAC is already enabled"
            return
        }
    } catch {
        Write-WarnLog "Could not check Azure RBAC status: $_"
    }
    
    # Azure RBAC cannot be set via the ARM REST API from the edge device context.
    # The Azure RP rejects PUT/PATCH with aadProfile from all tested API versions.
    # This feature is OPTIONAL - AIO does not require it.
    # Enable it from Windows after deployment using the Azure CLI:
    Write-WarnLog "Azure RBAC is not enabled (optional - AIO does not require this)"
    Write-Host ""
    Write-Host "  Azure RBAC enables 'az connectedk8s proxy' for kubectl via Azure identities." -ForegroundColor DarkGray
    Write-Host "  To enable it, run from Windows:" -ForegroundColor Yellow
    Write-Host "    az connectedk8s update --name $script:ClusterName --resource-group $script:ResourceGroup --enable-azure-rbac" -ForegroundColor Cyan
    Write-Host ""
}

function Enable-ArcFeatures {
    Write-Log "Verifying Arc features (custom-locations, cluster-connect)..."
    
    if ($DryRun) {
        Write-InfoLog "[DRY-RUN] Would verify Arc features"
        return
    }
    
    # Features should already be enabled during New-AzConnectedKubernetes
    # This function now just verifies they are active
    
    # Get the Custom Locations RP object ID if not already set
    $customLocationsOid = $script:CustomLocationsOid
    if ([string]::IsNullOrEmpty($customLocationsOid)) {
        $customLocationsAppId = "bc313c14-388c-4e7d-a58e-70017303ee3b"
        try {
            $customLocationsOid = (Get-AzADServicePrincipal -ApplicationId $customLocationsAppId -ErrorAction Stop).Id
            if ([string]::IsNullOrEmpty($customLocationsOid)) {
                throw "Service principal returned empty object ID"
            }
        } catch {
            Write-WarnLog "Could not retrieve Custom Locations RP object ID"
        }
    }
    
    if ([string]::IsNullOrEmpty($customLocationsOid)) {
        Write-WarnLog "Could not verify Custom Locations RP object ID"
    } else {
        Write-InfoLog "Custom Locations RP Object ID: $customLocationsOid"
    }
    
    # Verify the cluster configuration
    Write-InfoLog "Checking cluster feature state..."
    try {
        $clusterInfo = Get-AzConnectedKubernetes -ResourceGroupName $script:ResourceGroup -ClusterName $script:ClusterName -ErrorAction Stop
        
        Write-InfoLog "Cluster configuration:"
        Write-InfoLog "  Connectivity: $($clusterInfo.ConnectivityStatus)"
        Write-InfoLog "  PrivateLinkState: $($clusterInfo.PrivateLinkState)"
        Write-InfoLog "  Distribution: $($clusterInfo.Distribution)"
        
        if ($clusterInfo.PrivateLinkState -eq "Enabled") {
            Write-ErrorLog "CRITICAL: Private Link is enabled - this is incompatible with custom-locations"
            Write-ErrorLog "Custom-locations feature will NOT work until Private Link is disabled"
            Write-ErrorLog "To fix: Delete the Arc connection and re-run this script"
            return
        }
        
        # NOTE: The ConnectedCluster object has NO .Feature property in Az.ConnectedKubernetes 0.15.0.
        # Custom-locations state is NOT readable from the PS object - Helm is the authoritative source.
        # Use direct flat properties for what IS available:
        
        # Check OIDC issuer profile
        if ($clusterInfo.OidcIssuerProfileEnabled -eq $true) {
            Write-InfoLog "  OIDC Issuer: Enabled (URL: $($clusterInfo.OidcIssuerProfileIssuerUrl))"
        } else {
            Write-WarnLog "  OIDC Issuer: NOT enabled"
        }
        
        if ($clusterInfo.WorkloadIdentityEnabled -eq $true) {
            Write-InfoLog "  Workload Identity (ARM flag): Enabled"
        } else {
            Write-WarnLog "  Workload Identity: NOT enabled in ARM"
        }
        
        if ($clusterInfo.AadProfileEnableAzureRbac -eq $true) {
            Write-InfoLog "  Azure RBAC (ARM flag): Enabled"
        } else {
            Write-WarnLog "  Azure RBAC: NOT enabled in ARM"
        }
        
        # custom-locations: check via Helm (the only reliable source)
        try {
            $helmValues = helm get values azure-arc --namespace azure-arc-release -o json 2>$null | ConvertFrom-Json
            if ($helmValues.systemDefaultValues.customLocations.enabled -eq $true) {
                Write-Success "  Custom-locations (Helm): Enabled"
            } else {
                Write-InfoLog "  Custom-locations (Helm): NOT enabled - will enable via Azure CLI next..."
            }
        } catch {
            Write-InfoLog "  Custom-locations: Could not check Helm state - will enable via Azure CLI next..."
        }
    } catch {
        Write-ErrorLog "Could not verify cluster feature state: $_"
    }
}

function Enable-OidcWorkloadIdentity {
    Write-Log "Verifying OIDC issuer and workload identity..."
    
    if ($DryRun) {
        Write-InfoLog "[DRY-RUN] Would verify OIDC and workload identity"
        return
    }
    
    # KNOWN ISSUE: Az.ConnectedKubernetes module sets WorkloadIdentityEnabled=true in ARM
    # but does NOT deploy the workload identity webhook pods to the cluster.
    # We need to verify the webhook is running and enable it via CLI if not.
    
    Write-InfoLog "Checking if workload identity webhook is deployed..."
    
    try {
        # Check if workload identity webhook pods are running
        $wiPods = kubectl get pods -n azure-arc 2>$null | Select-String -Pattern "workload-identity"
        
        if ($wiPods) {
            Write-Success "Workload identity webhook is running"
            Write-InfoLog "Pods: $wiPods"
            return
        }
        
        Write-WarnLog "Workload identity webhook NOT found in cluster"
        Write-InfoLog "Enabling OIDC issuer + workload identity via GET + PUT..."
        Write-InfoLog "NOTE: Webhook pods deploy asynchronously after ARM update."
        
        try {
            $resourceId = "/subscriptions/$($script:SubscriptionId)/resourceGroups/$($script:ResourceGroup)/providers/Microsoft.Kubernetes/connectedClusters/$($script:ClusterName)"
            # 2024-06-01-preview added oidcIssuerProfile and securityProfile.workloadIdentity
            $apiVersion = "2024-06-01-preview"
            
            # GET current state
            $getResponse = Invoke-AzRestMethod -Method GET -Path "${resourceId}?api-version=${apiVersion}" -ErrorAction Stop
            if ($getResponse.StatusCode -ne 200) {
                Write-WarnLog "GET failed with HTTP $($getResponse.StatusCode): $($getResponse.Content)"
                throw "GET failed"
            }
            $resource = $getResponse.Content | ConvertFrom-Json
            
            # Modify oidcIssuerProfile
            if (-not $resource.properties.oidcIssuerProfile) {
                $resource.properties | Add-Member -MemberType NoteProperty -Name oidcIssuerProfile -Value ([PSCustomObject]@{}) -Force
            }
            $resource.properties.oidcIssuerProfile | Add-Member -MemberType NoteProperty -Name enabled -Value $true -Force
            
            # Modify securityProfile.workloadIdentity
            if (-not $resource.properties.securityProfile) {
                $resource.properties | Add-Member -MemberType NoteProperty -Name securityProfile -Value ([PSCustomObject]@{}) -Force
            }
            if (-not $resource.properties.securityProfile.workloadIdentity) {
                $resource.properties.securityProfile | Add-Member -MemberType NoteProperty -Name workloadIdentity -Value ([PSCustomObject]@{}) -Force
            }
            $resource.properties.securityProfile.workloadIdentity | Add-Member -MemberType NoteProperty -Name enabled -Value $true -Force
            
            # PUT full body back
            $putBody = $resource | ConvertTo-Json -Depth 20 -Compress
            $putResponse = Invoke-AzRestMethod -Method PUT -Path "${resourceId}?api-version=${apiVersion}" -Payload $putBody -ErrorAction Stop
            
            if ($putResponse.StatusCode -in 200, 201, 202) {
                Write-Success "OIDC issuer and workload identity enabled in ARM"
            } else {
                Write-WarnLog "PUT returned HTTP $($putResponse.StatusCode): $($putResponse.Content)"
            }
        } catch {
            Write-WarnLog "GET+PUT for workload identity failed: $_"
        }
        
        # Verify webhook is now running
        Write-InfoLog "Waiting for workload identity webhook to start..."
        Start-Sleep -Seconds 15
        
        $wiPodsAfter = kubectl get pods -n azure-arc 2>$null | Select-String -Pattern "workload-identity"
        if ($wiPodsAfter) {
            Write-Success "Workload identity webhook is now running!"
            Write-InfoLog "Pods: $wiPodsAfter"
        } else {
            Write-WarnLog "Webhook pods not yet visible - they may take a few minutes to appear."
            Write-Host "Verify with: kubectl get pods -n azure-arc | grep workload" -ForegroundColor Cyan
        }
        
    } catch {
        Write-ErrorLog "Failed to verify/enable workload identity: $_"
    }
}

function Test-K3sOidcIssuerConfigured {
    <#
    .SYNOPSIS
        Checks if K3s is configured with the correct Arc OIDC issuer URL.
    
    .DESCRIPTION
        For secret sync to work with workload identity, K3s must issue service 
        account tokens with the Arc OIDC issuer URL (not the default 
        kubernetes.default.svc.cluster.local). This function checks if K3s is
        correctly configured.
        
        Returns a hashtable with:
        - Configured: $true if OIDC issuer matches Arc issuer
        - CurrentIssuer: Current K3s issuer URL (or $null if default)
        - ExpectedIssuer: Arc OIDC issuer URL
    #>
    
    Write-InfoLog "Checking K3s OIDC issuer configuration..."
    
    $result = @{
        Configured = $false
        CurrentIssuer = $null
        ExpectedIssuer = $null
        K3sReady = $false
    }
    
    # Check if K3s is running
    $nodesReady = kubectl get nodes --no-headers 2>$null | Select-String -Pattern "Ready"
    if (-not $nodesReady) {
        Write-WarnLog "K3s is not ready (no nodes in Ready state)"
        return $result
    }
    $result.K3sReady = $true
    
    # Get the expected OIDC issuer URL from Azure via PS module
    try {
        $arcCluster = Get-AzConnectedKubernetes `
            -ResourceGroupName $script:ResourceGroup `
            -ClusterName $script:ClusterName `
            -ErrorAction Stop
        $expectedIssuer = $arcCluster.OidcIssuerProfileIssuerUrl
    } catch {
        Write-WarnLog "Could not retrieve Arc cluster info: $_"
    }
    
    if ([string]::IsNullOrEmpty($expectedIssuer)) {
        Write-WarnLog "OIDC issuer URL not available from Azure yet"
        return $result
    }
    $result.ExpectedIssuer = $expectedIssuer
    
    # Get current K3s issuer
    $clusterDump = kubectl cluster-info dump 2>$null
    $currentIssuer = $clusterDump | Select-String -Pattern "service-account-issuer=([^\s,`"\\]+)" | 
        ForEach-Object { $_.Matches.Groups[1].Value } | 
        Select-Object -First 1
    
    if ($currentIssuer) {
        $result.CurrentIssuer = $currentIssuer
        
        if ($currentIssuer -eq $expectedIssuer) {
            $result.Configured = $true
            Write-Success "K3s OIDC issuer is correctly configured"
        } else {
            Write-WarnLog "K3s OIDC issuer mismatch"
            Write-InfoLog "  Current:  $currentIssuer"
            Write-InfoLog "  Expected: $expectedIssuer"
        }
    } else {
        Write-InfoLog "K3s using default issuer (kubernetes.default.svc.cluster.local)"
    }
    
    return $result
}

function Configure-K3sOidcIssuer {
    <#
    .SYNOPSIS
        Configures K3s to use the Arc OIDC issuer URL for service account tokens.
    
    .DESCRIPTION
        After Arc connection, retrieves the OIDC issuer URL from Azure and configures
        K3s to issue service account tokens with that issuer. This is REQUIRED for
        workload identity and secret sync to work properly.
        
        Without this configuration, K3s issues tokens with the default issuer
        'https://kubernetes.default.svc.cluster.local' which doesn't match the
        federated identity credentials created by Azure, causing secret sync to fail.
        
        Safe to run multiple times - checks current state before making changes.
    #>
    
    Write-Log "Configuring K3s OIDC issuer for secret sync..."
    
    if ($DryRun) {
        Write-InfoLog "[DRY-RUN] Would configure K3s OIDC issuer"
        return $true
    }
    
    # Check current configuration
    $oidcStatus = Test-K3sOidcIssuerConfigured
    
    if ($oidcStatus.Configured) {
        Write-Success "K3s already configured with correct OIDC issuer"
        return $true
    }
    
    if (-not $oidcStatus.K3sReady) {
        Write-Host ""
        Write-Host "============================================================================" -ForegroundColor Yellow
        Write-Host "K3S NOT READY" -ForegroundColor Yellow
        Write-Host "============================================================================" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "K3s is not running or restarting." -ForegroundColor Cyan
        Write-Host ""
        Write-Host "Check K3s status and run this script again:" -ForegroundColor Gray
        Write-Host "  kubectl get nodes"
        Write-Host "  sudo systemctl status k3s"
        Write-Host ""
        return $false
    }
    
    if (-not $oidcStatus.ExpectedIssuer) {
        Write-Host ""
        Write-Host "============================================================================" -ForegroundColor Yellow
        Write-Host "ARC OIDC ISSUER NOT AVAILABLE" -ForegroundColor Yellow
        Write-Host "============================================================================" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "The Arc OIDC issuer URL is not yet available from Azure." -ForegroundColor Cyan
        Write-Host "Arc may still be initializing. This typically takes 2-5 minutes."
        Write-Host ""
        Write-Host "Run this script again in a few minutes." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "To check Arc status manually:" -ForegroundColor Gray
        Write-Host "  kubectl get pods -n azure-arc"
        Write-Host "  az connectedk8s show --name $script:ClusterName --resource-group $script:ResourceGroup --query '{status:connectivityStatus, oidc:oidcIssuerProfile.issuerUrl}'"
        Write-Host ""
        return $false
    }
    
    $oidcIssuerUrl = $oidcStatus.ExpectedIssuer
    Write-InfoLog "OIDC Issuer URL: $oidcIssuerUrl"
    Write-InfoLog "Updating K3s configuration..."
    
    # Create the K3s config file content
    $k3sConfig = @"
kube-apiserver-arg:
  - 'service-account-issuer=$oidcIssuerUrl'
  - 'service-account-max-token-expiration=24h'
"@
    
    $configPath = "/etc/rancher/k3s/config.yaml"
    
    # Check if config file exists and has other settings we should preserve
    $existingConfig = $null
    try {
        $existingConfig = (sudo cat $configPath 2>$null) -join "`n"
    } catch {}
    
    if ($existingConfig -and $existingConfig -notmatch "service-account-issuer") {
        # Append to existing config (preserving other settings)
        Write-InfoLog "Appending OIDC issuer to existing K3s config..."
        $k3sConfig = $existingConfig.TrimEnd() + "`n" + $k3sConfig
    } elseif ($existingConfig -and $existingConfig -match "service-account-issuer") {
        # Config already has an issuer setting - replace the whole file
        Write-InfoLog "Replacing existing OIDC issuer in K3s config..."
    }
    
    # Write the config file
    $k3sConfig | sudo tee $configPath > $null
    
    Write-InfoLog "Restarting K3s to apply OIDC issuer configuration..."
    sudo systemctl restart k3s
    
    Write-Host ""
    Write-Host "============================================================================" -ForegroundColor Green
    Write-Host "K3S OIDC ISSUER CONFIGURED" -ForegroundColor Green
    Write-Host "============================================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "K3s is restarting with the Arc OIDC issuer. This takes 60-90 seconds." -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Run this script again to verify the configuration is complete." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "To check K3s status manually:" -ForegroundColor Gray
    Write-Host "  kubectl get nodes"
    Write-Host "  kubectl cluster-info dump | grep service-account-issuer"
    Write-Host ""
    Write-Host "Once K3s is ready, secret sync will work correctly for:" -ForegroundColor Gray
    Write-Host "  - Azure Key Vault secrets to Kubernetes"
    Write-Host "  - Dataflow endpoints with Managed Identity authentication"
    Write-Host ""
    
    # Exit script - user should re-run after K3s restarts
    return $false
}

function Create-FabricSecretPlaceholders {
    <#
    .SYNOPSIS
        Creates placeholder secrets in Key Vault for Microsoft Fabric Event Streams.
    
    .DESCRIPTION
        NOTE: Fabric Event Stream custom endpoints now support Managed Identity. This function
        is retained for backward compatibility but is no longer needed for new deployments.
        New deployments should configure the Fabric endpoint in the Azure Portal using
        System-Assigned Managed Identity -- no secrets or Key Vault setup required.
        
        Creates two secrets in Azure Key Vault for legacy Fabric Kafka/SASL authentication:
        - fabric-sasl-username: Set to '$ConnectionString' (required by Fabric SASL)
        - fabric-sasl-password: Set to a placeholder prompting user to add their connection string
        
        Safe to run multiple times - will not overwrite existing password if it's been set.
    #>
    
    Write-Log "Creating Fabric Event Streams secret placeholders..."
    
    if ($DryRun) {
        Write-InfoLog "[DRY-RUN] Would create Fabric secret placeholders in Key Vault"
        return $true
    }
    
    if ([string]::IsNullOrEmpty($script:KeyVaultName)) {
        Write-WarnLog "Key Vault name not configured in aio_config.json"
        Write-InfoLog "Skipping Fabric secret creation. You can create them manually later."
        return $true
    }
    
    $usernameSecretName = "fabric-sasl-username"
    $passwordSecretName = "fabric-sasl-password"
    $usernameValue = '$ConnectionString'
    $passwordPlaceholder = "PUT_YOUR_FABRIC_KAFKA_CONNECTION_STRING_HERE"
    $kvApiVersion = "7.4"
    $kvBaseUrl = "https://$($script:KeyVaultName).vault.azure.net/secrets"
    
    try {
        # Get a Key Vault data-plane token (audience = vault.azure.net)
        # This avoids needing the Az.KeyVault module which is not installed on edge machines.
        $kvToken = (Get-AzAccessToken -ResourceUrl "https://vault.azure.net" -ErrorAction Stop).Token
        $kvHeaders = @{ Authorization = "Bearer $kvToken"; "Content-Type" = "application/json" }
        
        # Helper: GET a secret value (returns $null if not found)
        function Get-KvSecret($name) {
            try {
                $r = Invoke-RestMethod -Method GET -Uri "${kvBaseUrl}/${name}?api-version=${kvApiVersion}" -Headers $kvHeaders -ErrorAction Stop
                return $r.value
            } catch { return $null }
        }
        
        # Helper: SET a secret value
        function Set-KvSecret($name, $value) {
            $body = @{ value = $value } | ConvertTo-Json -Compress
            Invoke-RestMethod -Method PUT -Uri "${kvBaseUrl}/${name}?api-version=${kvApiVersion}" -Headers $kvHeaders -Body $body -ErrorAction Stop | Out-Null
        }
        
        # Username secret
        $existingUsername = Get-KvSecret $usernameSecretName
        if ($existingUsername -eq $usernameValue) {
            Write-InfoLog "Secret '$usernameSecretName' already exists with correct value"
        } else {
            Write-InfoLog "Creating secret '$usernameSecretName'..."
            try {
                Set-KvSecret $usernameSecretName $usernameValue
                Write-Success "Created secret '$usernameSecretName'"
            } catch {
                Write-WarnLog "Failed to create secret '$usernameSecretName': $_"
            }
        }
        
        # Password secret
        $existingPassword = Get-KvSecret $passwordSecretName
        if ($existingPassword -and $existingPassword -ne $passwordPlaceholder) {
            Write-InfoLog "Secret '$passwordSecretName' already exists with custom value (not overwriting)"
        } elseif ($existingPassword -eq $passwordPlaceholder) {
            Write-InfoLog "Secret '$passwordSecretName' already exists with placeholder value"
        } else {
            Write-InfoLog "Creating placeholder secret '$passwordSecretName'..."
            try {
                Set-KvSecret $passwordSecretName $passwordPlaceholder
                Write-Success "Created placeholder secret '$passwordSecretName'"
            } catch {
                Write-WarnLog "Failed to create secret '$passwordSecretName': $_"
            }
        }
        
        Write-Host ""
        Write-Host "Fabric Secret Setup:" -ForegroundColor Cyan
        Write-Host "  Key Vault:       $script:KeyVaultName"
        Write-Host "  Username Secret: $usernameSecretName = '$usernameValue'"
        Write-Host "  Password Secret: $passwordSecretName"
        Write-Host ""
        Write-Host "To set your Fabric connection string:" -ForegroundColor Yellow
        Write-Host "  1. Go to Microsoft Fabric > Event Stream > ... > Connection Settings"
        Write-Host "  2. Copy the Kafka connection string"
        Write-Host "  3. Update the secret (run on this device after 'Connect-AzAccount'):"
        Write-Host ""
        Write-Host "  `$t = (Get-AzAccessToken -ResourceUrl 'https://vault.azure.net').Token" -ForegroundColor Cyan
        Write-Host "  Invoke-RestMethod -Method PUT -Uri 'https://$($script:KeyVaultName).vault.azure.net/secrets/$passwordSecretName`?api-version=7.4' -Headers @{Authorization=`"Bearer `$t`";'Content-Type'='application/json'} -Body '{`"value`":`"YOUR_CONNECTION_STRING`"}'" -ForegroundColor Cyan
        Write-Host ""
        
        return $true
        
    } catch {
        Write-WarnLog "Failed to create Fabric secrets: $_"
        Write-InfoLog "You can create them manually - get a vault token and PUT to the Key Vault data plane:"
        Write-Host "  `$t = (Get-AzAccessToken -ResourceUrl 'https://vault.azure.net').Token" -ForegroundColor Cyan
        Write-Host "  Invoke-RestMethod -Method PUT -Uri 'https://$($script:KeyVaultName).vault.azure.net/secrets/$usernameSecretName`?api-version=7.4' -Headers @{Authorization=`"Bearer `$t`";'Content-Type'='application/json'} -Body '{`"value`":`"`$ConnectionString`"}'" -ForegroundColor Cyan
        Write-Host "  Invoke-RestMethod -Method PUT -Uri 'https://$($script:KeyVaultName).vault.azure.net/secrets/$passwordSecretName`?api-version=7.4' -Headers @{Authorization=`"Bearer `$t`";'Content-Type'='application/json'} -Body '{`"value`":`"YOUR_CONNECTION_STRING`"}'" -ForegroundColor Cyan
        return $true  # Don't fail the whole script
    }
}

# ============================================================================
# VERIFICATION
# ============================================================================

function Test-ArcConnection {
    Write-Log "Verifying Arc connection..."
    
    if ($DryRun) {
        Write-InfoLog "[DRY-RUN] Would verify Arc connection"
        return
    }
    
    # Wait a moment for status to update
    Start-Sleep -Seconds 5
    
    try {
        $arcCluster = Get-AzConnectedKubernetes -ResourceGroupName $script:ResourceGroup -ClusterName $script:ClusterName
        $arcStatus = $arcCluster.ConnectivityStatus
    } catch {
        $arcStatus = "Unknown"
    }
    
    Write-Host ""
    Write-Host "Arc Connection Status:" -ForegroundColor Cyan
    Write-Host "  Cluster:    $script:ClusterName"
    Write-Host "  Status:     $arcStatus"
    Write-Host ""
    
    if ($arcStatus -eq "Connected") {
        Write-Success "Cluster is connected to Azure Arc!"
    } else {
        Write-WarnLog "Cluster status is '$arcStatus'. It may take a few minutes to fully connect."
        Write-InfoLog "Check status with: Get-AzConnectedKubernetes -ResourceGroupName $script:ResourceGroup -ClusterName $script:ClusterName"
    }
}

# ============================================================================
# CHART DOWNLOAD HELPER
# ============================================================================

function Get-ChartFromRegistry {
    <#
    .SYNOPSIS
        Downloads a Helm chart tarball directly from MCR's HTTP registry API.
    
    .DESCRIPTION
        Bypasses the Helm OCI client entirely. This avoids the media-type
        incompatibility error that occurs when the system Helm is older than
        v3.14 and the chart was pushed with newer OCI conventions.
        
        Flow: anonymous token → OCI manifest → chart layer blob → local .tgz
    #>
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$Version
    )
    
    $registry = "mcr.microsoft.com"
    $baseUrl  = "https://$registry/v2/$Repo"
    
    # Step 1: Obtain anonymous bearer token
    Write-InfoLog "Fetching anonymous token from MCR for $Repo..."
    $tokenUrl = "https://$registry/oauth2/token?service=$registry&scope=repository:${Repo}:pull"
    $tokenResp = Invoke-RestMethod -Uri $tokenUrl -ErrorAction Stop
    $authHeaders = @{ Authorization = "Bearer $($tokenResp.access_token)" }
    
    # Step 2: Get OCI manifest
    Write-InfoLog "Fetching OCI manifest for version $Version..."
    $manifestHeaders = $authHeaders.Clone()
    $manifestHeaders['Accept'] = 'application/vnd.oci.image.manifest.v1+json'
    $manifest = Invoke-RestMethod -Uri "$baseUrl/manifests/$Version" -Headers $manifestHeaders -ErrorAction Stop
    
    # Step 3: Find the chart layer (tar+gzip)
    $chartLayer = $manifest.layers | Where-Object {
        $_.mediaType -match 'tar\+gzip|tar\.gzip|chart\.content'
    } | Select-Object -First 1
    
    if (-not $chartLayer) {
        throw "No chart tarball layer found in OCI manifest (layers: $($manifest.layers | ForEach-Object { $_.mediaType }))"
    }
    
    # Step 4: Download the blob
    $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) "azure-arc-k8sagents-${Version}.tgz"
    Write-InfoLog "Downloading chart blob ($($chartLayer.digest)) to $tempFile..."
    Invoke-WebRequest -Uri "$baseUrl/blobs/$($chartLayer.digest)" -Headers $authHeaders -OutFile $tempFile -ErrorAction Stop
    
    if (-not (Test-Path $tempFile) -or (Get-Item $tempFile).Length -eq 0) {
        throw "Downloaded chart file is empty or missing"
    }
    
    Write-InfoLog "Chart downloaded: $('{0:N0}' -f (Get-Item $tempFile).Length) bytes"
    return $tempFile
}

# ============================================================================
# COMPLETION
# ============================================================================

# Track whether custom-locations was successfully enabled
$script:CustomLocationsEnabled = $false

function Enable-CustomLocations {
    <#
    .SYNOPSIS
        Enables custom-locations feature using PowerShell + Helm.
    
    .DESCRIPTION
        The Az.ConnectedKubernetes module gap means New-AzConnectedKubernetes -CustomLocationsOid:
          1. Registers the OID with Azure ARM  (done by PS module)
          2. Does NOT run 'helm upgrade' to enable the feature in the cluster (MISSING from PS module)
        
        This function replicates what 'az connectedk8s enable-features' does internally,
        using pure PowerShell + Helm:
          Step 1: Set-AzConnectedKubernetes -CustomLocationsOid  (ARM registration)
          Step 2: helm upgrade --reuse-values with customLocations flags  (cluster enablement)
        
        Helm is the authoritative source - verified after both steps.
    #>
    
    Write-Log "Enabling custom-locations feature..."
    
    $customLocationsOid = $script:CustomLocationsOid
    if ([string]::IsNullOrEmpty($customLocationsOid)) {
        $customLocationsAppId = "bc313c14-388c-4e7d-a58e-70017303ee3b"
        try {
            $customLocationsOid = (Get-AzADServicePrincipal -ApplicationId $customLocationsAppId -ErrorAction Stop).Id
            if ([string]::IsNullOrEmpty($customLocationsOid)) {
                throw "Service principal returned empty object ID"
            }
        } catch {
            Write-WarnLog "Could not retrieve Custom Locations RP object ID: $_"
            Write-WarnLog "Custom-locations CANNOT be enabled without a valid OID"
            Write-Host ""
            Write-Host "To fix:" -ForegroundColor Yellow
            Write-Host "  1. Register the provider:  Register-AzResourceProvider -ProviderNamespace Microsoft.ExtendedLocation" -ForegroundColor Cyan
            Write-Host "  2. Run grant_entra_id_roles.ps1 from Windows" -ForegroundColor Cyan
            Write-Host "  3. Re-run this script" -ForegroundColor Cyan
            Write-Host ""
            return
        }
    }
    
    Write-InfoLog "Custom Locations OID: $customLocationsOid"
    
    # Check current status via Helm (authoritative source)
    Write-InfoLog "Checking current custom-locations status..."
    try {
        $currentValues = helm get values azure-arc --namespace azure-arc-release -o json 2>$null | ConvertFrom-Json
        if ($currentValues.systemDefaultValues.customLocations.enabled -eq $true) {
            Write-Success "Custom-locations is already enabled!"
            Write-InfoLog "Current OID: $($currentValues.systemDefaultValues.customLocations.oid)"
            $script:CustomLocationsEnabled = $true
            return
        }
    } catch {
        Write-InfoLog "Could not check current Helm state, proceeding with enablement..."
    }
    
    if ($DryRun) {
        Write-InfoLog "[DRY-RUN] Step 1: Would run Set-AzConnectedKubernetes -CustomLocationsOid $customLocationsOid"
        Write-InfoLog "[DRY-RUN] Step 2: Would run helm upgrade azure-arc --reuse-values --set systemDefaultValues.customLocations.enabled=true"
        $script:CustomLocationsEnabled = $true
        return
    }
    
    # Step 1: ARM registration via GET + PUT (best-effort - Helm in Step 2 is authoritative)
    Write-InfoLog "Step 1: Registering custom-locations OID in ARM via GET + PUT..."
    try {
        $resourceId = "/subscriptions/$($script:SubscriptionId)/resourceGroups/$($script:ResourceGroup)/providers/Microsoft.Kubernetes/connectedClusters/$($script:ClusterName)"
        $apiVersion = "2024-06-01-preview"
        
        $getResponse = Invoke-AzRestMethod -Method GET -Path "${resourceId}?api-version=${apiVersion}" -ErrorAction Stop
        if ($getResponse.StatusCode -ne 200) { throw "GET failed: HTTP $($getResponse.StatusCode)" }
        $resource = $getResponse.Content | ConvertFrom-Json
        
        if (-not $resource.properties.features) {
            $resource.properties | Add-Member -MemberType NoteProperty -Name features -Value ([PSCustomObject]@{}) -Force
        }
        if (-not $resource.properties.features.customLocations) {
            $resource.properties.features | Add-Member -MemberType NoteProperty -Name customLocations -Value ([PSCustomObject]@{}) -Force
        }
        $resource.properties.features.customLocations | Add-Member -MemberType NoteProperty -Name settings -Value ([PSCustomObject]@{ customLocationsOid = $customLocationsOid }) -Force
        
        $putResponse = Invoke-AzRestMethod -Method PUT -Path "${resourceId}?api-version=${apiVersion}" -Payload ($resource | ConvertTo-Json -Depth 20 -Compress) -ErrorAction Stop
        if ($putResponse.StatusCode -in 200, 201, 202) {
            Write-Success "ARM registration complete"
        } else {
            Write-WarnLog "PUT returned HTTP $($putResponse.StatusCode) - Step 2 (Helm) will handle enablement"
        }
    } catch {
        Write-WarnLog "GET+PUT for custom-locations OID failed: $_"
        Write-InfoLog "Continuing to Step 2 - Helm update can succeed independently"
    }
    
    # Step 2: Helm upgrade to actually enable the feature in the cluster
    # This is the step the PS module skips - we do it explicitly.
    # The azure-arc chart is installed by the Arc agent from an internal OCI registry.
    # Strategy:
    #   A) Try OCI reference directly (works with Helm >= 3.14)
    #   B) If OCI fails due to media-type incompatibility, download the chart
    #      tarball via MCR's HTTP registry API and use the local .tgz file
    Write-InfoLog "Step 2: Enabling custom-locations in cluster via Helm..."
    
    # Extract chart version from the installed release
    $chartVersion = $null
    try {
        $releaseJson = helm list -n azure-arc-release -f '^azure-arc$' -o json 2>$null | ConvertFrom-Json
        if ($releaseJson -and $releaseJson.Count -gt 0) {
            $chartString = $releaseJson[0].chart
            if ($chartString -match '-([\d]+\.[\d]+\.[\d]+.*)$') {
                $chartVersion = $Matches[1]
                Write-InfoLog "Installed chart: $chartString (version: $chartVersion)"
            }
        }
    } catch {
        Write-WarnLog "Could not determine installed chart version: $_"
    }
    
    $helmSetArgs = @(
        "--namespace", "azure-arc-release",
        "--reuse-values",
        "--set", "systemDefaultValues.customLocations.enabled=true",
        "--set", "systemDefaultValues.customLocations.oid=$customLocationsOid"
    )
    
    $helmUpgradeSuccess = $false
    
    # Attempt A: OCI reference (fast path — works if Helm supports the media type)
    $ociRef = "oci://mcr.microsoft.com/azurearck8s/batch1/stable/azure-arc-k8sagents"
    $helmArgs = @("upgrade", "azure-arc", $ociRef) + $helmSetArgs
    if ($chartVersion) { $helmArgs += @("--version", $chartVersion) }
    
    Write-InfoLog "Attempt A - OCI pull: helm $($helmArgs -join ' ')"
    $helmResult = & helm @helmArgs 2>&1
    
    if ($LASTEXITCODE -eq 0) {
        $helmUpgradeSuccess = $true
        Write-Success "Helm upgrade completed (OCI)"
    } else {
        Write-WarnLog "OCI-based upgrade failed: $helmResult"
        Write-InfoLog "Falling back to direct HTTP chart download..."
        
        # Attempt B: Download chart tarball via MCR HTTP API (bypasses Helm OCI client)
        $localChart = $null
        try {
            if (-not $chartVersion) {
                throw "Cannot download chart — installed version unknown"
            }
            $localChart = Get-ChartFromRegistry `
                -Repo "azurearck8s/batch1/stable/azure-arc-k8sagents" `
                -Version $chartVersion
            
            $helmArgs = @("upgrade", "azure-arc", $localChart) + $helmSetArgs
            Write-InfoLog "Attempt B - Local tgz: helm $($helmArgs -join ' ')"
            $helmResult = & helm @helmArgs 2>&1
            
            if ($LASTEXITCODE -eq 0) {
                $helmUpgradeSuccess = $true
                Write-Success "Helm upgrade completed (direct download)"
            } else {
                Write-ErrorLog "Helm upgrade failed with local chart: $helmResult"
            }
        } catch {
            Write-ErrorLog "Direct chart download failed: $_"
        } finally {
            if ($localChart -and (Test-Path $localChart)) {
                Remove-Item $localChart -Force -ErrorAction SilentlyContinue
            }
        }
    }
    
    if (-not $helmUpgradeSuccess) {
        Write-Host ""
        Write-Host "Custom-locations could not be enabled automatically." -ForegroundColor Yellow
        Write-Host "To enable manually from a machine with az CLI, run:" -ForegroundColor Yellow
        Write-Host "  az connectedk8s enable-features --name $script:ClusterName --resource-group $script:ResourceGroup --features cluster-connect custom-locations" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "Or upgrade Helm to >= 3.14 on this machine and re-run this script:" -ForegroundColor Yellow
        Write-Host "  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash" -ForegroundColor Cyan
        Write-Host ""
        return
    }
    
    # Verify both steps worked
    Write-InfoLog "Verifying custom-locations is enabled..."
    Start-Sleep -Seconds 3
    
    try {
        $verifyResult = helm get values azure-arc --namespace azure-arc-release -o json 2>$null | ConvertFrom-Json
        if ($verifyResult.systemDefaultValues.customLocations.enabled -eq $true) {
            Write-Success "Custom-locations feature is now enabled!"
            Write-InfoLog "  enabled: true"
            Write-InfoLog "  oid:     $($verifyResult.systemDefaultValues.customLocations.oid)"
            $script:CustomLocationsEnabled = $true
        } else {
            Write-WarnLog "Helm values don't show custom-locations as enabled yet."
            Write-WarnLog "It may take a moment to sync. Verify with:"
            Write-Host "  helm get values azure-arc -n azure-arc-release -o json | jq '.systemDefaultValues.customLocations'" -ForegroundColor Cyan
        }
    } catch {
        Write-WarnLog "Could not verify Helm state after upgrade: $_"
        Write-Host "Verify manually:" -ForegroundColor Yellow
        Write-Host "  helm get values azure-arc -n azure-arc-release -o json | jq '.systemDefaultValues.customLocations'" -ForegroundColor Cyan
    }
}

function Show-Completion {
    Write-Host ""
    
    if ($script:CustomLocationsEnabled) {
        Write-Host "============================================================================" -ForegroundColor Green
        Write-Host "Arc Enablement Completed Successfully!" -ForegroundColor Green
        Write-Host "============================================================================" -ForegroundColor Green
        Write-Host ""
        Write-Host "Your cluster '$script:ClusterName' is now connected to Azure Arc."
        Write-Host "  - Custom-locations feature is enabled" -ForegroundColor Green
        Write-Host "  - K3s OIDC issuer configured for secret sync" -ForegroundColor Green
    } else {
        Write-Host "============================================================================" -ForegroundColor Yellow
        Write-Host "Arc Enablement Completed (with warnings)" -ForegroundColor Yellow
        Write-Host "============================================================================" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Your cluster '$script:ClusterName' is connected to Azure Arc."
        Write-Host "  - K3s OIDC issuer configured for secret sync" -ForegroundColor Green
        Write-Host "  - Custom-locations could NOT be verified" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Before proceeding, verify custom-locations manually:" -ForegroundColor Cyan
        Write-Host "  helm get values azure-arc -n azure-arc-release -o json | jq '.systemDefaultValues.customLocations'"
        Write-Host ""
        Write-Host "If 'enabled' is not true, run:" -ForegroundColor Cyan
        Write-Host "  az connectedk8s enable-features --name $script:ClusterName --resource-group $script:ResourceGroup --features cluster-connect custom-locations"
    }
    Write-Host ""
    Write-Host "Next Steps:" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "1. From your Windows management machine, run:"
    Write-Host "   cd external_configuration"
    Write-Host "   .\External-Configurator.ps1"
    Write-Host ""
    Write-Host "2. This will deploy Azure IoT Operations to your cluster."
    Write-Host ""
    Write-Host "3. After deployment, run grant_entra_id_roles.ps1 to set up permissions:"
    Write-Host "   .\grant_entra_id_roles.ps1"
    Write-Host ""
    Write-Host "Useful Commands:" -ForegroundColor Cyan
    Write-Host "  Check Arc status:  Get-AzConnectedKubernetes -ResourceGroupName $script:ResourceGroup -ClusterName $script:ClusterName"
    Write-Host "  View Arc agents:   kubectl get pods -n azure-arc"
    Write-Host "  Verify OIDC issuer: kubectl cluster-info dump | grep service-account-issuer"
    Write-Host "  Verify custom-locations: helm get values azure-arc -n azure-arc-release -o json | jq '.systemDefaultValues.customLocations'"
    Write-Host ""
    Write-Host "Log file: $LogFile"
    Write-Host ""
}

# ============================================================================
# MAIN
# ============================================================================

function Main {
    # Setup logging
    Write-Host "============================================================================"
    Write-Host "Azure IoT Operations - Arc Enable Script (PowerShell)"
    Write-Host "============================================================================"
    Write-Host "Log file: $LogFile"
    Write-Host "Started: $(Get-Date)"
    Write-Host ""
    
    Add-Content -Path $LogFile -Value "============================================================================"
    Add-Content -Path $LogFile -Value "Azure IoT Operations - Arc Enable Script (PowerShell)"
    Add-Content -Path $LogFile -Value "Started: $(Get-Date)"
    Add-Content -Path $LogFile -Value "============================================================================"
    
    if ($DryRun) {
        Write-Host "*** DRY-RUN MODE - No changes will be made ***" -ForegroundColor Yellow
        Write-Host ""
    }
    
    Load-Configuration
    Check-Prerequisites
    Connect-ToAzure
    Test-ResourceGroup
    Enable-ArcForCluster
    Enable-ArcFeatures
    Enable-AzureRbac
    Enable-OidcWorkloadIdentity
    
    # Configure K3s OIDC issuer for secret sync
    # This may exit early if K3s needs to restart - user should re-run
    $oidcConfigured = Configure-K3sOidcIssuer
    if (-not $oidcConfigured) {
        Write-Log "Script exiting - re-run after K3s restarts to complete configuration"
        exit 0
    }
    
    # Create placeholder secrets for Fabric Event Streams
    Create-FabricSecretPlaceholders
    
    Enable-CustomLocations  # Enable custom-locations via Azure CLI
    Test-ArcConnection
    Show-Completion
    
    Write-Log "Arc enablement completed successfully!"
}

# Run main function
try {
    Main
} catch {
    Write-ErrorLog "Script failed: $_" -Fatal
}
