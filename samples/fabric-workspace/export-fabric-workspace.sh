#!/usr/bin/env bash
#
# export-fabric-workspace.sh
#
# Exports the full configuration of a Microsoft Fabric workspace to a JSON
# snapshot file, including:
#   - Workspace metadata
#   - Eventhouse(s)
#   - KQL Database schemas (tables, columns, policies)
#   - Ingestion mappings (CSV, JSON, Avro …)
#   - Eventstream definition (including Event Hubs source details)
#   - Real-Time Dashboard definition
#
# Usage:
#   export FABRIC_WORKSPACE_ID="<your-workspace-id>"
#   ./export-fabric-workspace.sh
#
#   # Or with a config file:
#   ./export-fabric-workspace.sh --config my-config.env
#
# Output:
#   snapshot.json  (in the current directory, or path set by SNAPSHOT_FILE)
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ── Color helpers ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log_info()  { echo -e "${CYAN}[INFO]${NC}  $*" >&2; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*" >&2; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()  { echo -e "\n${CYAN}──────────────────────────────────${NC}" >&2; echo -e "${CYAN}  $*${NC}" >&2; echo -e "${CYAN}──────────────────────────────────${NC}" >&2; }

# ── Load optional config file ────────────────────────────────────────────────
CONFIG_FILE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config) CONFIG_FILE="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 [--config <config-file>]"
            echo ""
            echo "Required:"
            echo "  FABRIC_WORKSPACE_ID   The workspace to export"
            echo ""
            echo "Optional:"
            echo "  SNAPSHOT_FILE         Output path (default: snapshot.json in current dir)"
            exit 0 ;;
        *) log_error "Unknown option: $1"; exit 1 ;;
    esac
done

if [[ -n "${CONFIG_FILE}" ]]; then
    [[ -f "${CONFIG_FILE}" ]] || { log_error "Config file not found: ${CONFIG_FILE}"; exit 1; }
    log_info "Loading config from ${CONFIG_FILE}"
    # shellcheck disable=SC1090
    source "${CONFIG_FILE}"
else
    # Auto-detect a config file in the same directory as the script
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    for _auto in "${SCRIPT_DIR}/my-config.env" "${SCRIPT_DIR}/sample-config.env"; do
        if [[ -f "${_auto}" ]]; then
            log_info "Auto-loading config from ${_auto}"
            # shellcheck disable=SC1090
            source "${_auto}"
            break
        fi
    done
fi

# ── Configuration ─────────────────────────────────────────────────────────────
FABRIC_WORKSPACE_ID="${FABRIC_WORKSPACE_ID:-}"
SNAPSHOT_FILE="${SNAPSHOT_FILE:-snapshot.json}"
FABRIC_API_BASE="https://api.fabric.microsoft.com/v1"

# ── Prereq check ─────────────────────────────────────────────────────────────
check_prereqs() {
    local missing=0
    for cmd in az curl jq; do
        command -v "${cmd}" &>/dev/null || { log_error "${cmd} not found"; missing=1; }
    done
    [[ -n "${FABRIC_WORKSPACE_ID}" ]] || { log_error "FABRIC_WORKSPACE_ID must be set"; missing=1; }
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
    || { log_warn "Could not obtain Kusto token for ${cluster_uri}"; echo ""; }
}

# ── HTTP helpers ──────────────────────────────────────────────────────────────
fabric_get() {
    # Returns body on 2xx, empty string on 404, exits on other errors
    local path="$1" token="$2"
    local body_file http_code body
    body_file=$(mktemp)
    http_code=$(curl -s -o "${body_file}" -w "%{http_code}" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        "${FABRIC_API_BASE}${path}")
    body=$(cat "${body_file}"); rm -f "${body_file}"

    if [[ "${http_code}" == "404" ]]; then echo ""; return; fi
    if [[ "${http_code}" -ge 200 && "${http_code}" -lt 300 ]]; then echo "${body}"; return; fi
    log_error "GET ${path} → HTTP ${http_code}: ${body}" >&2
    echo ""
}

fabric_post() {
    # POST that handles 202 long-running; returns final body
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
            retry_after="${retry_after:-3}"
            [[ -n "${location}" ]] && { poll_operation "${location}" "${token}" "${retry_after}"; return $?; }
        fi
        echo "${body}"; return
    fi
    log_warn "POST ${path} → HTTP ${http_code}: ${body}" >&2
    echo ""
}

