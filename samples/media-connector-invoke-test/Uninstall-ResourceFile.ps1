#Requires -Version 7
<#
    Uninstall a resource file.
#>
param (
    [Parameter(
        Mandatory=$true,
        HelpMessage="The resource file.")]
    [string]$resourceFile
)

Write-Host "`n"
Write-Host (Split-Path -Path $PSCommandPath -Leaf).ToUpper() -ForegroundColor White

$aioConnectorsNamespace = (Get-Content -Path (Join-Path -Path $PSScriptRoot -ChildPath ".config_aio_connectors_namespace") -Raw).Trim()
Write-Host "AIO connectors namespace: $aioConnectorsNamespace"

$resourcesDirectory = (Get-Content -Path (Join-Path -Path $PSScriptRoot -ChildPath ".config_resources_path") -Raw).Trim()
$resourcesDirectory = $ExecutionContext.InvokeCommand.ExpandString(${resourcesDirectory})
Write-Host "Resources directory: $resourcesDirectory"

Write-Host "Resource file: $resourceFile"

$fileFullPath=(Join-Path -Path $resourcesDirectory -ChildPath $resourceFile)
Write-Host "Resource file full path: ${fileFullPath}"

Write-Host "Deleteing the resource..."
. kubectl delete -n ${aioConnectorsNamespace} -f ${fileFullPath}
If ($LastExitCode -ne 0) {
    Write-Host "Error: The resource could not be applied."
    Exit $LastExitCode
} Else {
    Write-Host "The resource was deleted successfully.`n"
}
