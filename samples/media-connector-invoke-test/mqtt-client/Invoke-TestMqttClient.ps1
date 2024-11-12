Write-Host "Media Connector mRPC API test`n"

Write-Host "mRPC is an MQTTv5 based RPC protocol. It uses MQTT as the transport layer and JSON as the payload. You can use any standard MQTTv5 client to interact with the mRPC API.`n"

Write-Host "The media client used is based on the AIO documentation available here: https://learn.microsoft.com/en-us/azure/iot-operations/manage-mqtt-broker/howto-test-connection`n"

Write-Host "Test the MQTT client container"

$command = @"
mosquitto_pub --host aio-mq-dmqtt-frontend --port 8883 --topic "test/hello" --message "world" --debug --cafile /var/run/certs/ca.crt -D CONNECT authentication-method 'K8S-SAT' -D CONNECT authentication-data `$(cat /var/run/secrets/tokens/mq-sat)
"@
Write-Host "COMMAND: $command"
kubectl exec mqtt-client --namespace azure-iot-operations -- sh -c $command
