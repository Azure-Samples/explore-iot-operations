#Requires -Version 7
<#
    Update the Media Server config files.
#>

$mediaServerNamespace="media-server"

Write-Host "Detecting the Media Server endpoint..."
$mediaServerEndpointIp=(kubectl get service media-server-public `
    --namespace ${mediaServerNamespace} `
    --output jsonpath='{.status.loadBalancer.ingress[0].ip}')
If (${mediaServerEndpointIp}) {
    Write-Host "Media Server endpoint IP: ${mediaServerEndpointIp}"
    $mediaServerHost=$mediaServerEndpointIp
} Else {
    $mediaServerEndpointHostname=(kubectl get service media-server-public `
        --namespace ${mediaServerNamespace} `
        --output jsonpath='{.status.loadBalancer.ingress[0].hostname}')
	If (${mediaServerEndpointHostname}) {
        Write-Host "Media Server endpoint hostname: ${mediaServerEndpointHostname}"
        $mediaServerHost=$mediaServerEndpointHostname
    }
}
If (-not ${mediaServerEndpointIp} -and -not ${mediaServerEndpointHostname}) {
    Write-Host "Failed to detect the Media Server endpoint. Exiting..."
    Exit 1
}

Write-Host "Media Server host: ${mediaServerHost}"
Out-File -FilePath (Join-Path -Path $PSScriptRoot -ChildPath ".config_media_server_host") -InputObject $mediaServerHost -NoNewline

Write-Host "Done!`n"
