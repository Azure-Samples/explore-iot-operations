<#
.SYNOPSIS
    Recreate the ACR pull secret in the default namespace.

.DESCRIPTION
    When pods show ImagePullBackOff, it is often because the ACR pull secret is
    missing or expired in the target namespace. This script re-creates it using
    the container registry from aio_config.json and the current az login context.

    Problem solved: Deploy-EdgeModules.ps1 creates the secret during initial 
    deployment, but it can disappear after a cluster restart or namespace recreation.

.NOTES
    Requires: Azure CLI, kubectl, active az login with access to the ACR.
#>

$ErrorActionPreference = "Stop"

$ConfigPath = Join-Path $PSScriptRoot "../../config/aio_config.json"
if (-not (Test-Path $ConfigPath)) {
    Write-Error "aio_config.json not found at $ConfigPath"
    exit 1
}

$Config     = Get-Content $ConfigPath | ConvertFrom-Json
$RegistryName = $Config.azure.container_registry
$Namespace  = "default"
$SecretName = "acr-pull-secret"

Write-Host "Registry  : $RegistryName"
Write-Host "Namespace : $Namespace"
Write-Host "Secret    : $SecretName"
Write-Host ""

# Get ACR token via az acr login
Write-Host "Fetching ACR credentials..."
$Token    = az acr login --name $RegistryName --expose-token --output tsv --query accessToken
$LoginSrv = "$RegistryName.azurecr.io"

# Delete existing secret if present
$Existing = kubectl get secret $SecretName -n $Namespace --ignore-not-found
if ($Existing) {
    Write-Host "Deleting existing secret..."
    kubectl delete secret $SecretName -n $Namespace
}

# Create new secret
Write-Host "Creating pull secret..."
kubectl create secret docker-registry $SecretName `
    --namespace $Namespace `
    --docker-server  $LoginSrv `
    --docker-username "00000000-0000-0000-0000-000000000000" `
    --docker-password $Token

Write-Host ""
Write-Host "Done. Restart affected deployments:"
Write-Host "  kubectl rollout restart deployment/edgemqttsim -n $Namespace"
