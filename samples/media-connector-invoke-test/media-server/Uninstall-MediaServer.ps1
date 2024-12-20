<#
.SYNOPSIS
	Deploy MediaMTX into the default Kubernetes cluster.
.DESCRIPTION
	This PowerShell script deploys MediaMTX into the default Kubernetes cluster using kubectl.
.EXAMPLE
	PS> ./media-server-delete.ps1
.LINK
    https://azure.com/
.NOTES
    (c) 2024 Microsoft Corporation. All rights reserved.
	Author: andrejm@microsoft.com
#>

try {
	& kubectl delete -f media-server-service-public.yaml
	& kubectl delete -f media-server-service.yaml
	& kubectl delete -f media-server-deployment.yaml
	& kubectl delete namespace media-server
	exit 0 # success
} catch {
	"⚠️ Error in line $($_.InvocationInfo.ScriptLineNumber): $($Error[0])"
	exit 1
}
