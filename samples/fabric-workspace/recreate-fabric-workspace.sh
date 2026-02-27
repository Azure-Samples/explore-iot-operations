#!/usr/bin/env bash
#
# recreate-fabric-workspace.sh
#
# Recreates a Microsoft Fabric workspace from a JSON snapshot produced by
# export-fabric-workspace.sh, including:
#   - Workspace
#   - Eventhouse(s)
#   - KQL Database(s) with tables, column schemas, and ingestion mappings
#   - Eventstream(s) (with Event Hubs source, if connection string is supplied)
#   - Real-Time Dashboard(s)
#
# Usage:
#   ./recreate-fabric-workspace.sh --snapshot snapshot.json
#   ./recreate-fabric-workspace.sh --snapshot snapshot.json --config my-config.env
#
# Environment variable overrides (all optional unless noted):
#   FABRIC_CAPACITY_ID          Required for a new workspace
#   FABRIC_WORKSPACE_ID         If set, use this existing workspace instead of creating one
#   NEW_WORKSPACE_NAME          Workspace display name (required)
#   EVENTHUB_CONNECTION_STRING  Full SAS connection string for the Event Hubs source
#                               (alternative: set the four individual fields below)
#   EVENTHUB_NAMESPACE          Event Hubs namespace name (without .servicebus.windows.net)
#   EVENTHUB_ENTITY_PATH        Event Hub name (entity path)
#   EVENTHUB_KEY_NAME           Shared-access policy name
#   EVENTHUB_KEY                Shared-access key value
#   EVENTHUB_CONSUMER_GROUP     Event Hub consumer group (default: $Default)
#   DRY_RUN                     Set to "true" to print plan without creating resources
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ── Color helpers ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log_info()  { echo -e "${CYAN}[INFO]${NC}  $*" >&2; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*" >&2; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()  { echo -e "\n${CYAN}──────────────────────────────────${NC}" >&2; echo -e "${CYAN}  $*${NC}" >&2; echo -e "${CYAN}──────────────────────────────────${NC}" >&2; }
log_dry()   { echo -e "${YELLOW}[DRY-RUN]${NC} $*" >&2; }

# ── Argument parsing ──────────────────────────────────────────────────────────
SNAPSHOT_FILE=""
CONFIG_FILE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --snapshot) SNAPSHOT_FILE="$2"; shift 2 ;;
        --config)   CONFIG_FILE="$2";   shift 2 ;;
        --dry-run)  DRY_RUN="true";     shift ;;
        --help|-h)
            echo "Usage: $0 --snapshot <snapshot.json> [--config <config-file>] [--dry-run]"
            echo ""
            echo "Required:"
            echo "  --snapshot <file>           JSON snapshot from export-fabric-workspace.sh"
            echo ""
            echo "Optional env vars:"
            echo "  FABRIC_CAPACITY_ID          Fabric capacity ID (required for new workspace)"
            echo "  FABRIC_WORKSPACE_ID         Use an existing workspace"
            echo "  NEW_WORKSPACE_NAME          Workspace display name (required)"
            echo "  EVENTHUB_CONNECTION_STRING  Full SAS connection string (or set the four fields below)"
            echo "  EVENTHUB_NAMESPACE          Namespace name (without .servicebus.windows.net)"
            echo "  EVENTHUB_ENTITY_PATH        Event Hub name"
            echo "  EVENTHUB_KEY_NAME           Shared-access policy name"
            echo "  EVENTHUB_KEY                Shared-access key value"
            echo "  EVENTHUB_CONSUMER_GROUP     Consumer group (default: \$Default)"
            echo "  DRY_RUN                     true = print plan only"
            exit 0 ;;
        *) log_error "Unknown option: $1"; exit 1 ;;
    esac
done

if [[ -n "${CONFIG_FILE}" ]]; then
    [[ -f "${CONFIG_FILE}" ]] || { log_error "Config file not found: ${CONFIG_FILE}"; exit 1; }
    log_info "Loading config from ${CONFIG_FILE}" >&2
    # shellcheck disable=SC1090
    source "${CONFIG_FILE}"
else
    # Auto-detect a config file in the same directory as the script
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    for _auto in "${SCRIPT_DIR}/my-config.env" "${SCRIPT_DIR}/sample-config.env"; do
        if [[ -f "${_auto}" ]]; then
            log_info "Auto-loading config from ${_auto}" >&2
            # shellcheck disable=SC1090
            source "${_auto}"
            break
        fi
    done
fi

# ── Configuration ─────────────────────────────────────────────────────────────
FABRIC_CAPACITY_ID="${FABRIC_CAPACITY_ID:-}"
FABRIC_WORKSPACE_ID="${FABRIC_WORKSPACE_ID:-}"
NEW_WORKSPACE_NAME="${NEW_WORKSPACE_NAME:-}"
EVENTHUB_CONNECTION_STRING="${EVENTHUB_CONNECTION_STRING:-}"
EVENTHUB_NAMESPACE="${EVENTHUB_NAMESPACE:-}"
EVENTHUB_ENTITY_PATH="${EVENTHUB_ENTITY_PATH:-}"
EVENTHUB_KEY_NAME="${EVENTHUB_KEY_NAME:-}"
EVENTHUB_KEY="${EVENTHUB_KEY:-}"
EVENTHUB_CONSUMER_GROUP="${EVENTHUB_CONSUMER_GROUP:-\$Default}"
DRY_RUN="${DRY_RUN:-false}"

# Auto-assemble EVENTHUB_CONNECTION_STRING from individual fields when it is not
# set directly.  This lets config files (and CI environments) supply the four
# components separately without having to hand-craft the SAS connection string.
if [[ -z "${EVENTHUB_CONNECTION_STRING}" && -n "${EVENTHUB_NAMESPACE}" && \
      -n "${EVENTHUB_ENTITY_PATH}" && -n "${EVENTHUB_KEY_NAME}" && -n "${EVENTHUB_KEY}" ]]; then
    EVENTHUB_CONNECTION_STRING="Endpoint=sb://${EVENTHUB_NAMESPACE}.servicebus.windows.net/;"
    EVENTHUB_CONNECTION_STRING+="SharedAccessKeyName=${EVENTHUB_KEY_NAME};"
    EVENTHUB_CONNECTION_STRING+="SharedAccessKey=${EVENTHUB_KEY};"
    EVENTHUB_CONNECTION_STRING+="EntityPath=${EVENTHUB_ENTITY_PATH}"
fi
FABRIC_API_BASE="https://api.fabric.microsoft.com/v1"

