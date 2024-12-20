#Requires -Version 7
<#
    Start the default browser to watch an RTPS stream from the media server.
#>
param (
    [Parameter(
        Mandatory,
        HelpMessage="The asset name.")]
    [string]$assetName = ""
)

Write-Host (Split-Path -Path $PSCommandPath -Leaf).ToUpper() -ForegroundColor White

. (Join-Path $PSScriptRoot "Test-Prerequisites.ps1")

. (Join-Path $PSScriptRoot "Update-MediaServerConfigFiles.ps1")

$aioNamespace = (Get-Content -Path (Join-Path $PSScriptRoot ".config_aio_namespace") -Raw).Trim()
Write-Host "AIO namespace: $aioNamespace"

$aioConnectorsNamespace = (Get-Content -Path (Join-Path $PSScriptRoot ".config_aio_connectors_namespace") -Raw).Trim()
Write-Host "AIO connectors namespace: $aioConnectorsNamespace"

$mediaServer = (Get-Content -Path (Join-Path $PSScriptRoot ".config_media_server_host") -Raw).Trim()
Write-Host "Media Server: $mediaServer"

Write-Host "Asset Name: $assetName"

$streamUrl = "http://${mediaServer}:8888/${aioConnectorsNamespace}/data/${assetName}/"
Write-Host "Stream URL: $streamUrl"

Write-Host "Showing the RTSP stream from the media server in the default browser..."

if ($PSVersionTable.PSEdition -eq "Core") {
    # Check if the script is running on Windows
    If ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
        Write-Host "Running on Windows"
        . start $streamUrl
    }
    # Check if the script is running on Linux
    ElseIf ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Linux)) {
        Write-Host "Running on Linux"
        If (Test-Path -Path env:WSL_DISTRO_NAME) {
            Write-Host "Running on WSL"
            . wslview $streamUrl
        } Else {
            Write-Host "Not running on WSL"
            . xdg-open $streamUrl
        }
    }
    # Check if the script is running on macOS
    ElseIf ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::OSX)) {
        Write-Host "Running on macOS"

        Throw 'Error: macOS is not (yet) supported.`n'
    } Else {
        Write-Host "Unknown platform"

        Throw 'Error: Unknown platform.`n'
    }
} else {
    Write-Host "This script requires PowerShell Core"
}
