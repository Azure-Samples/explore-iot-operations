#Requires -Version 7
<#
    Install a resource pair (aep/asset), monitor it, and uninstall it.
#>
param (
    [Parameter(
        Mandatory,
        HelpMessage="The AEP name.")]
    [string]$aepName = "",
    [Parameter(
        Mandatory,
        HelpMessage="The asset name.")]
    [string]$assetName = "",
    [Parameter(
        Mandatory,
        HelpMessage="The datapoint name.")]
    [string]$datapointName = "",
    [Parameter(
        Mandatory,
        HelpMessage="The monitor expression.")]
    [string]$monitorExpresion = ""
)

Write-Host "`n"
Write-Host (Split-Path -Path $PSCommandPath -Leaf).ToUpper() -ForegroundColor White

(Join-Path -Path $PSScriptRoot -ChildPath "Test-Prerequisites.ps1") | Out-Null

$aioNamespace = (Get-Content -Path (Join-Path -Path $PSScriptRoot -ChildPath ".config_aio_namespace") -Raw).Trim()
Write-Host "AIO namespace: $aioNamespace"

$aioConnectorsNamespace = (Get-Content -Path (Join-Path -Path $PSScriptRoot -ChildPath ".config_aio_connectors_namespace") -Raw).Trim()
Write-Host "AIO connectors namespace: $aioConnectorsNamespace"

Write-Host "AEP Name: $aepName"

Write-Host "Asset Name: $assetName"

Write-Host "Datapoint Name: $datapointName"

Write-Host "Installing the resource files..."
. (Join-Path -Path $PSScriptRoot -ChildPath "Install-ResourceFile.ps1") -resourceFile "${aepName}.yaml"
. (Join-Path -Path $PSScriptRoot -ChildPath "Install-ResourceFile.ps1") -resourceFile "${assetName}.yaml"

Write-Host "Waiting for the snapshot-to-mqtt task to be ready...`n"
Start-Sleep -Seconds 3

try {
    Write-Host "Starting the monitor command...`n"
    $monitorExpresion = $ExecutionContext.InvokeCommand.ExpandString(${monitorExpresion})
    Invoke-Expression "${monitorExpresion}"

} finally {

    Write-Host "Uninstalling the resource files...`n"
    . (Join-Path -Path $PSScriptRoot -ChildPath "Uninstall-ResourceFile.ps1") -resourceFile "${assetName}.yaml"
    . (Join-Path -Path $PSScriptRoot -ChildPath "Uninstall-ResourceFile.ps1") -resourceFile "${aepName}.yaml"

    Write-Host "Snapshot-to-mqtt task test completed.`n"
}
