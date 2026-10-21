#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<EOF
Usage: $(basename "$0") --resource-group <rg> --relay-namespace-name <name> \\
  --apim-name <name> --apim-publisher-email <email> --apim-publisher-name <name> [options]

Deploys authenticated APIM -> Azure Relay -> aio-ai-relay access to an existing
Arc-connected AIO cluster. Uses the current kubectl context and Azure subscription.

Required:
  --resource-group <rg>              Existing resource group for Azure resources and the Arc cluster.
  --relay-namespace-name <name>      Azure Relay namespace name.
  --apim-name <name>                 Globally unique API Management name.
  --apim-publisher-email <email>     API Management publisher email.
  --apim-publisher-name <name>       API Management publisher name.

Authentication:
  --auth-mode <sami|sas>             Relay listener authentication. Default: sami.
  --cluster-name <name>              Arc-connected cluster name; required for sami.
  --aio-extension-name <name>        AIO Arc extension name; required for sami.
  --entra-app-name <name>            New Entra application name. Default: aio-ai-relay.
                                      Existing names are rejected; no app is reused or deleted.
  --entra-app-id <client-id>         Use a manually configured existing Entra app; no Graph calls.
  --entra-tenant-id <tenant-id>      Required with --entra-app-id. Both must be GUIDs.
                                      Cannot combine with --entra-app-name or --entra-azure-config-dir.
  --entra-azure-config-dir <dir>     Optional isolated Azure CLI profile for app registration.
                                      Default: current Azure CLI profile. Tenant policies still apply.

Endpoint:
  --endpoint-protocol <mcp|a2a|both>  Default: mcp. "both" installs two Helm releases.
  --endpoint-url <url>               Required for a2a/both; A2A target URL.
  --mcp-frontend-service-name <name> Default: aio-mcp-frontend.
  --mcp-frontend-audience <audience> Default: aio-mcp-frontend (inbound SAT audience).
  --mcp-role <role>                  Optional single MCP Frontend role, e.g. Reader.
                                      No role by default. Applied only to the MCP relay.

Optional:
  --chart-version <version>         Exact published chart version. Default: 0.1.2.
  --chart-reference <oci-reference> Default: oci://ghcr.io/azure-samples/explore-iot-operations/helm/aio-ai-relay.
  --image-tag <tag>                  Relay image tag. Default: 0.1.2.
  --values <file>                    Additional Helm values file, e.g. A2A auth/TLS settings.
  --hybrid-connection-name <name>    Default: hybridconnection; suffixed per protocol for both.
  --apim-sku <sku>                   Default: BasicV2.
  --apim-capacity <number>           Default: 1.
  --k8s-namespace <namespace>        Default: azure-iot-operations.
  --helm-release-name <name>         Default: aio-ai-relay; suffixed per protocol for both.
  -h, --help                        Show this help.

By default the script creates an Entra app with a user_impersonation scope and
AIOMcpAdmin app role. With --entra-app-id, configure these manually, set the
identifier URI to api://<client-id>, and require Enterprise app role assignment.
An administrator must assign callers to that role before API use.
It never enables anonymous APIM access. See README.md for prerequisites and costs.
EOF
}

