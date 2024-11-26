#Requires -Version 7
<#
    Start a file monitor session in the AIO Media Connector pod.
#>
param (
    [Parameter(
        HelpMessage="The path to monitor.")]
    [string]$pathToMonitor = ""
)

Write-Host (Split-Path -Path $PSCommandPath -Leaf).ToUpper() -ForegroundColor White

. (Join-Path -Path $PSScriptRoot -ChildPath "Test-Prerequisites.ps1")

$aioNamespace = (Get-Content -Path (Join-Path -Path $PSScriptRoot -ChildPath ".config_aio_namespace") -Raw).Trim()
Write-Host "AIO namespace: $aioNamespace"

$aioConnectorsNamespace = (Get-Content -Path (Join-Path -Path $PSScriptRoot -ChildPath ".config_aio_connectors_namespace") -Raw).Trim()
Write-Host "AIO connectors namespace: $aioConnectorsNamespace"

If ($pathToMonitor -eq "") {
    $pathToMonitor = "/tmp/${aioNamespace}"
}
Write-Host "Path to monitor: $pathToMonitor"

$podName = (kubectl get pods -n $aioConnectorsNamespace -l app.kubernetes.io/component=aio-opc-rtsp-1 --output=jsonpath='{.items[*].metadata.name}')
if ($null -eq $podName) {
    Write-Host "No pod found"
    Exit 1
}
Write-Host "Pod name: $podName"

try {
    Write-Host "Checking if inotifywait is installed..."
    $iNotifyWaitPath = "/usr/bin/inotifywait"
    $commandString = "kubectl exec --stdin --tty $podName -n $aioConnectorsNamespace -- ls ${iNotifyWaitPath}"
    $result = Invoke-Expression "${commandString}"
    If ($result -eq $iNotifyWaitPath) {
        Write-Host "Starting the file system monitor based on inotifywait..."
        $commandString = "kubectl exec --stdin --tty $podName -n $aioConnectorsNamespace -- inotifywait -m -r -e create -e delete -e modify --timefmt `"%Y-%m-%d %H:%M:%S`" --format `"[%T] [%e] [%w] [%f]`" ${pathToMonitor}"
        Invoke-Expression "${commandString}"
    } Else {
        Write-Host "inotifywait is not installed, pooling with find..."
        $commandString = "kubectl exec --stdin --tty $podName -n $aioConnectorsNamespace -- sh -c `'while true ; do find ${pathToMonitor} -cmin 0.05 ; sleep 3 ; done `'"
        Invoke-Expression "${commandString}"
    }

} finally {
    Write-Host "`nThe file system monitor ended."
}
