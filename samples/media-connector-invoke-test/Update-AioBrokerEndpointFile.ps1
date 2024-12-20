#Requires -Version 7
<#
    Update the AIO Broker endpoint file.
#>

$aioNamespace = (Get-Content -Path (Join-Path -Path $PSScriptRoot -ChildPath .config_aio_namespace) -Raw).Trim()
Write-Host "AIO connectors namespace: ${aioNamespace}"

$aioMqPort=1883 # Default MQTT port

Function Detect-Broker {
    Param (
        [string]$serviceName
    )

    Write-Host "Detecting the AIO Broker endpoint with service name $serviceName..."

    $aioMqEndpointIp=(kubectl get service $serviceName `
        --namespace ${aioNamespace} `
        --output jsonpath='{.status.loadBalancer.ingress[0].ip}')
    If (${aioMqEndpointIp}) {
        Write-Host "AIO Broker endpoint IP: ${aioMqEndpointIp}"

        $aioMqPort=(kubectl get service $serviceName `
            --namespace ${aioNamespace} `
            --output jsonpath='{.spec.ports[0].port}')
        Write-Host "AIO Broker port: ${aioMqPort}"

        $aioMqEndpoint="mqtt://${aioMqEndpointIp}:${aioMqPort}"
        $aioMqHost=$aioMqEndpointIp
    } Else {
        $aioMqEndpointHostname=(kubectl get service $serviceName `
            --namespace ${aioNamespace} `
            --output jsonpath='{.status.loadBalancer.ingress[0].hostname}')
        If (${aioMqEndpointHostname}) {
            Write-Host "AIO Broker endpoint hostname: ${aioMqEndpointHostname}"

            $aioMqPort=(kubectl get service $serviceName `
                --namespace ${aioNamespace} `
                --output jsonpath='{.spec.ports[0].port}')

            $aioMqEndpoint="mqtt://${aioMqEndpointHostname}:${aioMqPort}"
            $aioMqHost=$aioMqEndpointHostname
        }
    }
}

$endpointNames = @(
    "aio-broker",
    "aio-broker-listener-non-tls",
    "aio-broker-notls"
)

ForEach ($endpointName in $endpointNames) {

    . Detect-Broker -serviceName $endpointName

    If (${aioMqEndpointIp} -or ${aioMqEndpointHostname}) {
        Write-Host "AIO Broker endpoint detected!"
        Break
    }
}

If (-not ${aioMqEndpointIp} -and -not ${aioMqEndpointHostname}) {
    Throw "Failed to detect the AIO Broker endpoint."
    Exit 1
}

Write-Host "AIO Broker endpoint: ${aioMqEndpoint}"
Out-File -FilePath (Join-Path -Path $PSScriptRoot -ChildPath ".config_aio_broker_endpoint") -InputObject $aioMqEndpoint -NoNewline

Write-Host "AIO Broker host: ${aioMqHost}"
Out-File -FilePath (Join-Path -Path $PSScriptRoot -ChildPath ".config_aio_broker_host") -InputObject $aioMqHost -NoNewline

Write-Host "AIO Broker port: ${aioMqPort}"
Out-File -FilePath (Join-Path -Path $PSScriptRoot -ChildPath ".config_aio_broker_port") -InputObject $aioMqPort -NoNewline

Write-Host "Done!`n"
