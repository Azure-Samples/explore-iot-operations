#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ACTION="${1:?Usage: ./deploy.sh ACTION CONFIG.json}"
CONFIG="${2:?Usage: ./deploy.sh ACTION CONFIG.json}"
CONFIG="$(realpath "$CONFIG")"
case "$ACTION" in
    preflight|storage|model|definition|connector|camera|flow|reader|enable|disable|status) ;;
    *) echo "Unknown action: $ACTION" >&2; exit 2 ;;
esac
python "$ROOT/render.py" "$CONFIG"
SUBSCRIPTION="$(jq -er '.subscriptionId' "$CONFIG")"
GROUP="$(jq -er '.resourceGroup' "$CONFIG")"
INSTANCE="$(jq -er '.aioInstanceName' "$CONFIG")"
CONTEXT="$(jq -er '.kubeContext' "$CONFIG")"
MODEL="$(jq -er '.modelName' "$CONFIG")"
FOUNDRY="$(jq -er '.foundryNamespace' "$CONFIG")"
CLAIM="$(jq -er '.dataClaimName' "$CONFIG")"
NAMESPACE=azure-iot-operations
APP_ID="/subscriptions/$SUBSCRIPTION/resourceGroups/$GROUP/providers/Microsoft.IoTOperations/instances/$INSTANCE/aioApplicationDefinitions/edge-predictive-inference"

fail() { echo "$*" >&2; exit 1; }
k() { kubectl --context "$CONTEXT" --request-timeout=30s "$@"; }
arm() {
    local template="$1"
    shift
    az deployment group create --subscription "$SUBSCRIPTION" --resource-group "$GROUP" \
        --name "edge-predictive-$template" --template-file "$ROOT/bicep/$template.bicep" \
        --parameters "@$ROOT/.generated/$template.parameters.json" "$@" \
        --only-show-errors --output none
}
state() {
    az resource show --subscription "$SUBSCRIPTION" --ids "$1" \
        --api-version 2026-09-03-preview --query properties.provisioningState --output tsv
}
require_connector_slot() {
    local workloads
    workloads="$(k get deployments,statefulsets -n "$NAMESPACE" -o json |
        jq -r '.items[] | select(any(.spec.template.spec.containers[]?;
            .image | test("(^|/)inference-connector(:|@|$)"))) | .metadata.name')"
    [[ -z "$workloads" ]] || fail \
        "An inference connector already exists: $workloads. Do not deploy a second connector. Use a separate instance or have its owner merge this model and volume configuration. This first-install helper also refuses to replace an already running sample connector."
}
require_owned_or_absent() {
    local existing
    existing="$(k get "$1" "$2" -n "$3" --ignore-not-found -o json)"
    if [[ -n "$existing" ]]; then
        jq -e '.metadata.labels["app.kubernetes.io/part-of"] == "edge-predictive-inference"' \
            <<<"$existing" >/dev/null || fail "Refusing to overwrite unrelated $1/$2 in $3"
    fi
}