# ── Resolve capacity ID ───────────────────────────────────────────────────────
# The Fabric workspace API requires a capacity GUID. If the user supplied a full
# ARM resource path (/subscriptions/.../capacities/<name>) auto-resolve it.
resolve_capacity_id() {
    local raw="$1" token="$2"

    # Already a GUID – nothing to do
    if [[ "${raw}" =~ ^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$ ]]; then
        echo "${raw}"; return
    fi

    # ARM resource path: extract capacity name (last path segment) and look it
    # up in the Fabric capacities list
    if [[ "${raw}" == /subscriptions/* ]]; then
        local cap_name
        cap_name="${raw##*/}"   # everything after the last /
        log_info "  Resolving ARM resource path to capacity GUID (looking up '${cap_name}')..."

        local body_file http_code body
        body_file=$(mktemp)
        http_code=$(curl -s -o "${body_file}" -w "%{http_code}" \
            -H "Authorization: Bearer ${token}" \
            "${FABRIC_API_BASE}/capacities")
        body=$(cat "${body_file}"); rm -f "${body_file}"

        if [[ "${http_code}" -ge 200 && "${http_code}" -lt 300 ]]; then
            local guid
            guid=$(echo "${body}" | jq -r \
                --arg name "${cap_name}" \
                '.value[]? | select((.displayName // "" | ascii_downcase) == ($name | ascii_downcase)) | .id' \
                2>/dev/null | head -1)
            if [[ -n "${guid}" ]]; then
                log_ok "  Resolved capacity '${cap_name}' → ${guid}"
                echo "${guid}"; return
            fi
        fi

        log_error "Could not resolve capacity '${cap_name}' to a GUID."
        log_error "Check that the capacity name is correct and you have Fabric admin/contributor rights."
        log_error "You can list capacities with: az rest --method GET --url 'https://api.fabric.microsoft.com/v1/capacities'"
        return 1
    fi

    # Unknown format – pass through and let the API reject it with a clear message
    echo "${raw}"
}

# ── Track created resource IDs for summary ────────────────────────────────────
CREATED_WORKSPACE_ID=""
CREATED_EVENTHUB_CONN_ID=""         # tenant-level cloud connection ID for Event Hubs
declare -A CREATED_EVENTHOUSES=()   # displayName → id
declare -A CREATED_KQL_DATABASES=() # displayName → id
declare -A CREATED_KQL_CLUSTERS=()  # eventhouse_id → cluster_uri
declare -A CREATED_EVENTSTREAMS=()  # displayName → id
declare -A CREATED_DASHBOARDS=()    # displayName → id

# ── Prereq check ─────────────────────────────────────────────────────────────
check_prereqs() {
    local missing=0
    for cmd in az curl jq; do
        command -v "${cmd}" &>/dev/null || { log_error "${cmd} not found"; missing=1; }
    done
    [[ -n "${SNAPSHOT_FILE}" ]]   || { log_error "--snapshot is required"; missing=1; }
    [[ -f "${SNAPSHOT_FILE}" ]]   || { log_error "Snapshot file not found: ${SNAPSHOT_FILE}"; missing=1; }
    [[ ${missing} -eq 0 ]] || exit 1
}

# ── Token helpers ─────────────────────────────────────────────────────────────
get_fabric_token() {
    az account get-access-token \
        --resource "https://api.fabric.microsoft.com" \
        --query accessToken --output tsv 2>/dev/null \
    || { log_error "Failed to obtain Fabric token. Run 'az login'."; exit 1; }
}

get_kusto_token() {
    local cluster_uri="$1"
    az account get-access-token \
        --resource "${cluster_uri}" \
        --query accessToken --output tsv 2>/dev/null \
    || { log_warn "Could not get Kusto token for ${cluster_uri}"; echo ""; }
}

# ── HTTP helpers ──────────────────────────────────────────────────────────────
fabric_get() {
    local path="$1" token="$2"
    local body_file http_code body
    body_file=$(mktemp)
    http_code=$(curl -s -o "${body_file}" -w "%{http_code}" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        "${FABRIC_API_BASE}${path}")
    body=$(cat "${body_file}"); rm -f "${body_file}"
    if [[ "${http_code}" -ge 200 && "${http_code}" -lt 300 ]]; then echo "${body}"; return; fi
    log_warn "GET ${path} → HTTP ${http_code}" >&2; echo ""
}

fabric_post() {
    local path="$1" token="$2" data="${3:-{}}"
    local header_file body_file http_code body
    header_file=$(mktemp); body_file=$(mktemp)
    trap "rm -f ${header_file} ${body_file}" RETURN

    http_code=$(curl -s -o "${body_file}" -D "${header_file}" -w "%{http_code}" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d "${data}" \
        "${FABRIC_API_BASE}${path}")
    body=$(cat "${body_file}")

    if [[ "${http_code}" -ge 200 && "${http_code}" -lt 300 ]]; then
        if [[ "${http_code}" == "202" ]]; then
            local location retry_after
            location=$(grep -i "^location:" "${header_file}" | head -1 | tr -d '\r' | sed 's/[Ll]ocation: *//')
            retry_after=$(grep -i "^retry-after:" "${header_file}" | head -1 | tr -d '\r' | sed 's/[Rr]etry-[Aa]fter: *//')
            retry_after="${retry_after:-5}"
            if [[ -n "${location}" ]]; then
                poll_operation "${location}" "${token}" "${retry_after}"; return $?
            fi
        fi
        echo "${body}"; return
    fi
    # Surface the raw body so callers can inspect error codes
    log_error "POST ${path} → HTTP ${http_code}: ${body}" >&2
    # Return the body on stdout so callers that want to handle specific codes can
    echo "${body}"
    return 1
}

poll_operation() {
    local url="$1" token="$2" interval="${3:-5}"
    local attempts=0 max=60
    log_info "  Polling for completion..."
    while [[ ${attempts} -lt ${max} ]]; do
        sleep "${interval}"; attempts=$((attempts+1))
        local body_file http_code body status
        body_file=$(mktemp)
        http_code=$(curl -s -o "${body_file}" -w "%{http_code}" \
            -H "Authorization: Bearer ${token}" "${url}")
        body=$(cat "${body_file}"); rm -f "${body_file}"
        if [[ "${http_code}" -ge 200 && "${http_code}" -lt 300 ]]; then
            status=$(echo "${body}" | jq -r '.status // empty' 2>/dev/null)
            case "${status,,}" in
                succeeded) echo "${body}"; return 0 ;;
                failed)    log_error "Operation failed: $(echo "${body}" | jq -r '.error.message // .' 2>/dev/null)"; return 1 ;;
                *)         log_info "  status: ${status:-unknown} (${attempts}/${max})" ;;
            esac
        fi
    done
    log_error "Operation timed out."; return 1
}

# Wait for an eventhouse to expose its queryServiceUri (it takes a few seconds)
wait_for_cluster_uri() {
    local workspace_id="$1" house_id="$2" token="$3"
    local attempts=0 max=30
    while [[ ${attempts} -lt ${max} ]]; do
        local detail uri
        detail=$(fabric_get "/workspaces/${workspace_id}/eventhouses/${house_id}" "${token}")
        uri=$(echo "${detail}" | jq -r '.properties.queryServiceUri // empty')
        if [[ -n "${uri}" ]]; then
            echo "${uri}"; return 0
        fi
        attempts=$((attempts+1))
        log_info "  Waiting for cluster URI... (${attempts}/${max})"
        sleep 5
    done
    log_warn "Cluster URI not available after waiting."; echo ""; return 1
}

wait_for_kql_database() {
    local workspace_id="$1" db_id="$2" token="$3"
    local attempts=0 max=30
    while [[ ${attempts} -lt ${max} ]]; do
        local detail state
        detail=$(fabric_get "/workspaces/${workspace_id}/kqlDatabases/${db_id}" "${token}")
        # A KQL database is ready when its readWriteState is "RW" or if it just exists
        state=$(echo "${detail}" | jq -r '.properties.readWriteState // empty')
        if [[ -n "${detail}" && ("${state}" == "RW" || "${state}" == "") ]]; then
            return 0
        fi
        attempts=$((attempts+1))
        log_info "  Waiting for KQL database to be ready... (${attempts}/${max})"
        sleep 5
    done
    log_warn "KQL database not ready after waiting."; return 1
}

