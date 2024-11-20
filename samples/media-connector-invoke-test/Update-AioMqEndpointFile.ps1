#Requires -Version 7
<#
    Update the AIO MQ endpoint file.
#>

$aioNamespace = (Get-Content -Path (Join-Path -Path $PSScriptRoot -ChildPath .config_aio_namespace) -Raw).Trim()
Write-Host "AIO connectors namespace: ${aioNamespace}"

$aioMqPort=1883

Function Detect-MQ {
    Param (
        [string]$serviceName
    )
    Write-Host "Detecting the MQ endpoint..."
    $aioMqEndpointIp=(kubectl get service ${serviceName} `
        --namespace ${aioNamespace} `
        --output jsonpath='{.status.loadBalancer.ingress[0].ip}')
    If (${aioMqEndpointIp}) {
        Write-Host "AIO MQ endpoint IP: ${aioMqEndpointIp}"
        $aioMqEndpoint="mqtt://${aioMqEndpointIp}:${aioMqPort}"
        $aioMqHost=$aioMqEndpointIp
    } Else {
        $aioMqEndpointHostname=(kubectl get service ${serviceName} `
            --namespace ${aioNamespace} `
            --output jsonpath='{.status.loadBalancer.ingress[0].hostname}')
        If (${aioMqEndpointHostname}) {
            Write-Host "AIO MQ endpoint hostname: ${aioMqEndpointHostname}"
            $aioMqEndpoint="mqtt://${aioMqEndpointHostname}:${aioMqPort}"
            $aioMqHost=$aioMqEndpointHostname
        }
    }
}

. Detect-MQ -serviceName "aio-broker"
If (-not ${aioMqEndpointIp} -and -not ${aioMqEndpointHostname}) {
    . Detect-MQ -serviceName "aio-broker-listener-non-tls"
}

If (-not ${aioMqEndpointIp} -and -not ${aioMqEndpointHostname}) {
    Throw "Failed to detect the AIO MQ endpoint."
    Exit 1
}

Write-Host "AIO MQ endpoint: ${aioMqEndpoint}"
Out-File -FilePath (Join-Path -Path $PSScriptRoot -ChildPath ".config_aio_mq_endpoint") -InputObject $aioMqEndpoint -NoNewline

Write-Host "AIO MQ host: ${aioMqHost}"
Out-File -FilePath (Join-Path -Path $PSScriptRoot -ChildPath ".config_aio_mq_host") -InputObject $aioMqHost -NoNewline

Write-Host "AIO MQ port: ${aioMqPort}"
Out-File -FilePath (Join-Path -Path $PSScriptRoot -ChildPath ".config_aio_mq_port") -InputObject $aioMqPort -NoNewline

Write-Host "Done!`n"
