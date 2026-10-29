#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: bash deploy.sh <render|replay|deploy|enable|disable> [config.json]"
}
die() {
  printf '%s\n' "$*" >&2
  exit 1
}

ACTION="${1:-}"
[[ $# -le 2 ]] || die "Expected an action and an optional configuration path"
case "$ACTION" in
  render|replay|deploy|enable|disable) ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
SCRIPT_DIRECTORY=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONFIG="${2:-$SCRIPT_DIRECTORY/config.json}"
for tool in python3 jq; do
  command -v "$tool" >/dev/null || die "Required tool not found: $tool"
done
CONFIG=$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).resolve())' "$CONFIG")
cd "$SCRIPT_DIRECTORY"
python3 render.py "$CONFIG" --validate-only
if [[ "$ACTION" == render ]]; then
  python3 render.py "$CONFIG"
  exit 0
fi
if [[ "$ACTION" == deploy || "$ACTION" == replay ]]; then
  render_arguments=("$CONFIG")
  [[ "$ACTION" != replay ]] || render_arguments+=(--replay)
  python3 render.py "${render_arguments[@]}"
fi

if [[ "$ACTION" != disable ]]; then
  command -v kubectl >/dev/null || die "kubectl is required"
fi
CONTEXT=$(jq -er .kubeContext "$CONFIG")
kubectl_aio() { kubectl --context "$CONTEXT" --namespace azure-iot-operations "$@"; }

check_ownership() {
  local foreign
  foreign=$(kubectl --context "$CONTEXT" get -f "$1" --ignore-not-found -o json |
    jq -r '(.items // [.])[] | select(.metadata.labels["app.kubernetes.io/part-of"] != "edge-inference-sample") |
      "\(.kind)/\(.metadata.name)"')
  [[ -z "$foreign" ]] || die "Refusing to overwrite resources not owned by this sample: $foreign"
}
apply_manifest() {
  check_ownership "$1"
  kubectl --context "$CONTEXT" apply -f "$1"
}

if [[ "$ACTION" == replay ]]; then
  while IFS= read -r scenario; do
    expected="rtsp://edge-replay-$scenario.azure-iot-operations.svc.cluster.local:8554/camera"
    jq -e --arg name "$scenario" --arg address "$expected" \
      '.cameras[$name].address == $address and .cameras[$name].authentication.method == "Anonymous"' \
      "$CONFIG" >/dev/null || die "Camera $scenario must select the anonymous internal replay service"
    apply_manifest ".generated/replay-$scenario.yaml"
    kubectl_aio rollout status "deployment/edge-replay-$scenario" --timeout=180s
  done < <(jq -r '.enabledScenarios[]' "$CONFIG")
  exit 0
fi

command -v az >/dev/null || die "Azure CLI is required"
SUBSCRIPTION=$(jq -er .subscriptionId "$CONFIG")
GROUP=$(jq -er .resourceGroup "$CONFIG")
INSTANCE=$(jq -er .aioInstanceName "$CONFIG")
FOUNDRY_NAMESPACE=$(jq -er .foundryNamespace "$CONFIG")
INSTANCE_ID="/subscriptions/$SUBSCRIPTION/resourceGroups/$GROUP/providers/Microsoft.IoTOperations/instances/$INSTANCE"
API_VERSION=2026-09-03-preview

deploy_arm() {
  local template="$1"
  shift
  az deployment group create --subscription "$SUBSCRIPTION" --resource-group "$GROUP" \
    --name "edge-inference-$template" --template-file "bicep/$template.bicep" \
    --parameters "@.generated/$template.parameters.json" "$@" --only-show-errors --output none
}
check_models_and_cameras() {
  local scenario model asset
  while IFS= read -r scenario; do
    model=$(jq -er --arg name "$scenario" '.[] | select(.name == $name) | .modelName' scenarios.json)
    asset=$(jq -er --arg name "$scenario" '.[] | select(.name == $name) | .assetName' scenarios.json)
    kubectl --context "$CONTEXT" --namespace "$FOUNDRY_NAMESPACE" wait \
      "modeldeployment/$model" --for=jsonpath='{.status.state}'=Running --timeout=600s
    kubectl_aio get "asset.namespaces.deviceregistry.microsoft.com/$asset" -o json |
      jq -e 'any(.status.streams[]?; .name == "camera-snapshots" and .error == null) and
        any(.status.managementGroups[]?.actions[]?; .name == "ExtractClip" and .error == null)' >/dev/null ||
      die "Camera $asset is not recording or its ExtractClip action has an error; inspect asset status"
  done < <(jq -r '.enabledScenarios[]' "$CONFIG")
}

set_graph_mode() {
  local mode="$1"
  local profile_id="$INSTANCE_ID/dataflowProfiles/edge-inference"
  local graphs scenario stage name
  local stages=(capture inference postprocessing)
  graphs=$(az rest --method get --url \
    "https://management.azure.com$profile_id/dataflowGraphs?api-version=$API_VERSION" \
    --only-show-errors --output json)
  jq -e '.nextLink == null or .nextLink == ""' <<< "$graphs" >/dev/null ||
    die "Graph listing is paginated; inspect the complete profile before changing modes"
  jq -e '.value | length > 0 and all(.[];
    .name | split("/") | last | test("^(pcb-quality|equipment-area)-(capture|inference|postprocessing)$"))' \
    <<< "$graphs" >/dev/null ||
    die "The edge-inference profile is empty or contains unfamiliar graphs; inspect it before changing modes"
  if [[ "$mode" == Enabled ]]; then
    stages=(postprocessing inference capture)
    while IFS= read -r scenario; do
      for stage in "${stages[@]}"; do
        jq -e --arg name "$scenario-$stage" \
          'any(.value[]; (.name | split("/") | last) == $name)' <<< "$graphs" >/dev/null ||
          die "Graph $scenario-$stage is missing; deploy the selected scenarios before enabling"
      done
    done < <(jq -r '.enabledScenarios[]' "$CONFIG")
  fi
  for stage in "${stages[@]}"; do
    while IFS= read -r name; do
      scenario="${name%-"$stage"}"
      if [[ "$mode" == Enabled ]] &&
        ! jq -e --arg name "$scenario" '.enabledScenarios | index($name) != null' "$CONFIG" >/dev/null; then
        continue
      fi
      az resource update --subscription "$SUBSCRIPTION" \
        --ids "$profile_id/dataflowGraphs/$name" --api-version "$API_VERSION" \
        --include-response-body true --set "properties.mode=$mode" --only-show-errors --output none
    done < <(jq -r --arg suffix "-$stage" \
      '.value[].name | split("/") | last | select(endswith($suffix))' <<< "$graphs")
  done
  printf '%s\n' "Requested $mode for sample data flow graphs."
}

