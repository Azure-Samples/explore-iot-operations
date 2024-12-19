<#
.SYNOPSIS
	Deploy an open (non-TLS) broker listener into the default Kubernetes cluster.
.DESCRIPTION
	This PowerShell script deploys an open (non-TLS) broker listener into the default Kubernetes cluster using kubectl.
.LINK
    https://azure.com/
.NOTES
    (c) 2024 Microsoft Corporation. All rights reserved.
	Author: andrejm@microsoft.com
#>

try {
    & kubectl apply -f broker-listener.yaml --validate=false
	exit 0 # success
} catch {
	"⚠️ Error in line $($_.InvocationInfo.ScriptLineNumber): $($Error[0])"
	exit 1
}
