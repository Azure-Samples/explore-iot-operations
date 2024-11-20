<#
.SYNOPSIS
	Deletes an open (non-TLS) broker listener from the default Kubernetes cluster.
.DESCRIPTION
	This PowerShell script deletes an open (non-TLS) broker listener from the default Kubernetes cluster using kubectl.
.LINK
    https://azure.com/
.NOTES
    (c) 2024 Microsoft Corporation. All rights reserved.
	Author: andrejm@microsoft.com
#>

try {
	& kubectl delete -f broker-listener.yaml
	exit 0 # success
} catch {
	"⚠️ Error in line $($_.InvocationInfo.ScriptLineNumber): $($Error[0])"
	exit 1
}
