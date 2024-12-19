<#
    Start an interactive session in the AIO Media Connector pod.
#>

Write-Host (Split-Path -Path $PSCommandPath -Leaf).ToUpper() -ForegroundColor White

. (Join-Path -Path $PSScriptRoot -ChildPath "Test-Prerequisites.ps1")

$aioNamespace = (Get-Content -Path (Join-Path -Path $PSScriptRoot -ChildPath ".config_aio_namespace") -Raw).Trim()
Write-Host "AIO namespace: $aioNamespace"

$aioConnectorsNamespace = (Get-Content -Path (Join-Path -Path $PSScriptRoot -ChildPath ".config_aio_connectors_namespace") -Raw).Trim()
Write-Host "AIO connectors namespace: $aioConnectorsNamespace"

$podName = (kubectl get pods -n $aioConnectorsNamespace -l app.kubernetes.io/component=aio-opc-rtsp-1 --output=jsonpath='{.items[*].metadata.name}')
if ($null -eq $podName) {
    Write-Host "No pod found"
    Exit 1
}
Write-Host "Pod name: $podName"

try {
    Write-Host "Starting an interactive session..."
    . kubectl exec --stdin --tty $podName -n $aioConnectorsNamespace -- /bin/bash
} finally {
    Write-Host "`nThe interactive session ended."
}