kusto_run() {
    # Runs a KQL management command; returns output on success
    local cluster="$1" database="$2" command="$3" token="$4"
    [[ -z "${token}" ]] && { log_warn "Skipping Kusto command (no token)"; return; }

    local payload body_file http_code body
    payload=$(jq -n --arg db "${database}" --arg csl "${command}" \
        '{"db": $db, "csl": $csl, "properties": {"Options": {"servertimeout": "00:02:00"}}}')

    body_file=$(mktemp)
    http_code=$(curl -s -o "${body_file}" -w "%{http_code}" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json; charset=utf-8" \
        -d "${payload}" \
        "${cluster}/v1/rest/mgmt")
    body=$(cat "${body_file}"); rm -f "${body_file}"

    if [[ "${http_code}" -ge 200 && "${http_code}" -lt 300 ]]; then
        echo "${body}"
    else
        log_warn "Kusto command failed (HTTP ${http_code}): $(echo "${body}" | jq -r '.error.message // .["message"] // .' 2>/dev/null | head -c 300)"
        echo ""
    fi
}

# ── Plan display (dry-run) ────────────────────────────────────────────────────
print_plan() {
    local snapshot="$1"
    echo ""
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  DRY-RUN – the following resources would be created:${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  Workspace:  $(echo "${snapshot}" | jq -r '.workspace.displayName')"
    echo ""

    local eh_count db_count es_count dash_count
    eh_count=$(echo "${snapshot}"   | jq '.eventhouses | length')
    db_count=$(echo "${snapshot}"   | jq '.kql_databases | length')
    es_count=$(echo "${snapshot}"   | jq '.eventstreams | length')
    dash_count=$(echo "${snapshot}" | jq '.realtime_dashboards | length')

    echo "  Eventhouses (${eh_count}):"
    echo "${snapshot}" | jq -r '.eventhouses[].displayName' | sed 's/^/    - /'

    echo "  KQL Databases (${db_count}):"
    echo "${snapshot}" | jq -r '.kql_databases[] | "    - \(.displayName)  [\(.export_tables | length) tables, \(.export_mappings | length) mappings]"'

    echo "  Eventstreams (${es_count}):"
    echo "${snapshot}" | jq -r '.eventstreams[].displayName' | sed 's/^/    - /'

    echo "  Real-Time Dashboards (${dash_count}):"
    echo "${snapshot}" | jq -r '.realtime_dashboards[].displayName' | sed 's/^/    - /'
    echo ""
    echo -e "${YELLOW}Remove --dry-run to apply.${NC}"
    echo ""
}

# ── Step 1: Workspace ─────────────────────────────────────────────────────────
create_workspace() {
    local token="$1"

    if [[ -n "${FABRIC_WORKSPACE_ID}" ]]; then
        log_info "Using existing workspace: ${FABRIC_WORKSPACE_ID}"
        local ws
        ws=$(fabric_get "/workspaces/${FABRIC_WORKSPACE_ID}" "${token}")
        [[ -z "${ws}" ]] && { log_error "Workspace not found."; exit 1; }
        log_ok "Workspace: $(echo "${ws}" | jq -r '.displayName')"
        CREATED_WORKSPACE_ID="${FABRIC_WORKSPACE_ID}"
        return
    fi

    [[ -z "${NEW_WORKSPACE_NAME}" ]] && {
        log_error "NEW_WORKSPACE_NAME is required. Set it in your config file."
        exit 1
    }

    local ws_name desc
    ws_name="${NEW_WORKSPACE_NAME}"
    desc="Azure IoT Operations quickstart 3"

    [[ -z "${FABRIC_CAPACITY_ID}" ]] && {
        log_error "FABRIC_CAPACITY_ID is required to create a new workspace."
        log_error "Set it via env var or config file, or set FABRIC_WORKSPACE_ID to use an existing one."
        exit 1
    }

    # Normalise: resolve ARM resource path → GUID if needed
    local resolved_cap
    resolved_cap=$(resolve_capacity_id "${FABRIC_CAPACITY_ID}" "${token}") || exit 1

    # Delete any existing workspace with the same name so creation always starts clean
    local all_ws existing_ws_id
    all_ws=$(fabric_get "/workspaces" "${token}")
    existing_ws_id=$(echo "${all_ws}" | jq -r \
        --arg name "${ws_name}" \
        '.value[]? | select(.displayName == $name) | .id' | head -1)
    if [[ -n "${existing_ws_id}" ]]; then
        log_warn "Workspace '${ws_name}' already exists (${existing_ws_id}) – deleting it..."
        local del_code
        del_code=$(curl -s -o /dev/null -w "%{http_code}" \
            -X DELETE \
            -H "Authorization: Bearer ${token}" \
            "${FABRIC_API_BASE}/workspaces/${existing_ws_id}")
        if [[ "${del_code}" -ge 200 && "${del_code}" -lt 300 ]]; then
            log_ok "Deleted workspace: ${existing_ws_id}"
        else
            log_error "Failed to delete existing workspace (HTTP ${del_code}). Aborting."; exit 1
        fi
    fi

    log_info "Creating workspace: ${ws_name}"

    local payload result ws_id
    payload=$(jq -n \
        --arg name "${ws_name}" \
        --arg desc "${desc}" \
        --arg cap  "${resolved_cap}" \
        '{displayName: $name, description: $desc, capacityId: $cap}')

    local header_file body_file http_code
    header_file=$(mktemp); body_file=$(mktemp)
    http_code=$(curl -s -o "${body_file}" -D "${header_file}" -w "%{http_code}" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d "${payload}" \
        "${FABRIC_API_BASE}/workspaces")
    result=$(cat "${body_file}"); rm -f "${header_file}" "${body_file}"

    if [[ "${http_code}" -ge 200 && "${http_code}" -lt 300 ]]; then
        if [[ "${http_code}" == "202" ]]; then
            local location
            location=$(echo "${result}" | jq -r '.location // empty' 2>/dev/null)
            [[ -n "${location}" ]] && result=$(poll_operation "${location}" "${token}" "3")
        fi
        ws_id=$(echo "${result}" | jq -r '.id // empty')
    else
        log_error "Workspace creation failed (${http_code}): ${result}"; exit 1
    fi

    [[ -z "${ws_id}" ]] && { log_error "Could not extract workspace ID."; echo "${result}"; exit 1; }
    log_ok "Workspace ready: ${ws_name} (${ws_id})"
    CREATED_WORKSPACE_ID="${ws_id}"
}

# ── Step 2: Eventhouses ───────────────────────────────────────────────────────
create_eventhouses() {
    local snapshot="$1" ws_id="$2" token="$3"
    local count; count=$(echo "${snapshot}" | jq '.eventhouses | length')
    log_info "Creating ${count} Eventhouse(s)..."

    local i=0
    while [[ ${i} -lt ${count} ]]; do
        local house name desc payload result id cluster_uri
        house=$(echo "${snapshot}" | jq ".eventhouses[${i}]")
        name="contoso-qs-eh"
        desc="Quickstart Eventhouse"
        local orig_id; orig_id=$(echo "${house}" | jq -r '.id')

        log_info "  Creating Eventhouse: ${name}"

        payload=$(jq -n \
            --arg n "${name}" \
            --arg d "${desc}" \
            '{displayName: $n, description: $d}')

        # Use a raw curl call so we can inspect the exact HTTP status
        local eh_header eh_body eh_code
        eh_header=$(mktemp); local eh_body_file; eh_body_file=$(mktemp)
        eh_code=$(curl -s -o "${eh_body_file}" -D "${eh_header}" -w "%{http_code}" \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" \
            -d "${payload}" \
            "${FABRIC_API_BASE}/workspaces/${ws_id}/eventhouses")
        local eh_result; eh_result=$(cat "${eh_body_file}")
        rm -f "${eh_header}" "${eh_body_file}"

        if [[ "${eh_code}" -ge 200 && "${eh_code}" -lt 300 ]]; then
            if [[ "${eh_code}" == "202" ]]; then
                eh_result=$(poll_operation \
                    "$(echo "${eh_result}" | jq -r '.location // empty')" \
                    "${token}" "5") || true
            fi
            id=$(echo "${eh_result}" | jq -r '.id // empty')
        else
            log_warn "  Failed to create Eventhouse: ${name} (HTTP ${eh_code})"
            i=$((i+1)); continue
        fi
        [[ -z "${id}" ]] && { log_warn "  Could not extract ID for ${name}"; i=$((i+1)); continue; }
        log_ok "  Created: ${name} (${id})"

        # Wait for cluster URI to be available
        cluster_uri=$(wait_for_cluster_uri "${ws_id}" "${id}" "${token}")
        if [[ -n "${cluster_uri}" ]]; then
            CREATED_KQL_CLUSTERS["${id}"]="${cluster_uri}"
            log_ok "  Cluster URI: ${cluster_uri}"
        fi

        CREATED_EVENTHOUSES["${name}"]="${id}"
        # Store old→new ID mapping for KQL DB creation
        CREATED_EVENTHOUSES["orig:${orig_id}"]="${id}"
        i=$((i+1))
    done
}

# ── Step 3: KQL Databases ─────────────────────────────────────────────────────
create_kql_databases() {
    local ws_id="$1" token="$2"

    local eh_id="${CREATED_EVENTHOUSES["contoso-qs-eh"]:-}"
    if [[ -z "${eh_id}" ]]; then
        log_warn "  Could not find Eventhouse 'contoso-qs-eh'. Skipping KQL Database lookup."
        return
    fi

    # Fabric automatically creates a KQL database with the same name as the
    # Eventhouse when the Eventhouse is created.  Look it up rather than creating
    # a second database.
    log_info "  Looking up auto-created KQL Database for Eventhouse ${eh_id}..."

    local all_dbs db_id
    all_dbs=$(fabric_get "/workspaces/${ws_id}/kqlDatabases" "${token}")
    db_id=$(echo "${all_dbs}" | jq -r \
        --arg ehid "${eh_id}" \
        '.value[]? | select(.properties.parentEventhouseItemId == $ehid) | .id' | head -1)

    if [[ -z "${db_id}" ]]; then
        log_warn "  Could not find auto-created KQL Database for Eventhouse ${eh_id}."
        return
    fi

    log_ok "  Found auto-created KQL Database: ${db_id}"

    wait_for_kql_database "${ws_id}" "${db_id}" "${token}" || true

    CREATED_KQL_DATABASES["contoso-qs-db"]="${db_id}"
}

# ── Step 4: Tables and Ingestion Mappings ─────────────────────────────────────
create_kql_schema() {
    local ws_id="$1" token="$2"

    local db_name="contoso-qs-db"
    local db_id="${CREATED_KQL_DATABASES["${db_name}"]:-}"
    if [[ -z "${db_id}" ]]; then
        log_warn "  Skipping schema (KQL Database '${db_name}' was not created)"; return
    fi

    # Find cluster URI via the fixed eventhouse
    local eh_id cluster_uri
    eh_id="${CREATED_EVENTHOUSES["contoso-qs-eh"]:-}"
    cluster_uri="${CREATED_KQL_CLUSTERS["${eh_id}"]:-}"
    if [[ -z "${cluster_uri}" ]]; then
        log_warn "  No cluster URI found. Skipping schema creation."
        return
    fi

    local kusto_token
    kusto_token=$(get_kusto_token "${cluster_uri}")
    if [[ -z "${kusto_token}" ]]; then
        log_warn "  No Kusto token. Skipping schema for ${db_name}."; return
    fi

    log_info "  Creating tables in: ${db_name} (${cluster_uri})"
    # In Fabric/Kusto the database name in the management API is the item UUID, not the display name
    local kusto_db_name="${db_id}"
    local name="${db_name}"  # used in log messages below

        # ── Create OPCUA table ────────────────────────────────────────────────
        local create_cmd
        create_cmd=".create-merge table [OPCUA] ([AssetId]:string, [Spike]:bool, [Temperature]:decimal, [FillWeight]:decimal, [EnergyUse]:decimal, [Timestamp]:datetime)"
        log_info "    Running: ${create_cmd:0:80}..."
        kusto_run "${cluster_uri}" "${kusto_db_name}" "${create_cmd}" "${kusto_token}" > /dev/null
        log_ok "  Table created in ${name}"

        # ── Create OPCUA ingestion mapping ────────────────────────────────────
        # In KQL, single-quoted strings escape single quotes by doubling them ('')
        local map_json escaped_map_json map_cmd
        map_json='[{"column":"AssetId","Properties":{"Path":"$.AssetId"}},{"column":"Spike","Properties":{"Path":"$.Spike"}},{"column":"Temperature","Properties":{"Path":"$.TemperatureF"}},{"column":"FillWeight","Properties":{"Path":"$.FillWeight"}},{"column":"EnergyUse","Properties":{"Path":"$.EnergyUse.Value"}},{"column":"Timestamp","Properties":{"Path":"$.EventProcessedUtcTime"}}]'
        escaped_map_json="${map_json//\'/\'\'}"
        map_cmd=".create table ['OPCUA'] ingestion json mapping 'opcua_mapping' '${escaped_map_json}'"
        log_info "    Creating ingestion mapping: opcua_mapping"
        local map_result
        map_result=$(kusto_run "${cluster_uri}" "${kusto_db_name}" "${map_cmd}" "${kusto_token}")
        if [[ -z "${map_result}" ]]; then
            log_warn "    Failed to create ingestion mapping: opcua_mapping"
        else
            log_ok "  Mapping created: opcua_mapping"
        fi
}

# Patch a definition JSON by doing string replacement on the entire serialised form
# (safe because Fabric IDs are GUIDs and won't appear as substrings of other values)
patch_definition_raw() {
    local def_json="$1"
    local old_ws="$2"
    local new_ws="$3"
    shift 3
    local id_pairs=("$@")

    local patched="${def_json}"

    # Replace workspace ID
    if [[ -n "${old_ws}" && -n "${new_ws}" && "${old_ws}" != "${new_ws}" ]]; then
        patched="${patched//${old_ws}/${new_ws}}"
    fi

    # Replace item IDs
    local pi=0
    while [[ ${pi} -lt ${#id_pairs[@]} ]]; do
        local oid="${id_pairs[${pi}]}"
        local nid="${id_pairs[$((pi+1))]}"
        [[ -n "${oid}" && -n "${nid}" && "${oid}" != "${nid}" ]] && \
            patched="${patched//${oid}/${nid}}"
        pi=$((pi+2))
    done

    # We do this by processing the definition JSON parts array if present
    if echo "${patched}" | jq -e '.definition.parts' &>/dev/null 2>&1; then
        local parts_count
        parts_count=$(echo "${patched}" | jq '.definition.parts | length')
        local pi2=0
        while [[ ${pi2} -lt ${parts_count} ]]; do
            local payload_type payload decoded re_encoded
            payload_type=$(echo "${patched}" | jq -r ".definition.parts[${pi2}].payloadType // \"\"")
            if [[ "${payload_type}" == "InlineBase64" ]]; then
                payload=$(echo "${patched}" | jq -r ".definition.parts[${pi2}].payload // \"\"")
                if [[ -n "${payload}" ]]; then
                    decoded=$(echo "${payload}" | base64 -d 2>/dev/null || echo "")
                    if [[ -n "${decoded}" ]]; then
                        # Apply same replacements on decoded content
                        [[ -n "${old_ws}" && -n "${new_ws}" && "${old_ws}" != "${new_ws}" ]] && \
                            decoded="${decoded//${old_ws}/${new_ws}}"
                        local pi3=0
                        while [[ ${pi3} -lt ${#id_pairs[@]} ]]; do
                            local oid="${id_pairs[${pi3}]}"
                            local nid="${id_pairs[$((pi3+1))]}"
                            [[ -n "${oid}" && -n "${nid}" && "${oid}" != "${nid}" ]] && \
                                decoded="${decoded//${oid}/${nid}}"
                            pi3=$((pi3+2))
                        done
                        # dataConnectionId values in AzureEventHub sources are Fabric
                        # tenant-level ShareableCloud connections.  They can be referenced
                        # from any workspace in the same tenant, so we keep them as-is.
                        # If EVENTHUB_CONNECTION_STRING is set, the caller will have already
                        # replaced the dataConnectionId with a newly created connection's ID.
                        re_encoded=$(echo -n "${decoded}" | base64 -w 0)
                        patched=$(echo "${patched}" | jq \
                            --argjson idx "${pi2}" \
                            --arg enc "${re_encoded}" \
                            '.definition.parts[$idx].payload = $enc')
                    fi
                fi
            fi
            pi2=$((pi2+1))
        done
    fi

    echo "${patched}"
}

# Create a tenant-level ShareableCloud connection for Azure Event Hubs.
# The connection ID can then be injected as dataConnectionId in an Eventstream source.
# Returns the new connection ID on stdout, or empty string on failure.
# Usage: create_eventhub_connection <connection_string> <consumer_group> <token>
create_eventhub_connection() {
    local conn_str="$1" consumer_group="$2" token="$3"

    # Parse connection string fields.
    # Use a negative-lookahead so 'SharedAccessKey=' does not match 'SharedAccessKeyName='.
    local endpoint entity keyname key
    endpoint=$(echo "${conn_str}" | grep -oP 'Endpoint=sb://\K[^.]+' || true)
    entity=$(echo "${conn_str}"   | grep -oP 'EntityPath=\K[^;]+'              || true)
    keyname=$(echo "${conn_str}"  | grep -oP 'SharedAccessKeyName=\K[^;]+'     || true)
    key=$(echo "${conn_str}"      | grep -oP 'SharedAccessKey=(?!Name)\K[^;]+' || true)

    if [[ -z "${endpoint}" || -z "${entity}" || -z "${keyname}" || -z "${key}" ]]; then
        log_warn "  Could not parse EVENTHUB_CONNECTION_STRING — skipping connection creation."
        log_warn "    endpoint='${endpoint}' entity='${entity}' keyname='${keyname}' key=${key:+(set)}"
        echo ""; return 0
    fi

    local display_name="${endpoint}/${entity}"

    # Build the request body using the Fabric Connections API schema:
    #   connectionDetails.creationMethod = "EventHub.Contents"  (from ListSupportedConnectionTypes)
    #   connectionDetails.parameters     = [{endpoint}, {entityPath}]
    #   credentialDetails.credentials    = Basic (SAS key name + key)
    local body conn_resp_file conn_http_code result conn_id
    body=$(jq -n \
        --arg dn  "${display_name}" \
        --arg ep  "${endpoint}" \
        --arg ent "${entity}" \
        --arg usr "${keyname}" \
        --arg pwd "${key}" \
        '{
            "displayName": $dn,
            "connectivityType": "ShareableCloud",
            "privacyLevel": "None",
            "connectionDetails": {
                "type": "EventHub",
                "creationMethod": "EventHub.Contents",
                "parameters": [
                    {"dataType": "Text", "name": "endpoint",   "value": $ep},
                    {"dataType": "Text", "name": "entityPath", "value": $ent}
                ]
            },
            "credentialDetails": {
                "credentialType": "Basic",
                "singleSignOnType": "None",
                "connectionEncryption": "NotEncrypted",
                "skipTestConnection": false,
                "credentials": {
                    "credentialType": "Basic",
                    "username": $usr,
                    "password": $pwd
                }
            }
        }')

    conn_resp_file=$(mktemp)
    conn_http_code=$(curl -sS -o "${conn_resp_file}" -w "%{http_code}" \
        -X POST \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d "${body}" \
        "${FABRIC_API_BASE}/connections" 2>/dev/null || echo "000")
    result=$(cat "${conn_resp_file}"); rm -f "${conn_resp_file}"

    conn_id=$(echo "${result}" | jq -r '.id // empty' 2>/dev/null || true)
    if [[ -z "${conn_id}" ]]; then
        local err
        err=$(echo "${result}" | jq -r '.errorCode // .message // "unknown error"' 2>/dev/null || true)
        log_warn "  Could not create Event Hub connection (HTTP ${conn_http_code}: ${err})"
        log_warn "  Full response: ${result}"
        echo ""; return 0
    fi
    log_info "  Created Event Hub connection: ${conn_id} (${display_name})"
    echo "${conn_id}"
}

# ── Step 5: Cloud Connection (Event Hubs) ────────────────────────────────────
create_cloud_connection() {
    local token="$1"

    if [[ -z "${EVENTHUB_CONNECTION_STRING}" ]]; then
        log_info "  No EVENTHUB_CONNECTION_STRING set — skipping cloud connection creation."
        return
    fi

    # Parse connection string fields
    local endpoint entity keyname key
    endpoint=$(echo "${EVENTHUB_CONNECTION_STRING}" | grep -oP 'Endpoint=sb://\K[^.]+' || true)
    entity=$(echo "${EVENTHUB_CONNECTION_STRING}"   | grep -oP 'EntityPath=\K[^;]+'              || true)
    keyname=$(echo "${EVENTHUB_CONNECTION_STRING}"  | grep -oP 'SharedAccessKeyName=\K[^;]+'     || true)
    key=$(echo "${EVENTHUB_CONNECTION_STRING}"      | grep -oP 'SharedAccessKey=(?!Name)\K[^;]+' || true)

    if [[ -z "${endpoint}" || -z "${entity}" || -z "${keyname}" || -z "${key}" ]]; then
        log_warn "  Could not parse EVENTHUB_CONNECTION_STRING — skipping cloud connection creation."
        return
    fi

    local display_name="${endpoint}/${entity}"
    log_info "  Checking for existing cloud connection: ${display_name}"

    # Delete any existing connection with the same display name so creation starts clean
    local all_conns existing_id
    all_conns=$(fabric_get "/connections" "${token}")
    existing_id=$(echo "${all_conns}" | jq -r \
        --arg dn "${display_name}" \
        '.value[]? | select(.displayName == $dn) | .id' | head -1)

    if [[ -n "${existing_id}" ]]; then
        log_warn "  Connection '${display_name}' already exists (${existing_id}) – deleting it..."
        local del_code
        del_code=$(curl -s -o /dev/null -w "%{http_code}" \
            -X DELETE \
            -H "Authorization: Bearer ${token}" \
            "${FABRIC_API_BASE}/connections/${existing_id}")
        if [[ "${del_code}" -ge 200 && "${del_code}" -lt 300 ]]; then
            log_ok "  Deleted connection: ${existing_id}"
        else
            log_warn "  Failed to delete existing connection (HTTP ${del_code}) — proceeding anyway."
        fi
    fi

    log_info "  Creating Event Hub connection: ${display_name}"
    local conn_id
    conn_id=$(create_eventhub_connection \
        "${EVENTHUB_CONNECTION_STRING}" \
        "${EVENTHUB_CONSUMER_GROUP}" \
        "${token}")

    if [[ -n "${conn_id}" ]]; then
        log_ok "  Cloud connection ready: ${conn_id} (${display_name})"
        CREATED_EVENTHUB_CONN_ID="${conn_id}"
    else
        log_warn "  Cloud connection creation failed. Eventstreams may not have a working Event Hub source."
    fi
}

# ── Step 6: Eventstreams ──────────────────────────────────────────────────────
create_eventstreams() {
    local snapshot="$1" ws_id="$2" token="$3"
    local count; count=$(echo "${snapshot}" | jq '.eventstreams | length')
    log_info "Creating ${count} Eventstream(s)..."

    # Build old→new item ID pairs for patching definitions
    local old_ws_id
    old_ws_id=$(echo "${snapshot}" | jq -r '.workspace.id')
    local id_pairs=()
    for old_eh_key in "${!CREATED_EVENTHOUSES[@]}"; do
        [[ "${old_eh_key}" == orig:* ]] || continue
        local old_item_id="${old_eh_key#orig:}"
        local new_item_id="${CREATED_EVENTHOUSES[${old_eh_key}]}"
        id_pairs+=("${old_item_id}" "${new_item_id}")
    done
    # The auto-created KQL database in the new workspace was looked up by parent
    # eventhouse ID and stored under the "contoso-qs-db" key.  Find the old KQL
    # database ID from the snapshot (there is always exactly one; matching by
    # display name is fragile because the auto-created DB takes the eventhouse name,
    # not "contoso-qs-db").
    local old_db_id new_db_id
    old_db_id=$(echo "${snapshot}" | jq -r '.kql_databases[0].id // empty')
    new_db_id="${CREATED_KQL_DATABASES["contoso-qs-db"]:-}"
    [[ -n "${old_db_id}" && -n "${new_db_id}" ]] && id_pairs+=("${old_db_id}" "${new_db_id}")

    local i=0
    while [[ ${i} -lt ${count} ]]; do
        local stream name desc raw_def payload result stream_id
        stream=$(echo "${snapshot}" | jq ".eventstreams[${i}]")
        name=$(echo "${stream}" | jq -r '.displayName')
        desc=$(echo "${stream}" | jq -r '.description // ""')

        # Extract the definition from the snapshot export
        raw_def=$(echo "${stream}" | jq '.export_definition // {}')

        # Patch workspace ID and item IDs in the definition so destinations
        # resolve to the new workspace (avoids cross-workspace destination error)
        if echo "${raw_def}" | jq -e 'keys | length > 0' &>/dev/null 2>&1; then
            raw_def=$(patch_definition_raw "${raw_def}" \
                "${old_ws_id}" "${ws_id}" \
                "${id_pairs[@]}")
        fi

        # If a cloud connection was pre-created (Step 5), patch its ID into the
        # definition in place of the old dataConnectionId.
        if [[ -n "${CREATED_EVENTHUB_CONN_ID}" && $(echo "${raw_def}" | jq 'keys | length') -gt 0 ]]; then
            local _old_conn_id
            # dataConnectionId is inside the base64-encoded payload – decode each part to find it
            _old_conn_id=""
            local _part_count _part_idx
            _part_count=$(echo "${raw_def}" | jq '.definition.parts | length // 0')
            for (( _part_idx=0; _part_idx<_part_count; _part_idx++ )); do
                local _ptype _payload _decoded _found_id
                _ptype=$(echo "${raw_def}" | jq -r ".definition.parts[${_part_idx}].payloadType // \"\"")
                if [[ "${_ptype}" == "InlineBase64" ]]; then
                    _payload=$(echo "${raw_def}" | jq -r ".definition.parts[${_part_idx}].payload // \"\"")
                    _decoded=$(echo "${_payload}" | base64 -d 2>/dev/null || echo "")
                    _found_id=$(echo "${_decoded}" | jq -r \
                        '[.. | objects | select(.dataConnectionId?) | .dataConnectionId] | first // empty' \
                        2>/dev/null || true)
                    if [[ -n "${_found_id}" ]]; then
                        _old_conn_id="${_found_id}"
                        break
                    fi
                fi
            done
            if [[ -n "${_old_conn_id}" && "${_old_conn_id}" != "${CREATED_EVENTHUB_CONN_ID}" ]]; then
                log_info "  Patching Event Hub connection ID: ${CREATED_EVENTHUB_CONN_ID}"
                # Replace old connection ID inside base64-encoded parts
                raw_def=$(patch_definition_raw "${raw_def}" "" "" \
                    "${_old_conn_id}" "${CREATED_EVENTHUB_CONN_ID}")
            fi
        fi

        local has_def; has_def=$(echo "${raw_def}" | jq 'keys | length > 0')

        log_info "  Creating Eventstream: ${name}"

        if [[ "${has_def}" == "true" ]]; then
            payload=$(jq -n \
                --arg n   "${name}" \
                --arg d   "${desc}" \
                --argjson def "${raw_def}" \
                '{displayName: $n, description: $d, definition: $def.definition}')
        else
            payload=$(jq -n \
                --arg n "${name}" \
                --arg d "${desc}" \
                '{displayName: $n, description: $d}')
            log_warn "  No definition found in snapshot for '${name}' – creating empty Eventstream. Configure source and destination manually in Fabric portal."
        fi

        local raw_es_header raw_es_resp es_http_code es_result
        raw_es_header=$(mktemp); raw_es_resp=$(mktemp)
        es_http_code=$(curl -sS -o "${raw_es_resp}" -D "${raw_es_header}" -w "%{http_code}" \
            -X POST \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" \
            -d "${payload}" \
            "${FABRIC_API_BASE}/workspaces/${ws_id}/eventstreams")
        es_result=$(cat "${raw_es_resp}"); rm -f "${raw_es_resp}"

        if [[ "${es_http_code}" == "202" ]]; then
            local es_loc
            es_loc=$(grep -i "^location:" "${raw_es_header}" | head -1 | tr -d '\r' | sed 's/[Ll]ocation: *//')
            rm -f "${raw_es_header}"
            local poll_rc=0
            if [[ -n "${es_loc}" ]]; then
                es_result=$(poll_operation "${es_loc}" "${token}" "5") || poll_rc=$?
            fi
            if [[ ${poll_rc} -ne 0 && "${has_def}" == "true" ]]; then
                # Async validation failed (e.g. cloud connection not found in this tenant).
                # Retry without a definition so the eventstream shell is still created.
                log_warn "  Eventstream async operation failed. Retrying without definition."
                log_warn "  Set EVENTHUB_CONNECTION_STRING (or individual EVENTHUB_* fields) to recreate the Event Hub source connection automatically."
                local retry2_payload retry2_code retry2_resp retry2_header
                retry2_resp=$(mktemp); retry2_header=$(mktemp)
                retry2_payload=$(jq -n --arg n "${name}" --arg d "${desc}" '{displayName: $n, description: $d}')
                retry2_code=$(curl -sS -o "${retry2_resp}" -D "${retry2_header}" -w "%{http_code}" \
                    -X POST \
                    -H "Authorization: Bearer ${token}" \
                    -H "Content-Type: application/json" \
                    -d "${retry2_payload}" \
                    "${FABRIC_API_BASE}/workspaces/${ws_id}/eventstreams")
                es_result=$(cat "${retry2_resp}"); rm -f "${retry2_resp}"
                if [[ "${retry2_code}" == "202" ]]; then
                    local retry2_loc
                    retry2_loc=$(grep -i "^location:" "${retry2_header}" | head -1 | tr -d '\r' | sed 's/[Ll]ocation: *//')
                    rm -f "${retry2_header}"
                    [[ -n "${retry2_loc}" ]] && es_result=$(poll_operation "${retry2_loc}" "${token}" "5") || true
                    stream_id=$(echo "${es_result}" | jq -r '.createdItemId // .id // empty')
                elif [[ "${retry2_code}" -ge 200 && "${retry2_code}" -lt 300 ]]; then
                    stream_id=$(echo "${es_result}" | jq -r '.createdItemId // .id // empty')
                    rm -f "${retry2_header}"
                else
                    local retry2_err; retry2_err=$(echo "${es_result}" | jq -r '.errorCode // ""' 2>/dev/null || true)
                    rm -f "${retry2_header}"
                    if [[ "${retry2_err}" == "ItemDisplayNameAlreadyInUse" ]]; then
                        : # will be caught by the name-fallback search below
                    else
                        log_warn "  Retry also failed (HTTP ${retry2_code}). Skipping Eventstream: ${name}."
                        i=$((i+1)); continue
                    fi
                fi
            else
                stream_id=$(echo "${es_result}" | jq -r '.createdItemId // .id // empty')
            fi
        elif [[ "${es_http_code}" -ge 200 && "${es_http_code}" -lt 300 ]]; then
            stream_id=$(echo "${es_result}" | jq -r '.createdItemId // .id // empty')
            rm -f "${raw_es_header}"
        else
            rm -f "${raw_es_header}"
            local es_err_code
            es_err_code=$(echo "${es_result}" | jq -r '.errorCode // ""' 2>/dev/null || true)
            if [[ "${has_def}" == "true" ]]; then
                # Definition was rejected (e.g. dataConnectionId not found in this tenant).
                # Retry without a definition so the eventstream shell is still created.
                log_warn "  Definition rejected (HTTP ${es_http_code}: ${es_err_code}). Retrying without definition."
                log_warn "  Set EVENTHUB_CONNECTION_STRING to recreate the Event Hub source connection automatically."
                local retry_payload retry_code retry_resp retry_header
                retry_resp=$(mktemp); retry_header=$(mktemp)
                retry_payload=$(jq -n --arg n "${name}" --arg d "${desc}" '{displayName: $n, description: $d}')
                retry_code=$(curl -sS -o "${retry_resp}" -D "${retry_header}" -w "%{http_code}" \
                    -X POST \
                    -H "Authorization: Bearer ${token}" \
                    -H "Content-Type: application/json" \
                    -d "${retry_payload}" \
                    "${FABRIC_API_BASE}/workspaces/${ws_id}/eventstreams")
                es_result=$(cat "${retry_resp}"); rm -f "${retry_resp}"
                if [[ "${retry_code}" == "202" ]]; then
                    local retry_loc
                    retry_loc=$(grep -i "^location:" "${retry_header}" | head -1 | tr -d '\r' | sed 's/[Ll]ocation: *//')
                    rm -f "${retry_header}"
                    [[ -n "${retry_loc}" ]] && es_result=$(poll_operation "${retry_loc}" "${token}" "5") || true
                    stream_id=$(echo "${es_result}" | jq -r '.createdItemId // .id // empty')
                elif [[ "${retry_code}" -ge 200 && "${retry_code}" -lt 300 ]]; then
                    stream_id=$(echo "${es_result}" | jq -r '.createdItemId // .id // empty')
                    rm -f "${retry_header}"
                else
                    rm -f "${retry_header}"
                    log_warn "  Retry also failed (HTTP ${retry_code}). Skipping Eventstream: ${name}."
                    i=$((i+1)); continue
                fi
            else
                log_warn "  Failed to create Eventstream: ${name} (HTTP ${es_http_code}: ${es_err_code})"
                i=$((i+1)); continue
            fi
        fi

        # Fallback: if polling failed but Fabric still created the item, find it by name
        if [[ -z "${stream_id}" ]]; then
            local fallback_es
            fallback_es=$(curl -sS -H "Authorization: Bearer ${token}" \
                "${FABRIC_API_BASE}/workspaces/${ws_id}/eventstreams")
            stream_id=$(echo "${fallback_es}" | jq -r \
                --arg n "${name}" '.value[] | select(.displayName == $n) | .id' | head -1)
            [[ -n "${stream_id}" ]] && log_warn "  Async provisioning incomplete for '${name}' — found item anyway (${stream_id})"
        fi
        [[ -z "${stream_id}" ]] && { log_warn "  Could not extract ID for ${name}"; i=$((i+1)); continue; }

        log_ok "  Eventstream created: ${name} (${stream_id})"
        # If EVENTHUB_CONNECTION_STRING was not supplied:
        #   • If the original dataConnectionId exists in this tenant the definition was accepted
        #     and the eventstream is fully connected.
        #   • If the connection was not found the definition was rejected; an empty shell was
        #     created instead.  Set EVENTHUB_CONNECTION_STRING and re-run, or configure the
        #     source manually in the Fabric portal.
        if [[ -z "${EVENTHUB_CONNECTION_STRING}" ]]; then
            log_warn "  NOTE: EVENTHUB_CONNECTION_STRING was not set. If the Event Hub source is not connected, set EVENTHUB_CONNECTION_STRING and re-run to create a new connection."
        fi
        CREATED_EVENTSTREAMS["${name}"]="${stream_id}"
        i=$((i+1))
    done
}

# ── Step 6: Real-Time Dashboards ──────────────────────────────────────────────
create_dashboards() {
    local snapshot="$1" ws_id="$2" token="$3"
    local count; count=$(echo "${snapshot}" | jq '.realtime_dashboards | length')
    log_info "Creating ${count} Real-Time Dashboard(s)..."

    # Build old→new ID pairs for patching definitions (same logic as create_eventstreams)
    local old_ws_id
    old_ws_id=$(echo "${snapshot}" | jq -r '.workspace.id')
    local id_pairs=()
    for old_eh_key in "${!CREATED_EVENTHOUSES[@]}"; do
        [[ "${old_eh_key}" == orig:* ]] || continue
        local old_item_id="${old_eh_key#orig:}"
        local new_item_id="${CREATED_EVENTHOUSES[${old_eh_key}]}"
        id_pairs+=("${old_item_id}" "${new_item_id}")
    done
    local old_db_id new_db_id
    old_db_id=$(echo "${snapshot}" | jq -r '.kql_databases[0].id // empty')
    new_db_id="${CREATED_KQL_DATABASES["contoso-qs-db"]:-}"
    [[ -n "${old_db_id}" && -n "${new_db_id}" ]] && id_pairs+=("${old_db_id}" "${new_db_id}")

    # The dashboard also embeds the Eventhouse clusterUri (a hostname, not a GUID).
    # Extract the old URI from the snapshot definition and replace with the new one.
    local new_eh_id new_cluster_uri old_cluster_uri
    new_eh_id="${CREATED_EVENTHOUSES["contoso-qs-eh"]:-}"
    new_cluster_uri="${CREATED_KQL_CLUSTERS["${new_eh_id}"]:-}"
    old_cluster_uri=""
    if [[ -n "${new_cluster_uri}" && ${count} -gt 0 ]]; then
        local _snap_def _p_count _p_idx
        _snap_def=$(echo "${snapshot}" | jq '.realtime_dashboards[0].export_definition // {}')
        _p_count=$(echo "${_snap_def}" | jq '.definition.parts | length // 0')
        for (( _p_idx=0; _p_idx<_p_count; _p_idx++ )); do
            local _ptype _payload _decoded
            _ptype=$(echo "${_snap_def}" | jq -r ".definition.parts[${_p_idx}].payloadType // \"\"")
            if [[ "${_ptype}" == "InlineBase64" ]]; then
                _payload=$(echo "${_snap_def}" | jq -r ".definition.parts[${_p_idx}].payload // \"\"")
                _decoded=$(echo "${_payload}" | base64 -d 2>/dev/null || echo "")
                old_cluster_uri=$(echo "${_decoded}" | jq -r \
                    '[.dataSources[]? | select(.clusterUri?) | .clusterUri] | first // empty' \
                    2>/dev/null || true)
                [[ -n "${old_cluster_uri}" ]] && break
            fi
        done
        if [[ -n "${old_cluster_uri}" && "${old_cluster_uri}" != "${new_cluster_uri}" ]]; then
            log_info "  Patching cluster URI: ${old_cluster_uri} → ${new_cluster_uri}"
            id_pairs+=("${old_cluster_uri}" "${new_cluster_uri}")
        fi
    fi

    local i=0
    while [[ ${i} -lt ${count} ]]; do
        local dash name desc raw_def payload result dash_id
        dash=$(echo "${snapshot}" | jq ".realtime_dashboards[${i}]")
        name=$(echo "${dash}" | jq -r '.displayName')
        desc=$(echo "${dash}" | jq -r '.description // ""')
        raw_def=$(echo "${dash}" | jq '.export_definition // {}')

        # Patch workspace ID, Eventhouse/KQL DB item IDs, and cluster URI
        if echo "${raw_def}" | jq -e 'keys | length > 0' &>/dev/null 2>&1; then
            raw_def=$(patch_definition_raw "${raw_def}" \
                "${old_ws_id}" "${ws_id}" \
                "${id_pairs[@]}")
        fi

        log_info "  Creating Dashboard: ${name}"

        local has_def; has_def=$(echo "${raw_def}" | jq 'keys | length > 0')

        if [[ "${has_def}" == "true" ]]; then
            payload=$(jq -n \
                --arg n   "${name}" \
                --arg d   "${desc}" \
                --argjson def "${raw_def}" \
                '{displayName: $n, description: $d, definition: $def.definition}')
        else
            payload=$(jq -n \
                --arg n "${name}" \
                --arg d "${desc}" \
                '{displayName: $n, description: $d}')
        fi

        # Real-Time Dashboards use the /kqlDashboards endpoint
        local raw_dash_resp dash_http_code dash_result
        raw_dash_resp=$(mktemp)
        dash_http_code=$(curl -sS -o "${raw_dash_resp}" -w "%{http_code}" \
            -X POST \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" \
            -d "${payload}" \
            "${FABRIC_API_BASE}/workspaces/${ws_id}/kqlDashboards")
        dash_result=$(cat "${raw_dash_resp}"); rm -f "${raw_dash_resp}"

        if [[ "${dash_http_code}" -ge 200 && "${dash_http_code}" -lt 300 ]]; then
            dash_id=$(echo "${dash_result}" | jq -r '.id // empty')
        else
            local dash_err_code
            dash_err_code=$(echo "${dash_result}" | jq -r '.errorCode // ""' 2>/dev/null || true)
            log_warn "  Failed to create Dashboard: ${name} (HTTP ${dash_http_code}: ${dash_err_code})"
            i=$((i+1)); continue
        fi

        [[ -z "${dash_id}" ]] && { log_warn "  Could not extract ID for ${name}"; i=$((i+1)); continue; }
        log_ok "  Dashboard created: ${name} (${dash_id})"
        CREATED_DASHBOARDS["${name}"]="${dash_id}"
        i=$((i+1))
    done
}

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary() {
    local ws_id="$1"
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Recreation Complete${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  Workspace:  ${CYAN}${ws_id}${NC}"

    if [[ ${#CREATED_EVENTHOUSES[@]} -gt 0 ]]; then
        echo ""
        echo "  Eventhouses:"
        for name in "${!CREATED_EVENTHOUSES[@]}"; do
            [[ "${name}" == orig:* ]] && continue
            echo -e "    ${name}: ${CYAN}${CREATED_EVENTHOUSES[${name}]}${NC}"
        done
    fi

    if [[ ${#CREATED_KQL_DATABASES[@]} -gt 0 ]]; then
        echo ""
        echo "  KQL Databases:"
        for name in "${!CREATED_KQL_DATABASES[@]}"; do
            echo -e "    ${name}: ${CYAN}${CREATED_KQL_DATABASES[${name}]}${NC}"
        done
    fi

    if [[ ${#CREATED_EVENTSTREAMS[@]} -gt 0 ]]; then
        echo ""
        echo "  Eventstreams:"
        for name in "${!CREATED_EVENTSTREAMS[@]}"; do
            echo -e "    ${name}: ${CYAN}${CREATED_EVENTSTREAMS[${name}]}${NC}"
        done
    fi

    if [[ ${#CREATED_DASHBOARDS[@]} -gt 0 ]]; then
        echo ""
        echo "  Real-Time Dashboards:"
        for name in "${!CREATED_DASHBOARDS[@]}"; do
            echo -e "    ${name}: ${CYAN}${CREATED_DASHBOARDS[${name}]}${NC}"
        done
    fi

    echo ""
    echo -e "  Portal: ${CYAN}https://app.fabric.microsoft.com/groups/${ws_id}${NC}"
    echo ""
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    log_step "Microsoft Fabric Workspace – Recreation"

    check_prereqs

    local snapshot
    snapshot=$(cat "${SNAPSHOT_FILE}")

    log_info "Snapshot:  $(echo "${snapshot}" | jq -r '.exported_at')"
    log_info "Source:    $(echo "${snapshot}" | jq -r '.workspace.displayName')"

    if [[ "${DRY_RUN}" == "true" ]]; then
        print_plan "${snapshot}"
        exit 0
    fi

    log_info "Acquiring Fabric access token..."
    local token
    token=$(get_fabric_token)
    log_ok "Token acquired."

    log_step "Step 1/7: Workspace"
    create_workspace "${token}"

    log_step "Step 2/7: Eventhouses"
    create_eventhouses "${snapshot}" "${CREATED_WORKSPACE_ID}" "${token}"

    log_step "Step 3/7: KQL Database (auto-created by Eventhouse)"
    create_kql_databases "${CREATED_WORKSPACE_ID}" "${token}"

    log_step "Step 4/7: KQL Tables & Mappings"
    create_kql_schema "${CREATED_WORKSPACE_ID}" "${token}"

    log_step "Step 5/7: Cloud Connection"
    create_cloud_connection "${token}"

    log_step "Step 6/7: Eventstreams"
    create_eventstreams "${snapshot}" "${CREATED_WORKSPACE_ID}" "${token}"

    log_step "Step 7/7: Real-Time Dashboards"
    create_dashboards "${snapshot}" "${CREATED_WORKSPACE_ID}" "${token}"

    print_summary "${CREATED_WORKSPACE_ID}"
}

main
