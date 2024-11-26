<#
.SYNOPSIS
	Deploy MediaMTX into the default Kubernetes cluster.
.DESCRIPTION
	This PowerShell script deploys MediaMTX into the default Kubernetes cluster using kubectl.
.EXAMPLE
	PS> ./media-server-deploy.ps1
	namespace/media-server created
	deployment.apps/media-server created
	service/media-server created
	service/media-server-public created
.LINK
    https://azure.com/
.NOTES
    (c) 2024 Microsoft Corporation. All rights reserved.
	Author: andrejm@microsoft.com
#>

try {
    & kubectl create namespace media-server --dry-run=client -o yaml | kubectl apply -f -
    & kubectl apply -f media-server-deployment.yaml --validate=false
    & kubectl apply -f media-server-service.yaml --validate=false
    & kubectl apply -f media-server-service-public.yaml --validate=false
	exit 0 # success
} catch {
	"⚠️ Error in line $($_.InvocationInfo.ScriptLineNumber): $($Error[0])"
	exit 1
}