RESOURCE_GROUP=""
RELAY_NAMESPACE_NAME=""
APIM_NAME=""
APIM_PUBLISHER_EMAIL=""
APIM_PUBLISHER_NAME=""
CHART_VERSION="0.1.2"
CHART_REFERENCE="oci://ghcr.io/azure-samples/explore-iot-operations/helm/aio-ai-relay"
AUTH_MODE="sami"
CLUSTER_NAME=""
AIO_EXTENSION_NAME=""
ENTRA_APP_NAME=""
ENTRA_APP_ID=""
ENTRA_TENANT_ID=""
ENTRA_SP_ID=""
ROLE_ID=""
ENTRA_AZURE_CONFIG_DIR=""
ENTRA_APP_ROLE="AIOMcpAdmin"
ENDPOINT_PROTOCOL="mcp"
ENDPOINT_URL=""
MCP_FRONTEND_SERVICE_NAME="aio-mcp-frontend"
MCP_FRONTEND_AUDIENCE="aio-mcp-frontend"
MCP_ROLE=""
IMAGE_TAG="0.1.2"
VALUES_FILE=""
HYBRID_CONNECTION_NAME="hybridconnection"
APIM_SKU="BasicV2"
APIM_CAPACITY=1
K8S_NAMESPACE="azure-iot-operations"
HELM_RELEASE_NAME="aio-ai-relay"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --resource-group|--relay-namespace-name|--apim-name|--apim-publisher-email|--apim-publisher-name|\
        --chart-version|--chart-reference|--auth-mode|--cluster-name|--aio-extension-name|\
        --entra-app-name|--entra-app-id|--entra-tenant-id|--entra-azure-config-dir|--endpoint-protocol|--endpoint-url|\
        --mcp-frontend-service-name|--mcp-frontend-audience|--mcp-role|--image-tag|--values|\
        --hybrid-connection-name|--apim-sku|--apim-capacity|--k8s-namespace|--helm-release-name)
            if [[ $# -lt 2 || ! "${2:-}" =~ [^[:space:]] || "${2:-}" == --* ]]; then
                echo "Error: $1 requires a non-empty value." >&2
                exit 1
            fi ;;
        *) echo "Error: unknown argument '$1'." >&2; usage >&2; exit 1 ;;
    esac
    case "$1" in
        --resource-group) RESOURCE_GROUP="$2" ;;
        --relay-namespace-name) RELAY_NAMESPACE_NAME="$2" ;;
        --apim-name) APIM_NAME="$2" ;;
        --apim-publisher-email) APIM_PUBLISHER_EMAIL="$2" ;;
        --apim-publisher-name) APIM_PUBLISHER_NAME="$2" ;;
        --chart-version) CHART_VERSION="$2" ;;
        --chart-reference) CHART_REFERENCE="$2" ;;
        --auth-mode) AUTH_MODE="$2" ;;
        --cluster-name) CLUSTER_NAME="$2" ;;
        --aio-extension-name) AIO_EXTENSION_NAME="$2" ;;
        --entra-app-name) ENTRA_APP_NAME="$2" ;;
        --entra-app-id) ENTRA_APP_ID="$2" ;;
        --entra-tenant-id) ENTRA_TENANT_ID="$2" ;;
        --entra-azure-config-dir) ENTRA_AZURE_CONFIG_DIR="$2" ;;
        --endpoint-protocol) ENDPOINT_PROTOCOL="$2" ;;
        --endpoint-url) ENDPOINT_URL="$2" ;;
        --mcp-frontend-service-name) MCP_FRONTEND_SERVICE_NAME="$2" ;;
        --mcp-frontend-audience) MCP_FRONTEND_AUDIENCE="$2" ;;
        --mcp-role) MCP_ROLE="$2" ;;
        --image-tag) IMAGE_TAG="$2" ;;
        --values) VALUES_FILE="$2" ;;
        --hybrid-connection-name) HYBRID_CONNECTION_NAME="$2" ;;
        --apim-sku) APIM_SKU="$2" ;;
        --apim-capacity) APIM_CAPACITY="$2" ;;
        --k8s-namespace) K8S_NAMESPACE="$2" ;;
        --helm-release-name) HELM_RELEASE_NAME="$2" ;;
    esac
    shift 2
done

if [[ -z "$RESOURCE_GROUP" || -z "$RELAY_NAMESPACE_NAME" || -z "$APIM_NAME" || \
      -z "$APIM_PUBLISHER_EMAIL" || -z "$APIM_PUBLISHER_NAME" || -z "$CHART_VERSION" ]]; then
    echo "Error: missing required arguments; see --help." >&2
    exit 1
fi
if [[ -n "$ENTRA_APP_ID" || -n "$ENTRA_TENANT_ID" ]]; then
    guid='[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}'
    if [[ ! "$ENTRA_APP_ID" =~ ^$guid$ || ! "$ENTRA_TENANT_ID" =~ ^$guid$ ]]; then
        echo "Error: --entra-app-id and --entra-tenant-id must both be supplied as GUIDs." >&2
        exit 1
    fi
    if [[ -n "$ENTRA_APP_NAME" || -n "$ENTRA_AZURE_CONFIG_DIR" ]]; then
        echo "Error: existing-app IDs cannot be combined with --entra-app-name or --entra-azure-config-dir." >&2
        exit 1
    fi
fi
case "$AUTH_MODE" in
    sami) BICEP_AUTH_MODE="SystemAssignedManagedIdentity"; CHART_AUTH_METHOD="system-assigned-managed-identity" ;;
    sas) BICEP_AUTH_MODE="SharedAccessSignature"; CHART_AUTH_METHOD="shared-access-signature" ;;
    *) echo "Error: --auth-mode must be sami or sas." >&2; exit 1 ;;
