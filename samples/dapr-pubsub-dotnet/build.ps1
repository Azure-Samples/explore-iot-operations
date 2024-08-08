param (
    [Parameter(Mandatory=$True)]
    [string]$Version

    [Parameter(Mandatory=$True)]
    [string]$ContainerRegistry
)

docker build .\src\TelemetryProcessor\TelemetryTransformer\. -f .\src\TelemetryProcessor\TelemetryTransformer\Dockerfile -t telemetrytransformer:$Version
docker build .\src\TelemetryProcessor\TelemetryPersister\. -f .\src\TelemetryProcessor\TelemetryPersister\Dockerfile -t telemetrypersister:$Version

docker tag telemetrypersister:$Version $ContainerRegistry/explore-iot-operations/samples/dapr-pubsub-dotnet/telemetrypersister:$Version
docker tag telemetrytransformer:$Version $ContainerRegistry/explore-iot-operations/samples/dapr-pubsub-dotnet/telemetrytransformer:$Version

docker push $ContainerRegistry/explore-iot-operations/samples/dapr-pubsub-dotnet/telemetrypersister:$Version
docker push $ContainerRegistry/explore-iot-operations/samples/dapr-pubsub-dotnet/telemetrytransformer:$Version