poll_operation() {
    local url="$1" token="$2" interval="${3:-5}"
    local attempts=0 max=60 body_file http_code body status
    while [[ ${attempts} -lt ${max} ]]; do
        sleep "${interval}"; attempts=$((attempts+1))
        body_file=$(mktemp)
        http_code=$(curl -s -o "${body_file}" -w "%{http_code}" \
            -H "Authorization: Bearer ${token}" "${url}")
        body=$(cat "${body_file}"); rm -f "${body_file}"
        if [[ "${http_code}" -ge 200 && "${http_code}" -lt 300 ]]; then
            status=$(echo "${body}" | jq -r '.status // empty' 2>/dev/null)
            case "${status,,}" in
                succeeded) echo "${body}"; return 0 ;;
                failed)    log_warn "Operation failed: ${body}" >&2; return 1 ;;
                *)         log_info "  status: ${status:-unknown} (${attempts}/${max})" ;;
            esac
        fi
    done
    log_error "Operation timed out."; return 1
}

kusto_mgmt() {
    # Runs a KQL management command via the Kusto REST API.
    # Usage: kusto_mgmt <cluster_uri> <database> <kql_command> <kusto_token>
    local cluster="$1" database="$2" command="$3" token="$4"
    local body_file http_code body

    [[ -z "${token}" ]] && { echo "{}"; return; }

    local payload
    payload=$(jq -n --arg db "${database}" --arg csl "${command}" \
        '{"db": $db, "csl": $csl, "properties": {"Options": {"servertimeout": "00:01:00"}}}')

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
        log_warn "Kusto mgmt (${command}) → HTTP ${http_code}: ${body}" >&2
        echo "{}"
    fi
}

# ── List helpers ──────────────────────────────────────────────────────────────
# Fabric list responses use either .value or .items
fabric_list() {
    local path="$1" token="$2"
    local body
    body=$(fabric_get "${path}" "${token}")
    [[ -z "${body}" ]] && { echo "[]"; return; }
    echo "${body}" | jq '[.value // .items // [] | .[]]'
}

# ── Extract definition payload (handles 202 + base64-encoded parts) ───────────
get_item_definition() {
    local workspace_id="$1" item_id="$2" token="$3"

    local result
    result=$(fabric_post \
        "/workspaces/${workspace_id}/items/${item_id}/getDefinition" \
        "${token}" "{}")
    [[ -z "${result}" ]] && { echo "{}"; return; }

    # The definition is in result.definition.parts[] as base64-encoded content
    # Return the full object so we can re-use it verbatim on recreation
    echo "${result}"
}

get_eventstream_definition() {
    local workspace_id="$1" item_id="$2" token="$3"

    local result
    result=$(fabric_post \
        "/workspaces/${workspace_id}/eventstreams/${item_id}/getDefinition" \
        "${token}" "{}")
    [[ -z "${result}" ]] && { echo "{}"; return; }
    echo "${result}"
}

# ── Export sections ───────────────────────────────────────────────────────────
export_workspace() {
    local token="$1"
    log_info "Fetching workspace metadata..."
    local ws
    ws=$(fabric_get "/workspaces/${FABRIC_WORKSPACE_ID}" "${token}")
    [[ -z "${ws}" ]] && { log_error "Workspace ${FABRIC_WORKSPACE_ID} not found."; exit 1; }
    log_ok "Workspace: $(echo "${ws}" | jq -r '.displayName')"
    echo "${ws}"
}

export_eventhouses() {
    local workspace_id="$1" token="$2"
    log_info "Fetching Eventhouses..."

    local houses
    houses=$(fabric_list "/workspaces/${workspace_id}/eventhouses" "${token}")
    local count; count=$(echo "${houses}" | jq 'length')
    log_ok "Found ${count} Eventhouse(s)"

    local result="[]"
    local i=0
    while [[ ${i} -lt ${count} ]]; do
        local house
        house=$(echo "${houses}" | jq ".[${i}]")
        local house_id
        house_id=$(echo "${house}" | jq -r '.id')
        log_info "  Eventhouse: $(echo "${house}" | jq -r '.displayName') (${house_id})"

        # Get detailed view (includes queryServiceUri)
        local detail
        detail=$(fabric_get "/workspaces/${workspace_id}/eventhouses/${house_id}" "${token}")
        [[ -n "${detail}" ]] && house="${detail}"

        result=$(echo "${result}" | jq --argjson h "${house}" '. + [$h]')
        i=$((i+1))
    done
    echo "${result}"
}

