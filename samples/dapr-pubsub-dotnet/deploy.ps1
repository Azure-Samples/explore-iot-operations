param (    
    [Parameter(Mandatory=$True)]
    [string]$ContainerRegistry,

    [Parameter(Mandatory=$True)]
    [string]$Version
)

$contents = (Get-Content .\deploy\telemetryprocessor.yaml) -Replace '#{container_registry}#', $ContainerRegistry

$contents = $contents -replace '#{image_version}#', $Version

$contents | kubectl apply -n azure-iot-operations -f -