<#
.SYNOPSIS
    Start the Omniverse MQTT connector for the HMI-26 factory stage.

.DESCRIPTION
    Launches the Omniverse IoT Connector pointed at the AIO MQTT broker and 
    the local Nucleus server. Uses connector-config.json from the omniverse/ folder.
    
    Run this on the Windows machine that has Omniverse installed, after the edge
    cluster and AIO are up and the factory simulator is running.

.NOTES
    Problem solved: The connector needs specific config paths that differ between
    machines. This script handles the path resolution so it "just works" from
    the repo directory.
#>

$ErrorActionPreference = "Stop"

$RepoRoot   = Resolve-Path (Join-Path $PSScriptRoot "../../..")
$ConfigFile = Join-Path $PSScriptRoot "../omniverse/connector-config.json"

if (-not (Test-Path $ConfigFile)) {
    Write-Error "connector-config.json not found at $ConfigFile"
    exit 1
}

Write-Host "Starting Omniverse connector..."
Write-Host "  Config : $ConfigFile"
Write-Host "  Repo   : $RepoRoot"

# TODO: Replace the command below with the actual Omniverse connector executable
# and any required arguments. This is a placeholder.
# Example: & "C:\Program Files\NVIDIA Corporation\Omniverse\connector\iot_connector.exe" --config $ConfigFile

Write-Host ""
Write-Host "[PLACEHOLDER] Update this script with the path to your Omniverse connector executable."
Write-Host "See omniverse/README.md for setup instructions."