if [[ "$ACTION" == enable || "$ACTION" == disable ]]; then
  if [[ "$ACTION" == enable ]]; then
    check_models_and_cameras
    kubectl_aio rollout status deployment/edge-inference-observer --timeout=120s
    set_graph_mode Enabled
  else
    set_graph_mode Disabled
  fi
  exit 0
fi

az resource show --subscription "$SUBSCRIPTION" --ids "$INSTANCE_ID" \
  --api-version "$API_VERSION" --only-show-errors --output none
definitions=$(az rest --method get --url \
  "https://management.azure.com$INSTANCE_ID/aioApplicationDefinitions?api-version=$API_VERSION" \
  --only-show-errors --output json)
other_inference=$(jq -r '.value[] | select(.name != "edge-inference") |
  select((.properties.imageDetails.imageName // "" | contains("inference-connector")) or
    (.name | contains("inference"))) | .name' <<< "$definitions")
[[ -z "$other_inference" ]] ||
  die "An inference application already exists: $other_inference. Merge models into it; do not deploy another executor."

data_claim=$(jq -er .dataClaimName "$CONFIG")
state_claim=$(jq -er .stateClaimName "$CONFIG")
kubectl_aio get "pvc/$data_claim" -o json | jq -e '.spec.accessModes | index("ReadWriteMany") != null' >/dev/null ||
  die "The shared data PVC must support ReadWriteMany"
kubectl_aio get "pvc/$state_claim" >/dev/null
kubectl_aio get "secret/$(jq -er .foundryTrustSecret "$CONFIG")" -o json |
  jq -e '.data["ca.crt"] != null' >/dev/null || die "Foundry trust Secret must contain ca.crt"
kubectl_aio get "secret/$(jq -er .imagePullSecret "$CONFIG")" -o json |
  jq -e '(.type == "kubernetes.io/dockerconfigjson" and .data[".dockerconfigjson"] != null) or
    (.type == "kubernetes.io/dockercfg" and .data[".dockercfg"] != null)' >/dev/null ||
  die "The observer image pull Secret must contain Kubernetes registry credentials"
kubectl_aio get configmap/azure-iot-operations-aio-ca-trust-bundle >/dev/null
kubectl --context "$CONTEXT" --namespace "$FOUNDRY_NAMESPACE" \
  get "secret/$(jq -er .modelRegistrySecret "$CONFIG")" -o json |
  jq -e '.data.username != null and .data.password != null' >/dev/null ||
  die "The Foundry model registry Secret must contain username and password keys"
az resource show --subscription "$SUBSCRIPTION" \
  --ids "$INSTANCE_ID/registryEndpoints/$(jq -er .graphRegistryEndpointName "$CONFIG")" \
  --api-version "$API_VERSION" --only-show-errors --output none

template_name=$(jq -er .mediaTemplateName "$CONFIG")
templates=$(kubectl_aio get connectortemplates.akri.iotoperations.azure.com -o json)
matching=$(jq '[.items[] | select(any(.spec.deviceInboundEndpointTypes[]?; .endpointType == "Microsoft.Media"))]' <<< "$templates")
count=$(jq length <<< "$matching")
reuse=$(jq -r .useExistingMediaTemplate "$CONFIG")
if [[ "$reuse" == true ]]; then
  [[ "$count" == 1 ]] || die "Exactly one Microsoft.Media template must exist before reusing it"
  jq -e --arg name "$template_name" --arg claim "$data_claim" '
    .[0].metadata.name == $name and
    (.[0].spec.runtimeConfiguration.managedConfigurationSettings |
      .additionalConfiguration.localSharedPath == "/inference-shared/edge-inference/media" and
      any(.persistentVolumeClaims[]?; .claimName == $claim and .mountPath == "/inference-shared"))' \
    <<< "$matching" >/dev/null ||
    die "Existing media template storage does not match. Merge the documented storage settings manually first."
else
  if [[ "$count" != 0 ]]; then
    [[ "$count" == 1 ]] || die "Multiple Microsoft.Media templates exist; resolve the duplicate allocation first."
    jq -e --arg name "$template_name" '.[0].metadata.name == $name and
      .[0].metadata.labels["app.kubernetes.io/part-of"] == "edge-inference-sample"' <<< "$matching" >/dev/null ||
      die "Another Microsoft.Media template exists. Reuse it; never create a second matching template."
  fi
fi

check_ownership .generated/storage-init.yaml
kubectl_aio delete job/edge-inference-storage-init --ignore-not-found
apply_manifest .generated/storage-init.yaml
kubectl_aio wait job/edge-inference-storage-init --for=condition=complete --timeout=180s
[[ "$reuse" == true ]] || apply_manifest .generated/media-template.yaml
while IFS= read -r scenario; do
  apply_manifest ".generated/camera-$scenario.yaml"
done < <(jq -r '.enabledScenarios[]' "$CONFIG")

deploy_arm definition
definition_id="$INSTANCE_ID/aioApplicationDefinitions/edge-inference"
ready=false
for ((attempt=0; attempt<60; attempt++)); do
  state=$(az resource show --subscription "$SUBSCRIPTION" --ids "$definition_id" \
    --api-version "$API_VERSION" --query properties.provisioningState --output tsv --only-show-errors)
  if [[ "$state" == Succeeded ]]; then
    ready=true
    break
  fi
  [[ "$state" != Failed ]] || die "Application definition failed provisioning"
  sleep 5
done
[[ "$ready" == true ]] || die "Application definition did not become ready within five minutes"
deploy_arm connector
while IFS= read -r scenario; do
  apply_manifest ".generated/model-$scenario.yaml"
done < <(jq -r '.enabledScenarios[]' "$CONFIG")
apply_manifest .generated/scenarios-configmap.json
apply_manifest .generated/collector.yaml
apply_manifest .generated/response-cleanup.yaml
deploy_arm dataflows
check_models_and_cameras
kubectl_aio rollout status deployment/edge-inference-observer --timeout=180s
printf '%s\n' "Resources deployed with data flows DISABLED. Continue with the deployment and first-inspection steps in README.md, then run: bash deploy.sh enable $CONFIG"
