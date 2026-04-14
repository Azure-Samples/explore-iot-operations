<#
.SYNOPSIS
    Session Bootstrap - Optional helper for AKS-EE single-machine deployments

.DESCRIPTION
    OPTIONAL: You do not have to use this script.

    If you prefer, skip this script entirely and set the required environment
    variables directly in your PS7 session, then run External-Configurator.ps1:

        $env:AZURE_SUBSCRIPTION_ID = "your-sub-id"
        $env:AZURE_TENANT_ID       = "your-tenant-id"
        $env:AZURE_LOCATION        = "eastus2"
        $env:AZURE_RESOURCE_GROUP  = "rg-my-iot"
        az login --tenant $env:AZURE_TENANT_ID
        az account set --subscription $env:AZURE_SUBSCRIPTION_ID
        .\External-Configurator.ps1

    Alternatively, fill in the REQUIRED section below, save the file, and run
    this script once at the start of each PS7 session. It will set all variables
    and log you in automatically.

.NOTES
    Requires PowerShell 7+
    Run from the external_configuration/ directory:
        cd external_configuration
        .\session-bootstrap.ps1
#>

# ============================================================================
# REQUIRED (if using this script): Fill these in once, then run the script
# ============================================================================

$AZ_SUBSCRIPTION_ID    = ""   # Find yours: az account list -o table
$AZ_TENANT_ID          = ""   # OPTIONAL - only needed if you have multiple Azure tenants
                               # Find yours: az account show --query tenantId -o tsv
$AZ_LOCATION           = ""   # e.g. eastus2, westus, westeurope
$AZ_RESOURCE_GROUP     = ""   # Will be created if it does not exist
$AKS_EDGE_CLUSTER_NAME = ""   # Must be lowercase, no spaces
$AZ_CONTAINER_REGISTRY = ""   # Short name only, e.g. myregistry (NOT myregistry.azurecr.io)
                               # Leave blank to let External-Configurator.ps1 auto-generate one

# Optional: set a working directory to cd into automatically
$WORKDIR = ""                  # e.g. C:\workingdir  (leave blank to skip)

# ============================================================================
# DO NOT EDIT BELOW THIS LINE
# ============================================================================

# Validate required fields
$missingFields = @()
if ([string]::IsNullOrWhiteSpace($AZ_SUBSCRIPTION_ID))    { $missingFields += "AZ_SUBSCRIPTION_ID" }
# AZ_TENANT_ID is optional - only required if you have multiple Azure tenants
if ([string]::IsNullOrWhiteSpace($AZ_LOCATION))           { $missingFields += "AZ_LOCATION" }
if ([string]::IsNullOrWhiteSpace($AZ_RESOURCE_GROUP))     { $missingFields += "AZ_RESOURCE_GROUP" }
if ([string]::IsNullOrWhiteSpace($AKS_EDGE_CLUSTER_NAME)) { $missingFields += "AKS_EDGE_CLUSTER_NAME" }

if ($missingFields.Count -gt 0) {
    Write-Host ""
    Write-Host "[ERROR] The following required variables are not set:" -ForegroundColor Red
    foreach ($field in $missingFields) {
        Write-Host "        $field" -ForegroundColor Red
    }
    Write-Host ""
    Write-Host "Edit the REQUIRED section at the top of session-bootstrap.ps1 and run again," -ForegroundColor Yellow
    Write-Host "OR skip this script and set env vars directly in your terminal (see .DESCRIPTION)." -ForegroundColor Yellow
    exit 1
}

# Change to working directory if specified
if (-not [string]::IsNullOrWhiteSpace($WORKDIR)) {
    if (Test-Path $WORKDIR) {
        Set-Location $WORKDIR
        Write-Host "[INFO] Working directory set to: $WORKDIR" -ForegroundColor Cyan
    } else {
        Write-Host "[WARN] WORKDIR not found, skipping: $WORKDIR" -ForegroundColor Yellow
    }
}

# Set global variables (consumed by AksEdgeQuickStartForAio.ps1)
$global:SubscriptionId    = $AZ_SUBSCRIPTION_ID
$global:TenantId          = $AZ_TENANT_ID
$global:Location          = $AZ_LOCATION
$global:ResourceGroupName = $AZ_RESOURCE_GROUP
$global:ClusterName       = $AKS_EDGE_CLUSTER_NAME

# Set environment variables (consumed by az CLI and our scripts)
$env:AZURE_SUBSCRIPTION_ID    = $AZ_SUBSCRIPTION_ID
$env:AZURE_TENANT_ID          = $AZ_TENANT_ID
$env:AZURE_LOCATION           = $AZ_LOCATION
$env:AZURE_RESOURCE_GROUP     = $AZ_RESOURCE_GROUP
$env:AKSEDGE_CLUSTER_NAME     = $AKS_EDGE_CLUSTER_NAME
if (-not [string]::IsNullOrWhiteSpace($AZ_CONTAINER_REGISTRY)) {
    $env:AZURE_CONTAINER_REGISTRY = $AZ_CONTAINER_REGISTRY
}

# Log into Azure
Write-Host ""
if (-not [string]::IsNullOrWhiteSpace($AZ_TENANT_ID)) {
    Write-Host "Logging into Azure (tenant: $AZ_TENANT_ID)..." -ForegroundColor Cyan
    az login --tenant $AZ_TENANT_ID | Out-Null
} else {
    Write-Host "Logging into Azure..." -ForegroundColor Cyan
    az login | Out-Null
}
az account set --subscription $AZ_SUBSCRIPTION_ID

# Auto-lookup Custom Locations Resource Provider Object ID (tenant-specific, used by AKS-EE quickstart)
$customLocOid = az ad sp show --id bc313c14-388c-4e7d-a58e-70017303ee3b --query id -o tsv 2>$null
if (-not [string]::IsNullOrWhiteSpace($customLocOid)) {
    $global:CustomLocationOID = $customLocOid
    $env:CUSTOM_LOCATIONS_OID = $customLocOid
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " Session ready." -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  Subscription : $AZ_SUBSCRIPTION_ID" -ForegroundColor Gray
Write-Host "  Tenant       : $AZ_TENANT_ID" -ForegroundColor Gray
Write-Host "  Location     : $AZ_LOCATION" -ForegroundColor Gray
Write-Host "  Resource Grp : $AZ_RESOURCE_GROUP" -ForegroundColor Gray
Write-Host "  Cluster Name : $AKS_EDGE_CLUSTER_NAME" -ForegroundColor Gray
if (-not [string]::IsNullOrWhiteSpace($AZ_CONTAINER_REGISTRY)) {
    Write-Host "  ACR Name     : $AZ_CONTAINER_REGISTRY" -ForegroundColor Gray
}
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Run AKS-EE quickstart (if not done yet)" -ForegroundColor Gray
Write-Host "  2. .\grant_entra_id_roles.ps1" -ForegroundColor Gray
Write-Host "  3. .\External-Configurator.ps1" -ForegroundColor Gray
Write-Host ""