esac
if [[ "$AUTH_MODE" == sami && ( -z "$CLUSTER_NAME" || -z "$AIO_EXTENSION_NAME" ) ]]; then
    echo "Error: --cluster-name and --aio-extension-name are required for sami." >&2
    exit 1
fi
case "$ENDPOINT_PROTOCOL" in
    mcp|a2a|both) ;;
    *) echo "Error: --endpoint-protocol must be mcp, a2a, or both." >&2; exit 1 ;;
esac
if [[ "$ENDPOINT_PROTOCOL" != mcp && -z "$ENDPOINT_URL" ]]; then
    echo "Error: --endpoint-url is required for a2a or both." >&2
    exit 1
fi
if [[ "$ENDPOINT_PROTOCOL" == a2a && -n "$MCP_ROLE" ]]; then
    echo "Error: --mcp-role requires --endpoint-protocol mcp or both." >&2
    exit 1
fi
if [[ "$CHART_REFERENCE" != oci://* || ! "$APIM_CAPACITY" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: --chart-reference must be an OCI URI and --apim-capacity a positive integer." >&2
    exit 1
fi
number='(0|[1-9][0-9]*)'
identifier='(0|[1-9][0-9]*|[0-9]*[a-zA-Z-][0-9a-zA-Z-]*)'
if [[ ! "$CHART_VERSION" =~ ^$number\.$number\.$number(-$identifier(\.$identifier)*)?$ ]] \
    || (( ${#CHART_VERSION} > 128 )); then
    echo "Error: --chart-version must be SemVer without build metadata, at most 128 characters." >&2
    exit 1
fi
if [[ -n "$VALUES_FILE" && ! -f "$VALUES_FILE" ]]; then
    echo "Error: values file not found: $VALUES_FILE" >&2
    exit 1
fi
for cmd in az helm kubectl jq uuidgen; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: required command '$cmd' not found." >&2
        exit 1
    fi
done

az account show --output none
CONTEXT="$(kubectl config current-context)"
echo "==> Deploying to kubectl context '$CONTEXT', namespace '$K8S_NAMESPACE', resource group '$RESOURCE_GROUP'"

WORK_DIR="$(mktemp -d)"
trap 'rm -f -- "$WORK_DIR/aio-ai-relay-$CHART_VERSION.tgz" "$WORK_DIR/a2a-defaults.yaml"; rmdir -- "$WORK_DIR"' EXIT
# Download before creating cloud resources, then use that same local package for both releases.
helm pull "$CHART_REFERENCE" --version "$CHART_VERSION" --destination "$WORK_DIR"
CHART_PACKAGE="$WORK_DIR/aio-ai-relay-$CHART_VERSION.tgz"
if [[ ! -f "$CHART_PACKAGE" ]]; then
    echo "Error: expected an aio-ai-relay chart package at '$CHART_PACKAGE'." >&2
    exit 1
fi
cat > "$WORK_DIR/a2a-defaults.yaml" <<'YAML'
endpoint:
  auth: null
  headers: null
  serviceAccountTokens: null
  trustBundle: ""
  trustBundleConfigMap: ""
YAML

az_entra() {
    if [[ -n "$ENTRA_AZURE_CONFIG_DIR" ]]; then
        AZURE_CONFIG_DIR="$ENTRA_AZURE_CONFIG_DIR" az "$@"
    else
        az "$@"
    fi
}
if [[ -z "$ENTRA_APP_ID" ]]; then
    ENTRA_APP_NAME="${ENTRA_APP_NAME:-aio-ai-relay}"
    if [[ -n "$ENTRA_AZURE_CONFIG_DIR" ]]; then
        mkdir -p "$ENTRA_AZURE_CONFIG_DIR"
    fi
    if ! az_entra account show --output none; then
        echo "Error: sign in to the Entra Azure CLI profile before deployment; tenant policies must allow app registration." >&2
        exit 1
    fi
    ENTRA_TENANT_ID="$(az_entra account show --query tenantId -o tsv)"
    if [[ -z "$ENTRA_TENANT_ID" ]]; then
        echo "Error: could not determine the Entra tenant." >&2
        exit 1
    fi
    EXISTING_APPS="$(az_entra ad app list --display-name "$ENTRA_APP_NAME" -o json)"
    if [[ "$(jq -er 'length' <<< "$EXISTING_APPS")" -gt 0 ]]; then
        echo "Error: an Entra app named '$ENTRA_APP_NAME' already exists. Use a different --entra-app-name." >&2
        exit 1
    fi
    ENTRA_APP_JSON="$(az_entra ad app create --display-name "$ENTRA_APP_NAME" -o json)"
    ENTRA_APP_ID="$(jq -er '.appId | select(type == "string" and length > 0)' <<< "$ENTRA_APP_JSON")"
    echo "==> Created Entra app '$ENTRA_APP_ID' in tenant '$ENTRA_TENANT_ID'; retain this ID for cleanup."
    ENTRA_SP_JSON="$(az_entra ad sp create --id "$ENTRA_APP_ID" -o json)"
    ENTRA_SP_ID="$(jq -er '.id | select(type == "string" and length > 0)' <<< "$ENTRA_SP_JSON")"
    az_entra ad app update --id "$ENTRA_APP_ID" --identifier-uris "api://$ENTRA_APP_ID" --output none
    SCOPE_ID="$(uuidgen)"
    SCOPES="$(jq -cn --arg id "$SCOPE_ID" '[{
    id:$id, adminConsentDescription:"Access the AI relay",
    adminConsentDisplayName:"Access AI relay", isEnabled:true, type:"User",
    userConsentDescription:"Access the AI relay", userConsentDisplayName:"Access AI relay",
    value:"user_impersonation"
}]')"
    az_entra ad app update --id "$ENTRA_APP_ID" --set "api={\"oauth2PermissionScopes\":$SCOPES}" --output none
    ROLE_ID="$(uuidgen)"
    ROLES="$(jq -cn --arg id "$ROLE_ID" --arg role "$ENTRA_APP_ROLE" '[{
    id:$id, allowedMemberTypes:["User","Application"], description:"Access the AI relay API",
    displayName:$role, isEnabled:true, value:$role
}]')"
    az_entra ad app update --id "$ENTRA_APP_ID" --set "appRoles=$ROLES" --output none
    az_entra ad sp update --id "$ENTRA_APP_ID" --set appRoleAssignmentRequired=true --output none
else
    echo "==> Using existing Entra app '$ENTRA_APP_ID' in tenant '$ENTRA_TENANT_ID'; skipping Graph registration."
    echo "    App configuration is not verified. Require role assignment and configure user_impersonation and AIOMcpAdmin manually."
fi

DEPLOYMENT_NAME="ai-relay-$(date +%s)"
BICEP_PARAMS=(
    "authMode=$BICEP_AUTH_MODE"
    "relayNamespaceName=$RELAY_NAMESPACE_NAME"
    "hybridConnectionName=$HYBRID_CONNECTION_NAME"
    "apimName=$APIM_NAME"
    "apimPublisherEmail=$APIM_PUBLISHER_EMAIL"
    "apimPublisherName=$APIM_PUBLISHER_NAME"
    "apimSku=$APIM_SKU"
    "apimCapacity=$APIM_CAPACITY"
    "endpointMode=$ENDPOINT_PROTOCOL"
    "entraAppId=$ENTRA_APP_ID"
    "entraTenantId=$ENTRA_TENANT_ID"
    "entraAppRole=$ENTRA_APP_ROLE"
)
if [[ "$AUTH_MODE" == sami ]]; then
    BICEP_PARAMS+=("clusterName=$CLUSTER_NAME" "aioExtensionName=$AIO_EXTENSION_NAME")
fi
az deployment group create --name "$DEPLOYMENT_NAME" --resource-group "$RESOURCE_GROUP" \
    --template-file "$SCRIPT_DIR/bicep/ai-relay.bicep" --parameters "${BICEP_PARAMS[@]}" --output none
ENDPOINTS_JSON="$(az deployment group show --resource-group "$RESOURCE_GROUP" --name "$DEPLOYMENT_NAME" \
    --query properties.outputs.endpoints.value -o json)"

install_relay_release() {
    local protocol="$1" release_name="$2" sas_secret_name="$3"
    local endpoint relay_url hc_name sas_key_name sas_key apim_url annotations
    endpoint="$(jq -ce --arg protocol "$protocol" \
        '[.[] | select(.protocol == $protocol)] | if length == 1 then .[0] else error("Expected one endpoint") end' \
        <<< "$ENDPOINTS_JSON")"
    relay_url="$(jq -er '.relayUrl' <<< "$endpoint")"
    hc_name="$(jq -er '.hybridConnectionName' <<< "$endpoint")"
    apim_url="$(jq -er '.apimGatewayUrl' <<< "$endpoint")"
    kubectl create namespace "$K8S_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    local args=()
    if [[ -n "$VALUES_FILE" ]]; then args+=("--values" "$VALUES_FILE"); fi
    args+=("--set-string" "relay.url=$relay_url" "--set-string" "relay.auth.method=$CHART_AUTH_METHOD"
        "--set-string" "endpoint.protocol=$protocol")
    if [[ "$AUTH_MODE" == sas ]]; then
        sas_key_name="$(jq -er '.sasKeyName | select(length > 0)' <<< "$endpoint")"
        sas_key="$(az relay hyco authorization-rule keys list --resource-group "$RESOURCE_GROUP" \
            --namespace-name "$RELAY_NAMESPACE_NAME" --hybrid-connection-name "$hc_name" \
            --name "$sas_key_name" --query primaryKey -o tsv)"
        if [[ -z "$sas_key" ]]; then echo "Error: Azure Relay returned an empty SAS key." >&2; exit 1; fi
        printf '%s' "$sas_key" | kubectl create secret generic "$sas_secret_name" \
            --namespace "$K8S_NAMESPACE" --from-file=sas-key=/dev/stdin --dry-run=client -o yaml | kubectl apply -f - >/dev/null
        args+=("--set-string" "relay.auth.name=$sas_key_name"
            "--set-string" "relay.auth.secret.name=$sas_secret_name")
    else
        args+=("--set-string" "relay.auth.managedIdentity.extension=$AIO_EXTENSION_NAME")
    fi
    if [[ "$protocol" == mcp ]]; then
        args+=("--set-string" "endpoint.url=https://${MCP_FRONTEND_SERVICE_NAME}.${K8S_NAMESPACE}:443/mcp"
            "--set-string" "endpoint.serviceAccountTokens[0].name=aio-mcp-frontend"
            "--set-string" "endpoint.serviceAccountTokens[0].audience=$MCP_FRONTEND_AUDIENCE"
            "--set-string" "endpoint.auth.file=/var/run/secrets/tokens/aio-mcp-frontend"
            "--set-string" "endpoint.auth.kind=bearer-token")
        if [[ -n "$MCP_ROLE" ]]; then
            annotations="$(jq -cn --arg role "$MCP_ROLE" '{"aio-mcp-auth/roles":([$role]|tojson)}')"
            args+=("--set-json" "serviceAccount.annotations=$annotations")
        fi
    else
        # Remove MCP defaults; an A2A values file can provide its own auth, token and TLS settings.
        args=("--values" "$WORK_DIR/a2a-defaults.yaml" "${args[@]}"
            "--set-string" "endpoint.url=$ENDPOINT_URL")
    fi
    if [[ -n "$IMAGE_TAG" ]]; then args+=("--set-string" "image.tag=$IMAGE_TAG"); fi
    helm upgrade --install "$release_name" "$CHART_PACKAGE" --namespace "$K8S_NAMESPACE" \
        --create-namespace "${args[@]}"
    kubectl rollout status "deployment/$release_name" --namespace "$K8S_NAMESPACE" --timeout=180s
    echo "==> [$protocol] Public endpoint: $apim_url"
}

if [[ "$ENDPOINT_PROTOCOL" == both ]]; then
    install_relay_release mcp "${HELM_RELEASE_NAME}-mcp" "aio-ai-relay-hc-mcp"
    install_relay_release a2a "${HELM_RELEASE_NAME}-a2a" "aio-ai-relay-hc-a2a"
else
    install_relay_release "$ENDPOINT_PROTOCOL" "$HELM_RELEASE_NAME" "aio-ai-relay-hc"
fi
echo "==> Assign approved callers to '$ENTRA_APP_ROLE' before using the API."
echo "    Tenant: $ENTRA_TENANT_ID; app: $ENTRA_APP_ID"
if [[ -n "$ENTRA_SP_ID" ]]; then
    echo "    Service principal: $ENTRA_SP_ID; role ID: $ROLE_ID"
fi
echo "    Use Entra Enterprise applications > your app > Users and groups."
