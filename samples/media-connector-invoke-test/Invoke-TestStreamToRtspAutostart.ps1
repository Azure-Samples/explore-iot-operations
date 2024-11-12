$aioConnectorsNamespace = (Get-Content -Path (Join-Path -Path $PSScriptRoot -ChildPath ".config_aio_connectors_namespace") -Raw).Trim()
Write-Host "AIO connectors namespace: $aioConnectorsNamespace"

$aepName = "aep-public-http-anonymous-1"
Write-Host "AEP name: $aepName"

$assetName = "asset-public-http-anonymous-1-stream-to-rtsp-autostart"
Write-Host "Asset name: $assetName"

$datapointName = "stream-to-rtsp"
Write-Host "Datapoint name: $datapointName"

. (Join-Path -Path $PSScriptRoot -ChildPath "Invoke-ResourceInstallMonitorAndUninstall.ps1") `
    -aepName $aepName `
    -assetName $assetName `
    -datapointName $datapointName `
    -monitorExpresion `
        ". (Join-Path -Path $PSScriptRoot -ChildPath `"Start-RtspStreamViewer.ps1`") -assetName $assetName ; `
        try { Write-Host `"`nHit Ctrl+C to terminate`" ; Start-Sleep -Seconds 3600 } finally { Write-Host `"`nContinuing...`n`" }"
