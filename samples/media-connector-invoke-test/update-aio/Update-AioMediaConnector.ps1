#Requires -Version 7
<#
    Uninstall a resource file.
#>
param (
    [Parameter(
        Mandatory=$true,
        HelpMessage="The cluster resource group.")]
    [string]$clusterResourceGroup,
    [Parameter(
        Mandatory=$true,
        HelpMessage="The cluster name.")]
    [string]$clusterName,
    [Parameter(
        HelpMessage="The media connector version to use.")]
    [string]$mediaConnectorVersion = "1.1.0"
)

$extension = az k8s-extension list `
        --cluster-name $clusterName `
        --cluster-type connectedClusters `
        --resource-group $clusterResourceGroup `
        --query "[?extensionType == 'microsoft.iotoperations']" `
    | ConvertFrom-Json

az k8s-extension update `
    --version $extension.version `
    --name $extension.name `
    --release-train $extension.releaseTrain `
    --cluster-name $clusterName `
    --resource-group $clusterResourceGroup `
    --cluster-type connectedClusters `
    --auto-upgrade-minor-version false `
    --config connectors.image.registry=mcr.microsoft.com `
    --config connectors.image.repository=aio-connectors/helmchart/microsoft-aio-connectors `
    --config connectors.image.tag=$mediaConnectorVersion `
    --config connectors.values.enablePreviewFeatures=true `
    --yes
