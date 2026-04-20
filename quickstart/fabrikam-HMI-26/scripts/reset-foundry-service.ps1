<#
.SYNOPSIS
    Stop and restart the Foundry Local service.

.DESCRIPTION
    When Foundry Local becomes unresponsive (HTTP 503, timeouts from the agent),
    a service restart is the fastest recovery path. This script gracefully stops
    the service, waits for it to fully exit, then starts it again.

    Problem solved: Foundry Local can lock up after a model load failure or 
    after the host machine resumes from sleep. Port 5272 stays occupied but
    requests hang indefinitely.

.NOTES
    Requires: Foundry Local installed (winget install Microsoft.FoundryLocal).
    Run on the Windows machine hosting Foundry Local.
#>

$ErrorActionPreference = "Stop"
$Port = 5272

Write-Host "Stopping Foundry Local service..."
foundry service stop

# Wait for port to be released
$MaxWait = 20
$Waited  = 0
while ($Waited -lt $MaxWait) {
    $InUse = netstat -ano | Select-String ":$Port "
    if (-not $InUse) { break }
    Start-Sleep -Seconds 1
    $Waited++
}

if ($Waited -ge $MaxWait) {
    Write-Warning "Port $Port still in use after ${MaxWait}s. Attempting to kill the process..."
    $Pid = (netstat -ano | Select-String ":$Port\s" | Select-Object -First 1) -replace '.*\s(\d+)$','$1'
    if ($Pid) { Stop-Process -Id $Pid -Force }
}

Write-Host "Starting Foundry Local service..."
foundry service start

Write-Host ""
foundry service status
