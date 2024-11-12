Write-Host "Installing the MQTT client container"

Write-Host "Create the service account"

. kubectl create serviceaccount mqtt-client -n azure-iot-operations

Write-Host "Deploy the MQTT client container to the cluster"

. kubectl apply -f mqtt-client.yaml
