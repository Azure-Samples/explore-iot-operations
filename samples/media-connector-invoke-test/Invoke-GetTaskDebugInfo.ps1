<#
    Get the task debug info
#>
param (
    [Parameter(
        HelpMessage="AIO namespace.")]
    [string]$aioNamespace = (Get-Content -Path (Join-Path -Path $PSScriptRoot -ChildPath .aio_namespace) -Raw),
    [Parameter(
        HelpMessage="Asset name.")]
    [string]$assetName,
    [Parameter(
        HelpMessage="Datapoint name.")]
    [string]$datapointName
)

$mrpcTopic = "$aioNamespace/asset-operations/${assetName}/get-task-debug-info"

$mrpcResponseTopic = "$mrpcTopic/response"

$mrpcPayload = "{`"datapoint`":`"${datapointName}`"}"

. (Join-Path -Path $PSScriptRoot -ChildPath "Invoke-mRPC.ps1") -mrpcTopic $mrpcTopic -mrpcResponseTopic $mrpcResponseTopic -mrpcPayload $mrpcPayload
