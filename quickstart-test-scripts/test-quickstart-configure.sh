#!/bin/bash
# Test script for quickstart-configure.md
# Verifies the steps in "Quickstart: Configure your cluster"
# Stops on first failure and reports status.

set -euo pipefail

# ── Helpers ──────────────────────────────────────────────────────────────────

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

step() { echo -e "\n${YELLOW}>>> $1${NC}"; }
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
info() { echo -e "${CYAN}[INFO]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }

trap 'fail "Script failed at line $LINENO. Last command exit code: $?"' ERR

# ── Collect inputs ────────────────────────────────────────────────────────────

echo "========================================"
echo " Azure IoT Operations quickstart tester"
echo " (quickstart-configure.md)"
echo "========================================"
echo
echo "Enter required values. Press Enter to accept an existing environment variable."
echo

prompt_var() {
    local varname="$1"
    local prompt="$2"
    local current="${!varname:-}"
    if [[ -n "$current" ]]; then
        read -rp "${prompt} [${current}]: " input
        export "$varname"="${input:-$current}"
    else
        read -rp "${prompt}: " input
        [[ -z "$input" ]] && fail "${varname} is required."
        export "$varname"="$input"
    fi
}

prompt_var SUBSCRIPTION_ID "Azure Subscription ID"
prompt_var RESOURCE_GROUP  "Resource group name"
prompt_var CLUSTER_NAME    "Kubernetes cluster name"

echo
echo "Configuration:"
echo "  SUBSCRIPTION_ID = $SUBSCRIPTION_ID"
echo "  RESOURCE_GROUP  = $RESOURCE_GROUP"
echo "  CLUSTER_NAME    = $CLUSTER_NAME"
echo
read -rp "Proceed? [y/N] " confirm
[[ "${confirm,,}" == "y" ]] || { echo "Aborted."; exit 0; }

# ── Deploy OPC PLC simulator ──────────────────────────────────────────────────

step "Deploying OPC PLC simulator"
kubectl apply -f https://raw.githubusercontent.com/Azure-Samples/explore-iot-operations/main/samples/quickstarts/opc-plc-deployment.yaml
ok "OPC PLC simulator deployed"

# ── Configure the cluster ─────────────────────────────────────────────────────

step "Downloading quickstart.bicep"
wget https://raw.githubusercontent.com/Azure-Samples/explore-iot-operations/main/samples/quickstarts/quickstart.bicep -O quickstart.bicep
ok "quickstart.bicep downloaded"

step "Resolving AIO extension name"
AIO_EXTENSION_NAME=$(az k8s-extension list \
    -g "$RESOURCE_GROUP" \
    --cluster-name "$CLUSTER_NAME" \
    --cluster-type connectedClusters \
    --query "[?extensionType == 'microsoft.iotoperations'].id" \
    -o tsv | awk -F'/' '{print $NF}')
[[ -z "$AIO_EXTENSION_NAME" ]] && fail "Could not resolve AIO_EXTENSION_NAME. Is Azure IoT Operations deployed on the cluster?"
ok "AIO_EXTENSION_NAME=$AIO_EXTENSION_NAME"

step "Resolving AIO instance name"
AIO_INSTANCE_NAME=$(az iot ops list -g "$RESOURCE_GROUP" --query "[0].name" -o tsv)
[[ -z "$AIO_INSTANCE_NAME" ]] && fail "Could not resolve AIO_INSTANCE_NAME. Is Azure IoT Operations deployed?"
ok "AIO_INSTANCE_NAME=$AIO_INSTANCE_NAME"

step "Resolving custom location name"
CUSTOM_LOCATION_NAME=$(az iot ops list -g "$RESOURCE_GROUP" --query "[0].extendedLocation.name" -o tsv | awk -F'/' '{print $NF}')
[[ -z "$CUSTOM_LOCATION_NAME" ]] && fail "Could not resolve CUSTOM_LOCATION_NAME."
ok "CUSTOM_LOCATION_NAME=$CUSTOM_LOCATION_NAME"

step "Running Bicep deployment (configures device, asset, data flow, Event Hubs)"
az deployment group create \
    --subscription "$SUBSCRIPTION_ID" \
    --resource-group "$RESOURCE_GROUP" \
    --template-file quickstart.bicep \
    --parameters \
        clusterName="$CLUSTER_NAME" \
        customLocationName="$CUSTOM_LOCATION_NAME" \
        aioExtensionName="$AIO_EXTENSION_NAME" \
        aioInstanceName="$AIO_INSTANCE_NAME" \
        aioNamespaceName=myqsnamespace
ok "Bicep deployment complete"

# ── Verify deployed resources ─────────────────────────────────────────────────

step "Verifying device 'opc-ua-connector' exists"
DEVICE_PROV=$(az iot ops ns device show \
    --instance "$AIO_INSTANCE_NAME" \
    --name opc-ua-connector \
    --resource-group "$RESOURCE_GROUP" \
    --query "properties.provisioningState" \
    -o tsv)
[[ -z "$DEVICE_PROV" ]] && fail "Device 'opc-ua-connector' not found"
[[ "$DEVICE_PROV" != "Succeeded" ]] && fail "Device 'opc-ua-connector' provisioning state is '$DEVICE_PROV', expected 'Succeeded'"
ok "Device 'opc-ua-connector' provisioning state: $DEVICE_PROV"

step "Verifying asset 'oven' exists"
ASSET_COUNT=$(az iot ops ns asset query \
    --instance "$AIO_INSTANCE_NAME" \
    --name oven \
    --resource-group "$RESOURCE_GROUP" \
    --query "length(@)" \
    -o tsv)
[[ "$ASSET_COUNT" -lt 1 ]] && fail "Asset 'oven' not found for instance $AIO_INSTANCE_NAME"
ok "Asset 'oven' found ($ASSET_COUNT result(s))"

step "Verifying data flow endpoint 'quickstart-eh-endpoint' exists"
EH_ENDPOINT_STATE=$(az iot ops dataflow endpoint show \
    --resource-group "$RESOURCE_GROUP" \
    --instance "$AIO_INSTANCE_NAME" \
    --name quickstart-eh-endpoint \
    --query "properties.provisioningState" \
    -o tsv)
[[ -z "$EH_ENDPOINT_STATE" ]] && fail "Data flow endpoint 'quickstart-eh-endpoint' not found"
[[ "$EH_ENDPOINT_STATE" != "Succeeded" ]] && fail "Data flow endpoint provisioning state is '$EH_ENDPOINT_STATE', expected 'Succeeded'"
ok "Data flow endpoint 'quickstart-eh-endpoint' provisioning state: $EH_ENDPOINT_STATE"

step "Verifying data flow 'quickstart-oven-data-flow' exists and is enabled"
DF_STATE=$(az iot ops dataflow show \
    --resource-group "$RESOURCE_GROUP" \
    --instance "$AIO_INSTANCE_NAME" \
    --profile default \
    --name quickstart-oven-data-flow \
    --query "{provisioning:properties.provisioningState, mode:properties.mode}" \
    -o json)
DF_PROV=$(echo "$DF_STATE" | python3 -c "import sys,json; print(json.load(sys.stdin)['provisioning'])")
DF_MODE=$(echo "$DF_STATE" | python3 -c "import sys,json; print(json.load(sys.stdin)['mode'])")
[[ "$DF_PROV" != "Succeeded" ]] && fail "Data flow 'quickstart-oven-data-flow' provisioning state is '$DF_PROV', expected 'Succeeded'"
[[ "$DF_MODE" != "Enabled" ]] && fail "Data flow 'quickstart-oven-data-flow' mode is '$DF_MODE', expected 'Enabled'"
ok "Data flow 'quickstart-oven-data-flow' provisioning state: $DF_PROV, mode: $DF_MODE"

# ── Basic post-deployment checks ──────────────────────────────────────────────

step "Checking OPC PLC simulator pod status"
kubectl get pods -l app=opc-plc -A
ok "OPC PLC simulator pod listed"

step "Checking Azure IoT Operations pods"
kubectl get pods -n azure-iot-operations
ok "Pod list retrieved"

step "Verifying Event Hubs namespace exists in resource group"
EH_NAMESPACE=$(az eventhubs namespace list -g "$RESOURCE_GROUP" --query "[0].name" -o tsv)
[[ -z "$EH_NAMESPACE" ]] && fail "No Event Hubs namespace found in resource group $RESOURCE_GROUP"
ok "Event Hubs namespace: $EH_NAMESPACE"

step "Verifying at least one Event Hub exists in the namespace"
EH_HUB=$(az eventhubs eventhub list -g "$RESOURCE_GROUP" --namespace-name "$EH_NAMESPACE" --query "[0].name" -o tsv)
[[ -z "$EH_HUB" ]] && fail "No Event Hub found in namespace $EH_NAMESPACE"
export EH_HUB
ok "Event Hub: $EH_HUB"

# ── Verify messages are flowing to Event Hubs ─────────────────────────────────

step "Installing azure-eventhub Python package"
pip install --quiet azure-eventhub
ok "azure-eventhub installed"

step "Retrieving Event Hubs connection string"
EH_CONNECTION_STRING=$(az eventhubs namespace authorization-rule keys list \
    --resource-group "$RESOURCE_GROUP" \
    --namespace-name "$EH_NAMESPACE" \
    --name RootManageSharedAccessKey \
    --query primaryConnectionString -o tsv)
[[ -z "$EH_CONNECTION_STRING" ]] && fail "Could not retrieve Event Hubs connection string"
export EH_CONNECTION_STRING
ok "Connection string retrieved"

step "Waiting for messages to arrive in Event Hub: $EH_HUB (timeout: 120 s)"
info "The data flow may take a few minutes to start. Waiting up to 120 seconds for at least one message..."

python3 - <<PYEOF
import sys, os, threading
from azure.eventhub import EventHubConsumerClient

CONN_STR  = os.environ["EH_CONNECTION_STRING"]
HUB_NAME  = os.environ["EH_HUB"]
TIMEOUT_S = 120
MAX_MSGS  = 3

received = []

class _StopReceiving(Exception):
    pass

def on_event_batch(partition_context, events):
    for event in events:
        received.append(event.body_as_str(encoding="utf-8"))
    if received:
        raise _StopReceiving()

def on_error(partition_context, error):
    if not isinstance(error, _StopReceiving):
        print(f"Event Hub error: {error}", file=sys.stderr)

client = EventHubConsumerClient.from_connection_string(
    conn_str=CONN_STR,
    consumer_group="\$Default",
    eventhub_name=HUB_NAME,
)

# Ensure we don't hang forever if no messages arrive
timeout_timer = threading.Timer(TIMEOUT_S, client.close)
timeout_timer.start()

print(f"Listening on event hub '{HUB_NAME}' (up to {TIMEOUT_S}s)...")
try:
    with client:
        client.receive_batch(
            on_event_batch=on_event_batch,
            on_error=on_error,
            starting_position="-1",
            max_batch_size=MAX_MSGS,
            max_wait_time=10,
        )
except _StopReceiving:
    pass
except Exception:
    pass  # client was closed by the timeout timer
finally:
    timeout_timer.cancel()

if not received:
    print(f"ERROR: No messages received within {TIMEOUT_S} seconds.", file=sys.stderr)
    sys.exit(1)

print(f"Received {len(received)} message(s). Sample:")
for i, msg in enumerate(received[:MAX_MSGS]):
    print(f"  [{i+1}] {msg[:200]}")
PYEOF

ok "Messages are flowing to Event Hub: $EH_HUB"

# ── Done ──────────────────────────────────────────────────────────────────────

echo
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN} All steps completed successfully!${NC}"
echo -e "${GREEN}========================================${NC}"
echo
info "To view devices, assets, and data flows, visit:"
info "  https://iotoperations.azure.com"
