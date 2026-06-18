<#
.SYNOPSIS
    Force-restart the edgemqttsim deployment.

.DESCRIPTION
    If the factory simulator stops publishing messages (check with mosquitto_sub 
    or mqtt-viewer), a rollout restart usually brings it back without redeploying.

    Problem solved: After cluster events (node restart, network blip) the pod
    can enter a CrashLoopBackOff or simply stop publishing. This is the first
    thing to try before investigating further.

.NOTES
    Requires: kubectl connected to the cluster.
#>

$ErrorActionPreference = "Stop"
$Namespace  = "default"
$Deployment = "edgemqttsim"

Write-Host "Restarting $Deployment in namespace $Namespace..."
kubectl rollout restart deployment/$Deployment -n $Namespace

Write-Host ""
Write-Host "Waiting for rollout to complete..."
kubectl rollout status deployment/$Deployment -n $Namespace --timeout=120s

Write-Host ""
Write-Host "Current pod status:"
kubectl get pods -n $Namespace -l app=$Deployment