export_kql_databases() {
    local workspace_id="$1" token="$2" eventhouse_list="$3"
    log_info "Fetching KQL Databases..."

    local dbs
    dbs=$(fabric_list "/workspaces/${workspace_id}/kqlDatabases" "${token}")
    local count; count=$(echo "${dbs}" | jq 'length')
    log_ok "Found ${count} KQL Database(s)"

    # Build a map of eventhouse queryServiceUri by ID (for Kusto access)
    local cluster_map
    cluster_map=$(echo "${eventhouse_list}" | jq \
        'map(select(.properties.queryServiceUri != null)) |
         map({key: .id, value: .properties.queryServiceUri}) |
         from_entries')

    local result="[]"
    local i=0
    while [[ ${i} -lt ${count} ]]; do
        local db db_id db_name parent_id cluster_uri
        db=$(echo "${dbs}" | jq ".[${i}]")
        db_id=$(echo "${db}"  | jq -r '.id')
        db_name=$(echo "${db}" | jq -r '.displayName')
        parent_id=$(echo "${db}" | jq -r '.properties.parentEventhouseItemId // empty')
        cluster_uri=$(echo "${cluster_map}" | jq -r --arg k "${parent_id}" '.[$k] // empty')

        log_info "  KQL DB: ${db_name} (parent eventhouse: ${parent_id:-unknown})"

        # Enrich with schema and mappings via Kusto mgmt API
        local schema_raw mappings_raw schema_obj tables_schema mappings_obj
        schema_obj="{}"
        tables_schema="[]"
        mappings_obj="{}"

        if [[ -n "${cluster_uri}" ]]; then
            local kusto_token
            kusto_token=$(get_kusto_token "${cluster_uri}")

            if [[ -n "${kusto_token}" ]]; then
                log_info "    Fetching schema for ${db_name}..."
                schema_raw=$(kusto_mgmt "${cluster_uri}" "${db_name}" ".show database ['${db_name}'] schema as json" "${kusto_token}")
                schema_obj=$(echo "${schema_raw}" | jq -r '.Tables[0].Rows[0][0] // "{}"' 2>/dev/null | jq '.' 2>/dev/null || echo "{}")

                log_info "    Fetching tables for ${db_name}..."
                tables_raw=$(kusto_mgmt "${cluster_uri}" "${db_name}" ".show tables" "${kusto_token}")
                tables_schema=$(echo "${tables_raw}" | jq '.Tables[0].Rows // []' 2>/dev/null || echo "[]")

                # Fetch ingestion mappings per table (wildcards are not supported in KQL)
                # Columns returned by .show table <T> ingestion mappings:
                #   [0]=Name, [1]=Kind, [2]=Mapping (JSON), [3]=LastUpdatedOn, [4]=Database, [5]=Table
                log_info "    Fetching ingestion mappings for ${db_name}..."
                local table_names
                table_names=$(echo "${tables_raw}" | jq -r '.Tables[0].Rows[]? | .[0]' 2>/dev/null || true)
                mappings_obj="[]"
                while IFS= read -r tname; do
                    [[ -z "${tname}" ]] && continue
                    local tmap_raw tmap
                    tmap_raw=$(kusto_mgmt "${cluster_uri}" "${db_name}" \
                        ".show table ['${tname}'] ingestion mappings" "${kusto_token}")
                    tmap=$(echo "${tmap_raw}" | jq \
                        --arg tbl "${tname}" '
                        if (.Tables[0].Rows // []) | length > 0 then
                            [.Tables[0].Rows[] |
                                {
                                    table:   $tbl,
                                    name:    .[0],
                                    kind:    .[1],
                                    mapping: .[2]
                                }]
                        else [] end' 2>/dev/null || echo "[]")
                    mappings_obj=$(echo "${mappings_obj}" | jq --argjson m "${tmap}" '. + $m')
                done <<< "${table_names}"

                log_ok "    Schema + mappings captured for ${db_name}"
            else
                log_warn "    Skipping Kusto schema (no token for ${cluster_uri})"
            fi
        else
            log_warn "    No cluster URI found for ${db_name} – schema not exported"
        fi

        local enriched
        enriched=$(echo "${db}" | jq \
            --argjson schema   "${schema_obj}" \
            --argjson tables   "${tables_schema}" \
            --argjson mappings "${mappings_obj}" \
            '.export_schema   = $schema   |
             .export_tables   = $tables   |
             .export_mappings = $mappings')

        result=$(echo "${result}" | jq --argjson d "${enriched}" '. + [$d]')
        i=$((i+1))
    done
    echo "${result}"
}

export_eventstreams() {
    local workspace_id="$1" token="$2"
    log_info "Fetching Eventstreams..."

    local streams
    streams=$(fabric_list "/workspaces/${workspace_id}/eventstreams" "${token}")
    local count; count=$(echo "${streams}" | jq 'length')
    log_ok "Found ${count} Eventstream(s)"

    local result="[]"
    local i=0
    while [[ ${i} -lt ${count} ]]; do
        local stream stream_id stream_name
        stream=$(echo "${streams}" | jq ".[${i}]")
        stream_id=$(echo "${stream}" | jq -r '.id')
        stream_name=$(echo "${stream}" | jq -r '.displayName')

        log_info "  Fetching definition for Eventstream: ${stream_name}..."
        local definition
        definition=$(get_eventstream_definition "${workspace_id}" "${stream_id}" "${token}")

        local enriched
        enriched=$(echo "${stream}" | jq --argjson def "${definition}" '.export_definition = $def')
        result=$(echo "${result}" | jq --argjson s "${enriched}" '. + [$s]')
        log_ok "  Eventstream captured: ${stream_name}"
        i=$((i+1))
    done
    echo "${result}"
}

export_realtime_dashboards() {
    local workspace_id="$1" token="$2"
    log_info "Fetching Real-Time Dashboards..."

    # Real-Time Dashboards are exposed under /kqlDashboards in the Fabric REST API
    local items
    items=$(fabric_list "/workspaces/${workspace_id}/kqlDashboards" "${token}")
    local count; count=$(echo "${items}" | jq 'length')
    log_ok "Found ${count} Real-Time Dashboard(s)"

    local result="[]"
    local i=0
    while [[ ${i} -lt ${count} ]]; do
        local item item_id item_name
        item=$(echo "${items}" | jq ".[${i}]")
        item_id=$(echo "${item}" | jq -r '.id')
        item_name=$(echo "${item}" | jq -r '.displayName')

        log_info "  Fetching definition for Dashboard: ${item_name}..."
        local definition
        definition=$(fabric_post \
            "/workspaces/${workspace_id}/kqlDashboards/${item_id}/getDefinition" \
            "${token}" "{}")
        [[ -z "${definition}" ]] && definition="{}"

        local enriched
        enriched=$(echo "${item}" | jq --argjson def "${definition}" '.export_definition = $def')
        result=$(echo "${result}" | jq --argjson d "${enriched}" '. + [$d]')
        log_ok "  Dashboard captured: ${item_name}"
        i=$((i+1))
    done
    echo "${result}"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    log_step "Microsoft Fabric Workspace – Export"

    check_prereqs

    log_info "Acquiring Fabric access token..."
    local token
    token=$(get_fabric_token)
    log_ok "Token acquired."

    log_step "Step 1/5: Workspace"
    local workspace
    workspace=$(export_workspace "${token}")
    local workspace_name
    workspace_name=$(echo "${workspace}" | jq -r '.displayName')

    log_step "Step 2/5: Eventhouses"
    local eventhouses
    eventhouses=$(export_eventhouses "${FABRIC_WORKSPACE_ID}" "${token}")

    log_step "Step 3/5: KQL Databases"
    local kql_databases
    kql_databases=$(export_kql_databases "${FABRIC_WORKSPACE_ID}" "${token}" "${eventhouses}")

    log_step "Step 4/5: Eventstreams"
    local eventstreams
    eventstreams=$(export_eventstreams "${FABRIC_WORKSPACE_ID}" "${token}")

    log_step "Step 5/5: Real-Time Dashboards"
    local dashboards
    dashboards=$(export_realtime_dashboards "${FABRIC_WORKSPACE_ID}" "${token}")

    # ── Assemble snapshot ─────────────────────────────────────────────────────
    local snapshot
    snapshot=$(jq -n \
        --arg   exported_at  "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        --arg   schema_ver   "1.0" \
        --argjson workspace   "${workspace}" \
        --argjson eventhouses "${eventhouses}" \
        --argjson kql_dbs     "${kql_databases}" \
        --argjson eventstreams "${eventstreams}" \
        --argjson dashboards   "${dashboards}" \
        '{
            schema_version: $schema_ver,
            exported_at:    $exported_at,
            workspace:      $workspace,
            eventhouses:    $eventhouses,
            kql_databases:  $kql_dbs,
            eventstreams:   $eventstreams,
            realtime_dashboards: $dashboards
        }')

    echo "${snapshot}" > "${SNAPSHOT_FILE}"

    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Export Complete${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  Source workspace:    ${CYAN}${workspace_name}${NC} (${FABRIC_WORKSPACE_ID})"
    echo -e "  Eventhouses:         ${CYAN}$(echo "${eventhouses}" | jq 'length')${NC}"
    echo -e "  KQL Databases:       ${CYAN}$(echo "${kql_databases}" | jq 'length')${NC}"
    echo -e "  Eventstreams:        ${CYAN}$(echo "${eventstreams}" | jq 'length')${NC}"
    echo -e "  Real-Time Dashboards:${CYAN}$(echo "${dashboards}" | jq 'length')${NC}"
    echo ""
    echo -e "  Snapshot saved to:   ${CYAN}${SNAPSHOT_FILE}${NC}"
    echo ""
    echo -e "  Next step: run ${CYAN}recreate-fabric-workspace.sh --snapshot ${SNAPSHOT_FILE}${NC}"
    echo ""
}

main
