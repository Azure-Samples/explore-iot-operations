#!/bin/bash
# Deploy MQTT-based assets for spaceship factory

set -e

echo "=== Deploying MQTT Asset Endpoint Profile ==="
kubectl apply -f mqtt-asset-endpoint.yaml

echo ""
echo "=== Deploying Example Asset ==="
kubectl apply -f mqtt-asset-example.yaml

echo ""
echo "=== Verifying Deployment ==="
kubectl get assetendpointprofiles -n azure-iot-operations
kubectl get assets -n azure-iot-operations

echo ""
echo "=== Enable Resource Sync (if not already enabled) ==="
echo "Run: az iot ops enable-rsync --name <instance-name> --resource-group <resource-group>"

echo ""
echo "=== Next Steps ==="
echo "1. Wait 2-3 minutes for resources to sync to Azure"
echo "2. Go to Azure Portal → Your IoT Operations Instance → Assets"
echo "3. You should see 'spaceship-assembly-line-1' in the Assets list"
echo "4. Create additional assets by modifying mqtt-asset-example.yaml"
echo ""
echo "Note: MQTT assets are NOT auto-discovered. You must create them manually"
echo "or via manifests like the examples provided."

echo ""
echo "=== Checking Azure IoT Operations Status ==="
az iot ops check

echo ""
echo "=== Checking Resource Sync (rsync) Status ==="
echo "Checking if assets are syncing to Azure..."

# Get the IoT Operations instance name from the cluster
INSTANCE_NAME=$(kubectl get pods -n azure-iot-operations -l app.kubernetes.io/name=aio-orc-operator -o jsonpath='{.items[0].metadata.ownerReferences[0].name}' 2>/dev/null || echo "")

if [ -z "$INSTANCE_NAME" ]; then
    echo "⚠️  Could not auto-detect IoT Operations instance name"
    echo "   Manually check rsync status with:"
    echo "   az iot ops asset query --instance <instance-name> -g <resource-group>"
else
    echo "   Detected instance: $INSTANCE_NAME"
fi

# Check if rsync pods are running
echo ""
echo "Checking rsync-related pods:"
kubectl get pods -n azure-iot-operations | grep -E "aio-orc|resource-sync" || echo "   No rsync pods found with expected names"

# Check the synced status on the asset
echo ""
echo "Checking asset sync status:"
ASSET_STATUS=$(kubectl get asset spaceship-assembly-line-1 -n azure-iot-operations -o jsonpath='{.status.syncStatus}' 2>/dev/null || echo "not-available")
echo "   Asset sync status: $ASSET_STATUS"

if [ "$ASSET_STATUS" = "not-available" ]; then
    echo "   ℹ️  Sync status not yet reported (this is normal initially)"
fi

echo ""
echo "To verify assets appear in Azure Portal:"
echo "1. Azure Portal → IoT Operations → Your Instance"
echo "2. Navigate to 'Assets' section"
echo "3. Look for 'spaceship-assembly-line-1'"
echo ""
echo "If assets don't appear after 5 minutes, check:"
echo "• kubectl logs -n azure-iot-operations -l app.kubernetes.io/name=aio-orc-operator"
echo "• Ensure RBAC permissions are configured correctly"