case "$ACTION" in
    preflight)
        k get namespace "$NAMESPACE" "$FOUNDRY" >/dev/null
        k get storageclass "$(jq -er '.storageClassName' "$CONFIG")" >/dev/null
        k get registryendpoint default -n "$NAMESPACE" -o json |
            jq -e '.spec.host == "mcr.microsoft.com"' >/dev/null ||
            fail "The default registry endpoint must resolve mcr.microsoft.com"
        k get registryendpoint "$(jq -er '.registryEndpointName' "$CONFIG")" -n "$NAMESPACE" -o json |
            jq -e --arg host "$(jq -er '.registry' "$CONFIG")" '.spec.host == $host' >/dev/null ||
            fail "The sample registry endpoint must resolve the configured registry"
        k get connectortemplates -n "$NAMESPACE" -o json |
            jq -e '[.items[] | select(any(.spec.deviceInboundEndpointTypes[]?;
                .endpointType == "Microsoft.Media"))] | length == 1' >/dev/null ||
            fail "Install exactly one compatible Microsoft.Media connector template first"
        k get secret "$(jq -er '.foundryTrustSecret' "$CONFIG")" -n "$NAMESPACE" -o json |
            jq -e '.data["ca.crt"] != null' >/dev/null ||
            fail "The Foundry trust Secret must contain ca.crt"
        k get secret "$(jq -er '.modelRegistrySecret' "$CONFIG")" -n "$FOUNDRY" -o json |
            jq -e '.data.username != null and .data.password != null' >/dev/null ||
            fail "The model registry Secret needs username and password keys"
        require_owned_or_absent persistentvolumeclaim "$CLAIM" "$NAMESPACE"
        require_owned_or_absent modeldeployment "$MODEL" "$FOUNDRY"
        require_connector_slot
        oras manifest fetch --descriptor \
            mcr.microsoft.com/azureiotoperations/graph-dataflow-inference:0.2.0-preview.0 |
            jq -e '.digest == "sha256:4a3ca352ad900e459785674c3a2648c9b5a1f73583e8dbdb73c653471704c52d"' \
                >/dev/null || fail "The Microsoft inference graph differs from the selected 0.2 contract"
        echo "First-install checks passed. Also confirm AIO Apps support, Foundry audience aio-internal, registry pull authorization, camera secret synchronization, and shared-storage permissions."
        ;;
    storage)
        require_owned_or_absent persistentvolumeclaim "$CLAIM" "$NAMESPACE"
        require_owned_or_absent job edge-predictive-storage-init "$NAMESPACE"
        k apply -f "$ROOT/.generated/storage.yaml"
        k wait -n "$NAMESPACE" --for=condition=Complete job/edge-predictive-storage-init --timeout=180s
        k get pvc "$CLAIM" -n "$NAMESPACE" -o json |
            jq -e '.status.phase == "Bound" and (.spec.accessModes | index("ReadWriteMany") != null)' \
                >/dev/null || fail "The data claim must be Bound with ReadWriteMany"
        require_owned_or_absent cronjob edge-predictive-cleanup "$NAMESPACE"
        k apply -f "$ROOT/.generated/cleanup.yaml"
        ;;
    model)
        require_owned_or_absent modeldeployment "$MODEL" "$FOUNDRY"
        k apply --dry-run=server -f "$ROOT/.generated/model.yaml"
        k apply -f "$ROOT/.generated/model.yaml"
        echo "Wait for the model to be ready and verify its HTTPS base endpoint before deploying the connector."
        ;;
    definition)
        require_connector_slot
        arm definition
        for attempt in {1..30}; do
            current="$(state "$APP_ID")"
            [[ "$current" != Failed && "$current" != Canceled ]] ||
                fail "Application definition state: $current"
            if [[ "$current" == Succeeded ]]; then
                echo "Application definition is ready."
                exit 0
            fi
            echo "Application definition state: $current (attempt $attempt/30)"
            sleep 10
        done
        fail "Timed out waiting for the application definition; inspect it before continuing"
        ;;
    connector)
        require_connector_slot
        [[ "$(state "$APP_ID")" == Succeeded ]] || fail "Application definition is not ready"
        arm connector
        echo "Application configuration submitted. Check the connector workload and Foundry readiness."
        ;;
    camera) arm camera ;;
    flow) arm dataflow ;;
    reader)
        require_owned_or_absent serviceaccount edge-predictive-reader "$NAMESPACE"
        require_owned_or_absent pod edge-predictive-reader "$NAMESPACE"
        k apply -f "$ROOT/.generated/reader.yaml"
        k wait -n "$NAMESPACE" --for=condition=Ready pod/edge-predictive-reader --timeout=120s
        ;;
    enable)
        arm dataflow mode=Enabled
        arm camera enabled=true
        echo "Enable requests submitted. Verify JPEGs and real observations before treating the pipeline as ready."
        ;;
    disable)
        arm camera enabled=false
        arm dataflow mode=Disabled
        echo "Disable requests submitted. Confirm runtime reconciliation before deleting resources."
        ;;
    status)
        k get modeldeployment "$MODEL" -n "$FOUNDRY" -o yaml
        k get dataflowprofile edge-predictive-inference -n "$NAMESPACE" -o yaml
        k get dataflowgraph edge-person-detection -n "$NAMESPACE" -o yaml
        k get pvc "$CLAIM" -n "$NAMESPACE"
        state "$APP_ID/aioApplicationConfigurations/edge-predictive-inference"
        ;;
esac
