#Requires -Version 7
<#
    Start a an MQTT listener using mosquitto_sub.
#>
param (
    [Parameter(
        HelpMessage="The listen topic.")]
    [string[]]$listenTopics = @(),
    [Parameter(
        HelpMessage="The format string to be used to print messages.")]
    [string]$printFormat = "Topic [%t], ID [%m], QoS [%q], Retain [%r], Size [%l]"
)

Write-Host (Split-Path -Path $PSCommandPath -Leaf).ToUpper() -ForegroundColor White

. (Join-Path $PSScriptRoot "Test-Prerequisites.ps1")

. (Join-Path $PSScriptRoot "Update-AioBrokerEndpointFile.ps1")

$aioNamespace = (Get-Content -Path (Join-Path $PSScriptRoot ".config_aio_namespace") -Raw).Trim()
Write-Host "AIO namespace: $aioNamespace"

$aioMqHost = (Get-Content -Path (Join-Path $PSScriptRoot ".config_aio_broker_host") -Raw).Trim()
Write-Host "AIO MQ host: $aioMqHost"

$aioMqPort = (Get-Content -Path (Join-Path $PSScriptRoot ".config_aio_broker_port") -Raw).Trim()
Write-Host "AIO MQ port: $aioMqPort"

If ($listenTopics.Count -eq 0) {
    $listenTopics = @("${aioNamespace}/#")
}
Write-Host "listenTopics: $listenTopics"

Write-Host "printFormat: $printFormat"

ForEach ($listenTopic in $listenTopics) {
    $listenTopicParams += " -t `"${listenTopic}`" "
}

try {
    Write-Host "Starting the mosquitto_sub process..."
    $commandString = "mosquitto_sub --host $aioMqHost --port $aioMqPort --verbose -V mqttv5 -F `"${printFormat}`" ${listenTopicParams}"
    Invoke-Expression "${commandString}"
} finally {
    Write-Host "`nThe mosquitto_sub process ended."
}
