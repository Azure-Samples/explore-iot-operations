<#
.SYNOPSIS
    Restart the Foundry Local inference operator on the edge cluster.

.DESCRIPTION
    When Foundry Local becomes unresponsive (HTTP 503, timeouts from the agent),
    a pod restart is the fastest recovery path. This script force-restarts the
    inference-operator deployment in the foundry-local-operator namespace.

    Problem solved: The inference container can lock up after a model load
    failure or OOM event. The pod stays Running but requests hang indefinitely.
    A rollout restart triggers a clean pod replacement.

.NOTES
    Requires: kubectl access to the edge cluster.
    Connect first: az connectedk8s proxy -n <cluster-name> -g <resource-group>
#>

$ErrorActionPreference = "Stop"
$Namespace  = "foundry-local-operator"
$Deployment = "inference-operator"

Write-Host "Restarting Foundry Local inference operator..."
kubectl rollout restart deployment/$Deployment -n $Namespace

Write-Host "Waiting for rollout to complete..."
kubectl rollout status deployment/$Deployment -n $Namespace --timeout=120s

Write-Host ""
Write-Host "Current pod status:"
kubectl get pods -n $Namespace
