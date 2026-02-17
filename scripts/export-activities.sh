#!/bin/bash
#
# Export Copilot Studio Agent Activities - Enhanced Version
# Features:
#   - Analytics and insights extraction
#   - Tool usage statistics
#   - Execution time metrics
#   - HTML dashboard report
#   - Date range filtering
#   - Config file support
#
# Usage: ./export-copilot-activities-v2.sh [options]
#

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config/copilot-export.json"

# Source shared auth module
source "${SCRIPT_DIR}/auth.sh"

# Default configuration - Set via environment variables or config file
# Required: COPILOT_ENV_URL, COPILOT_BOT_ID, COPILOT_TENANT_ID
DEFAULT_ENV_URL="${COPILOT_ENV_URL:-}"
DEFAULT_BOT_ID="${COPILOT_BOT_ID:-}"
DEFAULT_TENANT="${COPILOT_TENANT_ID:-}"
OUTPUT_DIR="./reports"
RESOURCE="https://api.powerplatform.com"
APP_ID="${COPILOT_APP_ID:-04b07795-8ddb-461a-bbee-02f9e1bf7b46}"  # Microsoft Azure CLI (default)
PAGE_SIZE=500
VERBOSE=false
DEFAULT_CURL_CONNECT_TIMEOUT=10
DEFAULT_CURL_MAX_TIME=120
PVA_URL_CACHE_ENV_ID=""
PVA_URL_CACHE=""

# Parsed URL values
PARSED_ENV_ID=""
PARSED_BOT_GUID=""
PARSED_CONV_ID=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

print_header() {
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║     Copilot Studio Agent Activity Export v2.0              ║${NC}"
    echo -e "${CYAN}║     Enhanced Analytics & Reporting                         ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

print_status() { echo -e "${GREEN}[✓]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }
print_info() { echo -e "${BLUE}[i]${NC} $1"; }
print_debug() { [ "$VERBOSE" = true ] && echo -e "${CYAN}[DEBUG]${NC} $1" >&2; }

cleanup() {
    # auth.sh manages its own session token cleanup via trap
    :
}
trap cleanup EXIT

require_option_value() {
    local flag="$1"
    local value="${2:-}"
    if [ -z "$value" ] || [[ "$value" == -* ]]; then
        print_error "Option $flag requires a value"
        exit 1
    fi
}

http_request() {
    local method="$1"
    local url="$2"
    shift 2

    curl -sS \
        --connect-timeout "$DEFAULT_CURL_CONNECT_TIMEOUT" \
        --max-time "$DEFAULT_CURL_MAX_TIME" \
        --retry 2 \
        --retry-delay 1 \
        --retry-all-errors \
        -X "$method" "$url" "$@"
}

ensure_login() {
    local profile="${PISTUDIO_ACTIVE_PROFILE:-default}"
    if pistudio_has_valid_token "$profile"; then
        return 0
    fi
    # Try az/m365 fallback — get_access_token checks all backends
    local test_token
    test_token=$(get_access_token "https://management.azure.com" 2>/dev/null) || true
    if [[ -n "$test_token" ]]; then
        return 0
    fi
    print_warning "Login required..."
    pistudio_login "$profile" "${TENANT:-common}"
}

print_authenticated_as() {
    local user
    user=$(get_active_user || true)
    if [ -n "$user" ]; then
        print_status "Authenticated as: $user"
    fi
}

# Verbose curl wrapper - shows command in verbose mode
vcurl() {
    if [ "$VERBOSE" = true ]; then
        echo -e "${CYAN}[curl]${NC} curl $*" >&2
    fi
    curl -sS \
        --connect-timeout "$DEFAULT_CURL_CONNECT_TIMEOUT" \
        --max-time "$DEFAULT_CURL_MAX_TIME" \
        --retry 2 \
        --retry-delay 1 \
        --retry-all-errors \
        "$@"
}

# ═══════════════════════════════════════════════════════════════
# URL PARSING - Extract IDs from Copilot Studio URLs
# ═══════════════════════════════════════════════════════════════

# Parse Copilot Studio URL and extract environment ID, bot ID, and conversation ID
# Example URL: https://copilotstudio.preview.microsoft.com/environments/<env-id>/bots/<bot-guid>/activity/19:abc@thread.v2
parse_copilot_url() {
    local url="$1"

    # Extract environment ID (GUID after /environments/)
    if [[ "$url" =~ environments/([a-f0-9-]{36}) ]]; then
        PARSED_ENV_ID="${BASH_REMATCH[1]}"
        print_debug "Parsed environment ID: $PARSED_ENV_ID"
    fi

    # Extract bot GUID (after /bots/)
    if [[ "$url" =~ bots/([a-f0-9-]{36}) ]]; then
        PARSED_BOT_GUID="${BASH_REMATCH[1]}"
        print_debug "Parsed bot GUID: $PARSED_BOT_GUID"
    fi

    # Extract conversation ID (after /activity/ - URL encoded)
    if [[ "$url" =~ activity/([^/\?]+) ]]; then
        # URL decode the conversation ID
        PARSED_CONV_ID=$(printf '%b' "${BASH_REMATCH[1]//%/\\x}")
        print_debug "Parsed conversation ID: $PARSED_CONV_ID"
    fi

    # Extract from canvas URL format (different pattern)
    # https://copilotstudio.preview.microsoft.com/environments/xxx/bots/xxx/canvas
    if [[ "$url" =~ /canvas ]]; then
        print_debug "Canvas URL detected - no conversation ID"
    fi
}

# Resolve bot GUID to schema name
resolve_bot_guid_to_schema() {
    local dataverse_url="$1"
    local bot_guid="$2"

    local dv_token=$(get_access_token "${dataverse_url}")

    if [ -z "$dv_token" ]; then
        return 1
    fi

    curl -s "${dataverse_url}/api/data/v9.2/bots?\$select=schemaname,name&\$filter=botid%20eq%20'${bot_guid}'" \
        -H "Authorization: Bearer $dv_token" \
        -H "OData-MaxVersion: 4.0" \
        -H "Accept: application/json" | jq -r '.value[0].schemaname // empty'
}

# ═══════════════════════════════════════════════════════════════
# OPEN IN BROWSER - Launch Copilot Studio UI
# ═══════════════════════════════════════════════════════════════

open_in_browser() {
    local env_id="$1"
    local bot_guid="$2"
    local conv_id="$3"

    local base_url="https://copilotstudio.preview.microsoft.com"
    local url=""

    if [ -n "$conv_id" ]; then
        # URL encode conversation ID
        local encoded_conv=$(printf '%s' "$conv_id" | jq -sRr @uri)
        url="${base_url}/environments/${env_id}/bots/${bot_guid}/activity/${encoded_conv}"
    elif [ -n "$bot_guid" ]; then
        url="${base_url}/environments/${env_id}/bots/${bot_guid}/canvas"
    else
        url="${base_url}/environments/${env_id}"
    fi

    print_info "Opening: $url"

    # Cross-platform open command
    if command -v open &> /dev/null; then
        open "$url"  # macOS
    elif command -v xdg-open &> /dev/null; then
        xdg-open "$url"  # Linux
    elif command -v start &> /dev/null; then
        start "$url"  # Windows
    else
        print_warning "Could not detect browser opener. URL: $url"
    fi
}

# ═══════════════════════════════════════════════════════════════
# CLONE AGENT - Duplicate an existing agent with a new name
# ═══════════════════════════════════════════════════════════════

clone_agent() {
    local dataverse_url="$1"
    local source_schema="$2"
    local new_name="$3"

    print_info "Cloning agent '$source_schema' as '$new_name'..."

    local dv_token=$(get_access_token "${dataverse_url}")

    if [ -z "$dv_token" ]; then
        print_error "Could not get Dataverse token"
        return 1
    fi

    # Get source agent details
    local source=$(curl -s "${dataverse_url}/api/data/v9.2/botcomponents?\$select=name,schemaname,description,data,componenttype&\$expand=parentbotid(\$select=botid,schemaname)&\$filter=schemaname%20eq%20'${source_schema}'" \
        -H "Authorization: Bearer $dv_token" \
        -H "OData-MaxVersion: 4.0" \
        -H "Accept: application/json")

    local source_data=$(echo "$source" | jq -r '.value[0].data // empty')
    local source_desc=$(echo "$source" | jq -r '.value[0].description // empty')
    local parent_bot_id=$(echo "$source" | jq -r '.value[0].parentbotid.botid // empty')
    local parent_schema=$(echo "$source" | jq -r '.value[0].parentbotid.schemaname // empty')

    if [ -z "$source_data" ] || [ -z "$parent_bot_id" ]; then
        print_error "Could not find source agent or missing data"
        return 1
    fi

    # Generate new schema name
    local random_suffix=$(cat /dev/urandom | LC_ALL=C tr -dc 'a-zA-Z0-9' | head -c 3)
    local new_schema="${parent_schema}.agent.Agent_${random_suffix}"

    # Create clone
    local payload=$(jq -n \
        --arg name "$new_name" \
        --arg schema "$new_schema" \
        --arg data "$source_data" \
        --arg desc "Clone of ${source_schema}: ${source_desc}" \
        --arg parentbot "/bots(${parent_bot_id})" \
        '{
            "name": $name,
            "schemaname": $schema,
            "componenttype": 9,
            "description": $desc,
            "data": $data,
            "parentbotid@odata.bind": $parentbot
        }')

    local response=$(curl -s -w "\n%{http_code}" \
        -X POST "${dataverse_url}/api/data/v9.2/botcomponents" \
        -H "Authorization: Bearer $dv_token" \
        -H "OData-MaxVersion: 4.0" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -H "Prefer: return=representation" \
        -d "$payload")

    local http_code=$(echo "$response" | tail -1)
    local body=$(echo "$response" | sed '$d')

    if [ "$http_code" = "201" ]; then
        print_status "Cloned successfully!"
        print_info "New agent: $new_name"
        print_info "Schema: $new_schema"
        return 0
    else
        print_error "Clone failed (HTTP $http_code)"
        echo "$body" | jq -r '.error.message // .' 2>/dev/null
        return 1
    fi
}

# ═══════════════════════════════════════════════════════════════
# DIFF AGENTS - Compare two agent configurations
# ═══════════════════════════════════════════════════════════════

diff_agents() {
    local dataverse_url="$1"
    local schema1="$2"
    local schema2="$3"

    print_info "Comparing agents..."
    print_info "  Agent 1: $schema1"
    print_info "  Agent 2: $schema2"
    echo ""

    local dv_token=$(get_access_token "${dataverse_url}")

    if [ -z "$dv_token" ]; then
        print_error "Could not get Dataverse token"
        return 1
    fi

    # Get both agents
    local agent1=$(curl -s "${dataverse_url}/api/data/v9.2/botcomponents?\$select=name,data,description&\$filter=schemaname%20eq%20'${schema1}'" \
        -H "Authorization: Bearer $dv_token" \
        -H "OData-MaxVersion: 4.0" \
        -H "Accept: application/json" | jq -r '.value[0].data // empty')

    local agent2=$(curl -s "${dataverse_url}/api/data/v9.2/botcomponents?\$select=name,data,description&\$filter=schemaname%20eq%20'${schema2}'" \
        -H "Authorization: Bearer $dv_token" \
        -H "OData-MaxVersion: 4.0" \
        -H "Accept: application/json" | jq -r '.value[0].data // empty')

    if [ -z "$agent1" ]; then
        print_error "Could not find agent: $schema1"
        return 1
    fi

    if [ -z "$agent2" ]; then
        print_error "Could not find agent: $schema2"
        return 1
    fi

    # Create temp files and diff
    local tmp1=$(mktemp)
    local tmp2=$(mktemp)
    echo "$agent1" > "$tmp1"
    echo "$agent2" > "$tmp2"

    if diff -q "$tmp1" "$tmp2" > /dev/null 2>&1; then
        print_status "Agents are identical"
    else
        print_warning "Agents differ:"
        echo ""
        diff --color=always -u "$tmp1" "$tmp2" || true
    fi

    rm -f "$tmp1" "$tmp2"
}

# ═══════════════════════════════════════════════════════════════
# BACKUP/RESTORE - Export and import all agents
# ═══════════════════════════════════════════════════════════════

backup_agents() {
    local dataverse_url="$1"
    local bot_schema="$2"
    local backup_dir="$3"

    mkdir -p "$backup_dir"

    print_info "Backing up agents to: $backup_dir"

    local dv_token=$(get_access_token "${dataverse_url}")

    if [ -z "$dv_token" ]; then
        print_error "Could not get Dataverse token"
        return 1
    fi

    # Get all agents for the bot
    local filter=""
    if [ -n "$bot_schema" ]; then
        filter="startswith(schemaname,'${bot_schema}.agent.')"
    else
        filter="contains(schemaname,'.agent.')"
    fi

    local agents=$(curl -s "${dataverse_url}/api/data/v9.2/botcomponents?\$select=name,schemaname,description,data&\$filter=${filter}" \
        -H "Authorization: Bearer $dv_token" \
        -H "OData-MaxVersion: 4.0" \
        -H "Accept: application/json")

    local count=$(echo "$agents" | jq '.value | length')
    print_info "Found $count agent(s) to backup"

    # Save each agent
    echo "$agents" | jq -c '.value[]' | while read -r agent; do
        local name=$(echo "$agent" | jq -r '.name')
        local schema=$(echo "$agent" | jq -r '.schemaname')
        local data=$(echo "$agent" | jq -r '.data')
        local desc=$(echo "$agent" | jq -r '.description // empty')

        # Save YAML config
        local safe_name=$(echo "$name" | tr ' ' '_' | tr -cd '[:alnum:]_-')
        local yaml_file="${backup_dir}/${safe_name}.yaml"
        echo "$data" > "$yaml_file"

        # Save metadata
        local meta_file="${backup_dir}/${safe_name}.meta.json"
        echo "$agent" | jq '{name, schemaname, description}' > "$meta_file"

        print_status "Backed up: $name -> $yaml_file"
    done

    # Save manifest
    local manifest="${backup_dir}/manifest.json"
    echo "$agents" | jq '{backup_date: now | todate, count: (.value | length), agents: [.value[] | {name, schemaname}]}' > "$manifest"

    print_status "Backup complete: $count agent(s)"
    print_info "Manifest: $manifest"
}

restore_agents() {
    local dataverse_url="$1"
    local bot_schema="$2"
    local backup_dir="$3"

    if [ ! -d "$backup_dir" ]; then
        print_error "Backup directory not found: $backup_dir"
        return 1
    fi

    local manifest="${backup_dir}/manifest.json"
    if [ ! -f "$manifest" ]; then
        print_error "Manifest not found: $manifest"
        return 1
    fi

    print_info "Restoring from: $backup_dir"

    local dv_token=$(get_access_token "${dataverse_url}")

    if [ -z "$dv_token" ]; then
        print_error "Could not get Dataverse token"
        return 1
    fi

    # Get parent bot ID
    local parent_bot_id=$(get_parent_bot_id "$dataverse_url" "$bot_schema")
    if [ -z "$parent_bot_id" ]; then
        print_error "Could not find parent bot: $bot_schema"
        return 1
    fi

    local restored=0

    for yaml_file in "$backup_dir"/*.yaml; do
        [ -f "$yaml_file" ] || continue

        local base=$(basename "$yaml_file" .yaml)
        local meta_file="${backup_dir}/${base}.meta.json"

        if [ ! -f "$meta_file" ]; then
            print_warning "No metadata for $yaml_file, skipping"
            continue
        fi

        local name=$(jq -r '.name' "$meta_file")
        local desc=$(jq -r '.description // empty' "$meta_file")
        local data=$(cat "$yaml_file")

        # Check if agent already exists
        local existing=$(curl -s "${dataverse_url}/api/data/v9.2/botcomponents?\$select=botcomponentid&\$filter=name%20eq%20'$(printf '%s' "$name" | jq -sRr @uri)'" \
            -H "Authorization: Bearer $dv_token" \
            -H "OData-MaxVersion: 4.0" \
            -H "Accept: application/json" | jq -r '.value[0].botcomponentid // empty')

        if [ -n "$existing" ]; then
            print_warning "Agent '$name' already exists, updating..."
            # Update existing
            curl -s -X PATCH "${dataverse_url}/api/data/v9.2/botcomponents(${existing})" \
                -H "Authorization: Bearer $dv_token" \
                -H "OData-MaxVersion: 4.0" \
                -H "Content-Type: application/json" \
                -d "{\"data\": $(echo "$data" | jq -Rs .)}" > /dev/null
            print_status "Updated: $name"
        else
            # Create new
            # Prefer preserving the original suffix (Agent_XXX) from metadata to keep stable schema names across restores.
            local meta_schema
            meta_schema=$(jq -r '.schemaname // empty' "$meta_file" 2>/dev/null || true)
            local leaf="${meta_schema##*.}"
            leaf=$(echo "$leaf" | tr -cd '[:alnum:]_-')

            local new_schema=""
            if [ -n "$leaf" ]; then
                new_schema="${bot_schema}.agent.${leaf}"

                # If schema already exists, fall back to random.
                local schema_exists
                schema_exists=$(curl -s "${dataverse_url}/api/data/v9.2/botcomponents?\$select=botcomponentid&\$filter=schemaname%20eq%20'${new_schema}'" \
                    -H "Authorization: Bearer $dv_token" \
                    -H "OData-MaxVersion: 4.0" \
                    -H "Accept: application/json" | jq -r '.value[0].botcomponentid // empty')
                if [ -n "$schema_exists" ]; then
                    new_schema=""
                fi
            fi

            if [ -z "$new_schema" ]; then
                local random_suffix
                random_suffix=$(cat /dev/urandom | LC_ALL=C tr -dc 'a-zA-Z0-9' | head -c 3)
                new_schema="${bot_schema}.agent.Agent_${random_suffix}"
            fi

            local payload=$(jq -n \
                --arg name "$name" \
                --arg schema "$new_schema" \
                --arg data "$data" \
                --arg desc "$desc" \
                --arg parentbot "/bots(${parent_bot_id})" \
                '{
                    "name": $name,
                    "schemaname": $schema,
                    "componenttype": 9,
                    "description": $desc,
                    "data": $data,
                    "parentbotid@odata.bind": $parentbot
                }')

            curl -s -X POST "${dataverse_url}/api/data/v9.2/botcomponents" \
                -H "Authorization: Bearer $dv_token" \
                -H "OData-MaxVersion: 4.0" \
                -H "Content-Type: application/json" \
                -d "$payload" > /dev/null

            print_status "Created: $name ($new_schema)"
        fi

        ((restored++))
    done

    print_status "Restore complete: $restored agent(s)"
}

# ═══════════════════════════════════════════════════════════════
# SEARCH CONVERSATIONS - Find conversations by content
# ═══════════════════════════════════════════════════════════════

search_conversations() {
    local dataverse_url="$1"
    local search_term="$2"
    local days="${3:-7}"

    print_info "Searching conversations for: '$search_term' (last $days days)"

    local dv_token=$(get_access_token "${dataverse_url}")

    if [ -z "$dv_token" ]; then
        print_error "Could not get Dataverse token"
        return 1
    fi

    # Calculate date filter
    local since_date=$(date -v-${days}d +%Y-%m-%dT00:00:00Z 2>/dev/null || date -d "-$days days" +%Y-%m-%dT00:00:00Z)

    # Search in conversation transcripts
    local results=$(curl -s "${dataverse_url}/api/data/v9.2/conversationtranscripts?\$select=name,createdon,content&\$filter=createdon%20ge%20${since_date}%20and%20schemaname%20eq%20'pva-studio'&\$orderby=createdon%20desc&\$top=100" \
        -H "Authorization: Bearer $dv_token" \
        -H "OData-MaxVersion: 4.0" \
        -H "Accept: application/json")

    local count=$(echo "$results" | jq '.value | length // 0')

    if [ "$count" = "0" ] || [ "$count" = "null" ]; then
        echo ""
        print_warning "No transcripts found in the last $days days"
        return 0
    fi

    print_info "Searching through $count transcripts..."
    local matches=0

    echo "$results" | jq -c '.value[]?' 2>/dev/null | while read -r transcript; do
        [ -z "$transcript" ] && continue

        local content=$(echo "$transcript" | jq -r '.content // empty')
        local name=$(echo "$transcript" | jq -r '.name')
        local created=$(echo "$transcript" | jq -r '.createdon')

        # Search in content (case-insensitive)
        if echo "$content" | grep -qi "$search_term" 2>/dev/null; then
            ((matches++)) || true
            echo ""
            echo -e "${GREEN}Match found:${NC}"
            echo "  ID: $name"
            echo "  Created: $created"
            # Extract snippet with match
            local snippet=$(echo "$content" | grep -i -o ".\{0,50\}${search_term}.\{0,50\}" 2>/dev/null | head -1)
            if [ -n "$snippet" ]; then
                echo "  Snippet: ...$snippet..."
            fi
        fi
    done

    echo ""
    print_info "Search complete"
}

# ═══════════════════════════════════════════════════════════════
# WATCH MODE - Real-time conversation monitoring
# ═══════════════════════════════════════════════════════════════

watch_conversation() {
    local pva_url="$1"
    local bot_id="$2"
    local conv_id="$3"
    local interval="${4:-5}"

    print_info "Watching conversation: $conv_id"
    print_info "Press Ctrl+C to stop"
    echo ""

    local last_count=0
    local encoded_conv_id=$(printf '%s' "$conv_id" | jq -sRr @uri)

    while true; do
        local token=$(get_access_token "$RESOURCE")

        local activities=$(curl -s "${pva_url}/powervirtualagents/bots/${bot_id}/channels/pva-studio/conversations/${encoded_conv_id}/history?api-version=1&pageSize=100&filterType=All" \
            -H "accept: application/json" \
            -H "authorization: Bearer $token" \
            -H "origin: https://copilotstudio.preview.microsoft.com")

        local current_count=$(echo "$activities" | jq '.activities | length')

        if [ "$current_count" != "$last_count" ] && [ "$last_count" != "0" ]; then
            local new_activities=$((current_count - last_count))
            echo -e "${CYAN}[$(date +%H:%M:%S)]${NC} +$new_activities new activit(ies)"

            # Show last few new activities
            echo "$activities" | jq -r --argjson skip "$last_count" '.activities[$skip:] | .[] |
                if .type == "message" then
                    "\(.from.role): \(.text // "[no text]" | .[0:100])"
                elif .type == "event" then
                    "EVENT: \(.name)"
                else
                    "\(.type)"
                end' | while read -r line; do
                echo "  $line"
            done
        fi

        last_count=$current_count
        sleep "$interval"
    done
}

# Function to list all bots from Dataverse
list_bots() {
    local dataverse_url="$1"
    print_info "Fetching bots from Dataverse..." >&2

    local dv_token=$(get_access_token "${dataverse_url}")

    if [ -z "$dv_token" ]; then
        print_warning "Could not get Dataverse token" >&2
        return 1
    fi

    curl -s "${dataverse_url}/api/data/v9.2/bots?\$select=name,schemaname,botid,createdon,statuscode&\$expand=createdby(\$select=fullname)&\$filter=not%20startswith(template,'gpt')" \
        -H "Authorization: Bearer $dv_token" \
        -H "OData-MaxVersion: 4.0" \
        -H "Accept: application/json"
}

# Function to get environment Dataverse URL
get_dataverse_url() {
    local env_id="$1"
    local envs_json
    envs_json=$(list_environments 2>/dev/null) || return 1
    echo "$envs_json" | jq -r --arg id "$env_id" '.value[] | select(.name == $id) | .properties.linkedEnvironmentMetadata.instanceApiUrl'
}

# Function to resolve Dataverse URL (requires ENV_ID)
resolve_dataverse_url() {
    if [ -n "${DATAVERSE_URL_FROM_CONFIG:-}" ]; then
        echo "$DATAVERSE_URL_FROM_CONFIG"
        return 0
    fi

    if [ -n "$ENV_ID" ]; then
        local url=$(get_dataverse_url "$ENV_ID")
        if [ -n "$url" ] && [ "$url" != "null" ]; then
            echo "$url"
            return 0
        fi
    fi
    print_error "Could not determine Dataverse URL. Please specify --env-id with a valid environment ID."
    print_info "Run: pistudio envs"
    return 1
}

# Function to resolve PVA API URL with fallbacks
# Order: explicit ENV_URL -> canonical env-id host -> legacy truncated host
get_pva_api_url() {
    local env_id="$1"
    if [ -n "$PVA_URL_CACHE" ] && [ "$PVA_URL_CACHE_ENV_ID" = "$env_id" ]; then
        echo "$PVA_URL_CACHE"
        return 0
    fi

    local -a candidates=()

    if [ -n "${ENV_URL:-}" ]; then
        candidates+=("${ENV_URL%/}")
    fi
    if [ -n "$env_id" ]; then
        candidates+=("https://${env_id}.environment.api.powerplatform.com")

        local env_no_dashes
        env_no_dashes=$(echo "$env_id" | tr -d '-')
        local env_truncated="${env_no_dashes:0:30}"
        candidates+=("https://${env_truncated}.0e.environment.api.powerplatform.com")
    fi

    local candidate
    for candidate in "${candidates[@]}"; do
        if curl -sS --connect-timeout 4 --max-time 8 "$candidate" -o /dev/null 2>/dev/null; then
            PVA_URL_CACHE_ENV_ID="$env_id"
            PVA_URL_CACHE="$candidate"
            echo "$candidate"
            return 0
        fi
    done

    # Return first candidate as last resort for compatibility
    if [ ${#candidates[@]} -gt 0 ]; then
        PVA_URL_CACHE_ENV_ID="$env_id"
        PVA_URL_CACHE="${candidates[0]}"
        echo "${candidates[0]}"
        return 0
    fi
    return 1
}

# Function to list all conversations for a bot (via PVA conversations/metadata API)
list_conversations() {
    local env_id="$1"
    local bot_schema="$2"
    local page_size="${3:-150}"

    local pva_url
    pva_url=$(get_pva_api_url "$env_id") || return 1
    print_info "Fetching conversations from PVA API..." >&2
    print_info "URL: ${pva_url}/powervirtualagents/conversations/metadata" >&2

    local token=$(get_access_token "$RESOURCE")

    if [ -z "$token" ]; then
        print_warning "Could not get access token" >&2
        return 1
    fi

    local response
    response=$(curl -sS "${pva_url}/powervirtualagents/conversations/metadata?api-version=1&botSchemaName=${bot_schema}&pageSize=${page_size}" \
        -H "Accept: application/json" \
        -H "Authorization: Bearer $token" \
        -H "Origin: https://copilotstudio.preview.microsoft.com" 2>/dev/null || true)

    if [ -z "$response" ]; then
        print_warning "Failed to retrieve conversations from PVA API (network/DNS/auth issue)" >&2
        return 1
    fi

    echo "$response"
}

# Function to list conversation transcripts from Dataverse (more reliable than PVA API)
# This queries the conversationtranscripts table which stores pva-studio channel conversations
list_transcripts() {
    local dataverse_url="$1"
    local bot_id="$2"  # Bot GUID (not schema name)
    local limit="${3:-50}"

    print_info "Fetching conversation transcripts from Dataverse..." >&2

    local dv_token=$(get_access_token "${dataverse_url}")

    if [ -z "$dv_token" ]; then
        print_warning "Could not get Dataverse token" >&2
        return 1
    fi

    # Build filter - if bot_id provided, filter by it
    local filter=""
    if [ -n "$bot_id" ]; then
        filter="&\$filter=_bot_conversationtranscriptid_value%20eq%20${bot_id}"
    fi

    curl -s "${dataverse_url}/api/data/v9.2/conversationtranscripts?\$select=name,conversationtranscriptid,conversationstarttime,createdon&\$orderby=conversationstarttime%20desc&\$top=${limit}${filter}" \
        -H "Authorization: Bearer $dv_token" \
        -H "OData-MaxVersion: 4.0" \
        -H "Accept: application/json"
}

# Function to get bot GUID from schema name (needed for transcript filtering)
get_bot_guid() {
    local dataverse_url="$1"
    local bot_schema="$2"

    local dv_token=$(get_access_token "${dataverse_url}")

    if [ -z "$dv_token" ]; then
        return 1
    fi

    curl -s "${dataverse_url}/api/data/v9.2/bots?\$select=botid,name,schemaname&\$filter=schemaname%20eq%20'${bot_schema}'" \
        -H "Authorization: Bearer $dv_token" \
        -H "OData-MaxVersion: 4.0" \
        -H "Accept: application/json" | jq -r '.value[0].botid // empty'
}

# Function to fetch a single conversation transcript from Dataverse by ID
fetch_transcript() {
    local dataverse_url="$1"
    local transcript_id="$2"

    local dv_token=$(get_access_token "${dataverse_url}")

    if [ -z "$dv_token" ]; then
        print_warning "Could not get Dataverse token" >&2
        return 1
    fi

    # Fetch transcript and extract the content field (which contains activities JSON)
    local response=$(curl -s "${dataverse_url}/api/data/v9.2/conversationtranscripts(${transcript_id})?\$select=name,content,conversationstarttime" \
        -H "Authorization: Bearer $dv_token" \
        -H "OData-MaxVersion: 4.0" \
        -H "Accept: application/json")

    # Extract and parse the content field (it's a JSON string containing activities)
    echo "$response" | jq -r '.content // empty'
}

# Function to list transcripts with activity counts (for selection)
list_transcripts_with_stats() {
    local dataverse_url="$1"
    local bot_id="$2"
    local limit="${3:-20}"

    print_info "Fetching transcripts with activity counts..." >&2

    local dv_token=$(get_access_token "${dataverse_url}")

    if [ -z "$dv_token" ]; then
        print_warning "Could not get Dataverse token" >&2
        return 1
    fi

    local filter=""
    if [ -n "$bot_id" ]; then
        filter="&\$filter=_bot_conversationtranscriptid_value%20eq%20${bot_id}"
    fi

    # Fetch transcripts with content to count activities
    local response=$(curl -s "${dataverse_url}/api/data/v9.2/conversationtranscripts?\$select=name,conversationtranscriptid,conversationstarttime,content&\$orderby=conversationstarttime%20desc&\$top=${limit}${filter}" \
        -H "Authorization: Bearer $dv_token" \
        -H "OData-MaxVersion: 4.0" \
        -H "Accept: application/json")

    if ! echo "$response" | jq -e 'type == "object"' >/dev/null 2>&1; then
        print_warning "Unexpected response while fetching transcripts" >&2
        echo "[]"
        return 0
    fi

    if echo "$response" | jq -e '.error != null' >/dev/null 2>&1; then
        local api_error
        api_error=$(echo "$response" | jq -r '.error.message // .error.code // "Unknown error"' 2>/dev/null || true)
        print_warning "Dataverse transcript query failed: ${api_error}" >&2
        echo "[]"
        return 0
    fi

    # Parse and add activity counts
    echo "$response" | jq '[(.value // [])[] | {
        id: .conversationtranscriptid,
        name: .name,
        start_time: .conversationstarttime,
        activity_count: ((.content | fromjson? | .activities | length) // 0)
    }] | sort_by(-.activity_count)'
}

# Function to list sub-agents for a bot
list_subagents() {
    local dataverse_url="$1"
    local bot_schema="$2"
    print_info "Fetching sub-agents from Dataverse..." >&2

    local dv_token=$(get_access_token "${dataverse_url}")

    if [ -z "$dv_token" ]; then
        print_warning "Could not get Dataverse token" >&2
        return 1
    fi

    # Query botcomponents that are sub-agents (schemaname contains .agent.Agent_)
    local filter=""
    if [ -n "$bot_schema" ]; then
        filter="&\$filter=startswith(schemaname,'${bot_schema}.agent.Agent_')"
    else
        filter="&\$filter=contains(schemaname,'.agent.Agent_')"
    fi

    curl -s "${dataverse_url}/api/data/v9.2/botcomponents?\$select=name,schemaname,componenttype,createdon,modifiedon&\$expand=parentbotid(\$select=name,schemaname),createdby(\$select=fullname)${filter}" \
        -H "Authorization: Bearer $dv_token" \
        -H "OData-MaxVersion: 4.0" \
        -H "Accept: application/json"
}

# Function to export a sub-agent's full configuration
export_agent_config() {
    local dataverse_url="$1"
    local agent_schema="$2"
    print_info "Fetching agent configuration from Dataverse..." >&2

    local dv_token=$(get_access_token "${dataverse_url}")

    if [ -z "$dv_token" ]; then
        print_warning "Could not get Dataverse token" >&2
        return 1
    fi

    # URL encode the schema name for the filter
    local encoded_schema=$(echo "$agent_schema" | sed 's/ /%20/g')

    curl -s "${dataverse_url}/api/data/v9.2/botcomponents?\$select=name,schemaname,botcomponentid,description,data,createdon,modifiedon&\$expand=parentbotid(\$select=name,schemaname)&\$filter=schemaname%20eq%20'${encoded_schema}'" \
        -H "Authorization: Bearer $dv_token" \
        -H "OData-MaxVersion: 4.0" \
        -H "Accept: application/json"
}

# Function to update a sub-agent's configuration via PATCH
update_agent_config() {
    local dataverse_url="$1"
    local component_id="$2"
    local field="$3"
    local value="$4"
    print_info "Updating agent via PATCH..." >&2

    local dv_token=$(get_access_token "${dataverse_url}")

    if [ -z "$dv_token" ]; then
        print_warning "Could not get Dataverse token" >&2
        return 1
    fi

    # Build JSON payload
    local payload
    if [ "$field" = "data" ]; then
        # For data field, read from file
        payload=$(jq -n --arg data "$value" '{"data": $data}')
    else
        payload=$(jq -n --arg field "$field" --arg value "$value" '{($field): $value}')
    fi

    curl -s -w "\n%{http_code}" \
        -X PATCH "${dataverse_url}/api/data/v9.2/botcomponents(${component_id})" \
        -H "Authorization: Bearer $dv_token" \
        -H "OData-MaxVersion: 4.0" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -d "$payload"
}

# Function to get agent component ID by schema name
get_agent_component_id() {
    local dataverse_url="$1"
    local agent_schema="$2"

    local dv_token=$(get_access_token "${dataverse_url}")

    curl -s "${dataverse_url}/api/data/v9.2/botcomponents?\$select=botcomponentid&\$filter=schemaname%20eq%20'${agent_schema}'" \
        -H "Authorization: Bearer $dv_token" \
        -H "OData-MaxVersion: 4.0" \
        -H "Accept: application/json" | jq -r '.value[0].botcomponentid // empty'
}

# Function to get parent bot ID by schema name
get_parent_bot_id() {
    local dataverse_url="$1"
    local bot_schema="$2"

    local dv_token=$(get_access_token "${dataverse_url}")

    curl -s "${dataverse_url}/api/data/v9.2/bots?\$select=botid&\$filter=schemaname%20eq%20'${bot_schema}'" \
        -H "Authorization: Bearer $dv_token" \
        -H "OData-MaxVersion: 4.0" \
        -H "Accept: application/json" | jq -r '.value[0].botid // empty'
}

# Function to resolve bot name (display name or schema name) to schema name
# If the input contains spaces or doesn't match schema pattern, treat as display name
resolve_bot_schema() {
    local dataverse_url="$1"
    local bot_input="$2"

    # If input looks like a schema name (no spaces, contains underscore pattern), return as-is
    if [[ ! "$bot_input" =~ [[:space:]] ]] && [[ "$bot_input" =~ ^[a-zA-Z0-9_]+$ ]]; then
        echo "$bot_input"
        return 0
    fi

    # Otherwise, treat as display name and look up in Dataverse
    print_info "Resolving bot display name: '$bot_input'..." >&2

    local dv_token=$(get_access_token "${dataverse_url}")

    if [ -z "$dv_token" ]; then
        print_warning "Could not get Dataverse token for bot resolution" >&2
        echo "$bot_input"
        return 1
    fi

    # URL encode the bot name for the query
    local encoded_name=$(printf '%s' "$bot_input" | jq -sRr @uri)

    local result=$(curl -s "${dataverse_url}/api/data/v9.2/bots?\$select=schemaname,name&\$filter=name%20eq%20'${encoded_name}'" \
        -H "Authorization: Bearer $dv_token" \
        -H "OData-MaxVersion: 4.0" \
        -H "Accept: application/json")

    local schema=$(echo "$result" | jq -r '.value[0].schemaname // empty')

    if [ -n "$schema" ]; then
        print_status "Resolved '$bot_input' -> '$schema'" >&2
        echo "$schema"
        return 0
    else
        # Try case-insensitive contains search as fallback
        result=$(curl -s "${dataverse_url}/api/data/v9.2/bots?\$select=schemaname,name&\$filter=contains(name,'${encoded_name}')" \
            -H "Authorization: Bearer $dv_token" \
            -H "OData-MaxVersion: 4.0" \
            -H "Accept: application/json")

        schema=$(echo "$result" | jq -r '.value[0].schemaname // empty')

        if [ -n "$schema" ]; then
            local resolved_name=$(echo "$result" | jq -r '.value[0].name // empty')
            print_status "Resolved '$bot_input' -> '$schema' ($resolved_name)" >&2
            echo "$schema"
            return 0
        fi

        print_warning "Could not resolve bot name '$bot_input' - using as-is" >&2
        echo "$bot_input"
        return 1
    fi
}

# Function to resolve agent/component name (display name or schema name) to schema name
# Works for sub-agents, topics, tools, and other bot components
resolve_agent_schema() {
    local dataverse_url="$1"
    local agent_input="$2"
    local component_type="${3:-}"  # Optional: 9=agent, 3=topic, etc.

    # If input looks like a schema name (contains .agent. or .topic. pattern), return as-is
    if [[ "$agent_input" =~ \.(agent|topic|tool|action|flow)\. ]]; then
        echo "$agent_input"
        return 0
    fi

    # If it looks like a full schema name with dots (e.g., bot_name.agent.Agent_xyz), return as-is
    if [[ "$agent_input" =~ ^[a-zA-Z0-9_]+\.[a-zA-Z]+\.[a-zA-Z0-9_-]+$ ]]; then
        echo "$agent_input"
        return 0
    fi

    # Otherwise, treat as display name and look up in Dataverse
    print_info "Resolving component display name: '$agent_input'..." >&2

    local dv_token=$(get_access_token "${dataverse_url}")

    if [ -z "$dv_token" ]; then
        print_warning "Could not get Dataverse token for component resolution" >&2
        echo "$agent_input"
        return 1
    fi

    # URL encode the name for the query
    local encoded_name=$(printf '%s' "$agent_input" | jq -sRr @uri)

    # Build filter - optionally filter by component type
    local filter="name%20eq%20'${encoded_name}'"
    if [ -n "$component_type" ]; then
        filter="${filter}%20and%20componenttype%20eq%20${component_type}"
    fi

    local result=$(curl -s "${dataverse_url}/api/data/v9.2/botcomponents?\$select=schemaname,name,componenttype&\$filter=${filter}" \
        -H "Authorization: Bearer $dv_token" \
        -H "OData-MaxVersion: 4.0" \
        -H "Accept: application/json")

    local schema=$(echo "$result" | jq -r '.value[0].schemaname // empty')

    if [ -n "$schema" ]; then
        print_status "Resolved '$agent_input' -> '$schema'" >&2
        echo "$schema"
        return 0
    else
        # Try contains search as fallback
        filter="contains(name,'${encoded_name}')"
        if [ -n "$component_type" ]; then
            filter="${filter}%20and%20componenttype%20eq%20${component_type}"
        fi

        result=$(curl -s "${dataverse_url}/api/data/v9.2/botcomponents?\$select=schemaname,name,componenttype&\$filter=${filter}" \
            -H "Authorization: Bearer $dv_token" \
            -H "OData-MaxVersion: 4.0" \
            -H "Accept: application/json")

        schema=$(echo "$result" | jq -r '.value[0].schemaname // empty')

        if [ -n "$schema" ]; then
            local resolved_name=$(echo "$result" | jq -r '.value[0].name // empty')
            print_status "Resolved '$agent_input' -> '$schema' ($resolved_name)" >&2
            echo "$schema"
            return 0
        fi

        print_warning "Could not resolve component name '$agent_input' - using as-is" >&2
        echo "$agent_input"
        return 1
    fi
}

# Function to create a new sub-agent
create_agent() {
    local dataverse_url="$1"
    local agent_name="$2"
    local parent_bot_id="$3"
    local parent_schema="$4"
    local yaml_data="$5"
    local description="$6"

    print_info "Creating new sub-agent via Dataverse API..." >&2

    local dv_token=$(get_access_token "${dataverse_url}")

    if [ -z "$dv_token" ]; then
        print_warning "Could not get Dataverse token" >&2
        return 1
    fi

    # Generate random suffix for schema name
    local random_suffix=$(cat /dev/urandom | LC_ALL=C tr -dc 'a-zA-Z0-9' | head -c 3)
    local schema_name="${parent_schema}.agent.Agent_${random_suffix}"

    # Build payload
    local payload=$(jq -n \
        --arg name "$agent_name" \
        --arg schema "$schema_name" \
        --arg data "$yaml_data" \
        --arg desc "$description" \
        --arg parentbot "/bots(${parent_bot_id})" \
        '{
            "name": $name,
            "schemaname": $schema,
            "componenttype": 9,
            "description": $desc,
            "data": $data,
            "parentbotid@odata.bind": $parentbot
        }')

    curl -s -w "\n%{http_code}" \
        -X POST "${dataverse_url}/api/data/v9.2/botcomponents" \
        -H "Authorization: Bearer $dv_token" \
        -H "OData-MaxVersion: 4.0" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -H "Prefer: return=representation" \
        -d "$payload"
}

# Function to delete a sub-agent
delete_agent() {
    local dataverse_url="$1"
    local component_id="$2"

    print_info "Deleting sub-agent via Dataverse API..." >&2

    local dv_token=$(get_access_token "${dataverse_url}")

    if [ -z "$dv_token" ]; then
        print_warning "Could not get Dataverse token" >&2
        return 1
    fi

    curl -s -w "\n%{http_code}" \
        -X DELETE "${dataverse_url}/api/data/v9.2/botcomponents(${component_id})" \
        -H "Authorization: Bearer $dv_token" \
        -H "OData-MaxVersion: 4.0"
}

# Function to list all Power Platform environments via BAP API
list_environments() {
    print_info "Fetching environments from Business Application Platform API..." >&2

    local token=$(get_access_token "https://management.azure.com")

    if [ -z "$token" ]; then
        print_warning "Could not get Azure Management token" >&2
        return 1
    fi

    curl -s "https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/environments?api-version=2023-06-01" \
        -H "Authorization: Bearer $token" \
        -H "Accept: application/json"
}

# Function to get environment details with permissions
get_environment_details() {
    local env_id="$1"
    print_info "Fetching environment details for: $env_id" >&2

    local token=$(get_access_token "https://management.azure.com")

    if [ -z "$token" ]; then
        print_warning "Could not get Azure Management token" >&2
        return 1
    fi

    curl -s "https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/environments/${env_id}?api-version=2023-06-01&\$expand=properties.permissions" \
        -H "Authorization: Bearer $token" \
        -H "Accept: application/json"
}

# Function to get Copilot Studio feature flags from ECS
get_copilot_features() {
    local tenant_id="$1"
    local env_id="$2"

    print_info "Fetching Copilot Studio feature flags from ECS..." >&2

    curl -s "https://ecs.office.com/config/v1/CopilotStudio/1.0.0.0?TenantID=${tenant_id}&EnvironmentID=${env_id}&Region=preview&Locale=en-US&AppName=powerva-microsoft-com" \
        -H "Accept: application/json"
}

show_help() {
    cat << 'EOF'
╔══════════════════════════════════════════════════════════════════════════════╗
║              COPILOT STUDIO CLI - Activity Export & Agent Management         ║
╚══════════════════════════════════════════════════════════════════════════════╝

DESCRIPTION
    CLI for managing Microsoft Copilot Studio agents via Power Platform and
    Dataverse APIs. Export conversations, manage sub-agents, and generate
    analytics dashboards.

    Authenticate first:  pistudio login -p <profile>
    Quick reference:     pistudio --help    (this page)
    Command help:        pistudio <command> --help

══════════════════════════════════════════════════════════════════════════════
ENVIRONMENT VARIABLES
══════════════════════════════════════════════════════════════════════════════

    COPILOT_ENV_URL       https://{ENV_ID}.environment.api.powerplatform.com
    COPILOT_BOT_ID        Bot schema name (from --list-bots)
    COPILOT_TENANT_ID     Azure AD tenant ID (from pistudio status)
    COPILOT_APP_ID        Custom app ID (default: Azure CLI public client)

══════════════════════════════════════════════════════════════════════════════
DISCOVERY
══════════════════════════════════════════════════════════════════════════════

    --list-envs               List Power Platform environments
    --list-bots               List bots in an environment
    --list-subagents          List sub-agents for a bot
    --list-conversations      List conversations via PVA API
    --list-transcripts        List transcripts via Dataverse (more reliable)
    --env-details             Environment info (permissions, capacity)
    --feature-flags           Copilot Studio feature flags (no auth needed)

══════════════════════════════════════════════════════════════════════════════
EXPORT
══════════════════════════════════════════════════════════════════════════════

    -c, --conv-id <ID>        Export conversation (supports comma-separated)
    --export-all              Export all from --conversations-file
    --from-dataverse          Export via Dataverse (fallback for PVA DNS issues)
    --analytics-only          Regenerate analytics from existing export

══════════════════════════════════════════════════════════════════════════════
AGENT MANAGEMENT
══════════════════════════════════════════════════════════════════════════════

    --export-agent            Export sub-agent config to YAML
    --create-agent            Create new sub-agent (needs -b, --agent-name)
    --update-agent            Update agent field (--field, --value)
    --delete-agent            Delete sub-agent (permanent)
    --clone                   Duplicate agent (--source-agent, --new-name)
    --diff                    Compare two agents (--agent1, --agent2)
    --backup                  Backup all agents to directory
    --restore                 Restore agents from backup

══════════════════════════════════════════════════════════════════════════════
UTILITIES
══════════════════════════════════════════════════════════════════════════════

    --url <URL>               Parse Copilot Studio URL, extract IDs
    --open                    Open bot/conversation in browser
    --search <TERM>           Search transcripts (default: last 7 days)
    --watch                   Monitor conversation in real-time
    -v, --verbose             Debug output

══════════════════════════════════════════════════════════════════════════════
PARAMETERS
══════════════════════════════════════════════════════════════════════════════

    -e, --env-url <URL>       Environment API URL
    -b, --bot-id <NAME>       Bot schema name or display name (auto-resolved)
    -o, --output <DIR>        Output directory (default: ./reports)
    -t, --tenant <ID>         Azure AD tenant ID
    -d, --days <N>            Filter to last N days
    -f, --format <FMT>        Output formats: json,csv,html,md (default: all)
    -p, --profile <NAME>      Config profile name
    --config <PATH>           Config file path
    --env-id <GUID>           Environment ID (GUID)
    --agent-schema <NAME>     Agent schema or display name (auto-resolved)
    --agent-name <NAME>       Display name for new agent
    --yaml-file <PATH>        YAML config for agent create/update
    --field <FIELD>           Update field: description or data
    --value <VALUE>           New value (or file path for data)
    --transcript-id <GUID>    Transcript ID for Dataverse export
    --bot-guid <GUID>         Bot GUID for transcript filtering
    --backup-dir <PATH>       Backup/restore directory
    --interval <SEC>          Watch polling interval (default: 5)

══════════════════════════════════════════════════════════════════════════════
CONFIGURATION
══════════════════════════════════════════════════════════════════════════════

    Create config/copilot-export.json:

    {
        "defaultProfile": "dev",
        "profiles": {
            "dev": {
                "environmentUrl": "https://<env-id>.environment.api.powerplatform.com",
                "environmentId": "<env-id>",
                "dataverseUrl": "https://<org>.api.crm.dynamics.com",
                "botId": "<bot-schema-name>",
                "tenantId": "<tenant-id>"
            },
            "prod": {
                "environmentUrl": "https://<env-id>.environment.api.powerplatform.com",
                "environmentId": "<env-id>",
                "dataverseUrl": "https://<org>.api.crm.dynamics.com",
                "botId": "<bot-schema-name>",
                "tenantId": "<tenant-id>"
            }
        }
    }

══════════════════════════════════════════════════════════════════════════════
QUICK START
══════════════════════════════════════════════════════════════════════════════

    pistudio login -p dev                           # Authenticate
    pistudio envs                                   # Discover environments
    pistudio bots -p dev                            # List bots
    pistudio agents -p dev                          # List sub-agents
    pistudio agents get 'My Agent' -p dev           # Export agent YAML
    pistudio convs -p dev                           # List conversations
    pistudio convs export <conv-id> -p dev          # Export conversation
    pistudio agents backup -p dev                   # Backup all agents

══════════════════════════════════════════════════════════════════════════════
TROUBLESHOOTING
══════════════════════════════════════════════════════════════════════════════

    "Could not get token":     pistudio login -p <profile>
    PVA DNS errors:            Use --from-dataverse as fallback
    "Bot not found":           Use --list-bots to find schema name
    Empty exports:             Check conversation status (Status: 5 = complete)

    Dependencies: jq (brew install jq), curl (pre-installed)

EOF
    exit 0
}

# Load config file if exists (supports profiles)
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        print_info "Loading config from $CONFIG_FILE"

        # Check if config uses profiles structure
        local has_profiles=$(jq -r 'has("profiles")' "$CONFIG_FILE" 2>/dev/null)

        if [ "$has_profiles" = "true" ]; then
            # Profiles-based config
            local profile_name="$PROFILE"
            if [ -z "$profile_name" ]; then
                profile_name=$(jq -r '.defaultProfile // "default"' "$CONFIG_FILE")
            fi

            print_info "Using profile: $profile_name"

            # Only set if not already specified via CLI
            if [ -z "$CONFIG_ENV_URL" ]; then
                CONFIG_ENV_URL=$(jq -r --arg p "$profile_name" '.profiles[$p].environmentUrl // empty' "$CONFIG_FILE")
            fi
            if [ -z "$CONFIG_BOT_ID" ]; then
                CONFIG_BOT_ID=$(jq -r --arg p "$profile_name" '.profiles[$p].botId // empty' "$CONFIG_FILE")
            fi
            if [ -z "$CONFIG_TENANT" ]; then
                CONFIG_TENANT=$(jq -r --arg p "$profile_name" '.profiles[$p].tenantId // empty' "$CONFIG_FILE")
            fi
            if [ -z "$CONFIG_ENV_ID" ]; then
                CONFIG_ENV_ID=$(jq -r --arg p "$profile_name" '.profiles[$p].environmentId // empty' "$CONFIG_FILE")
            fi
            if [ -z "$CONFIG_DATAVERSE_URL" ]; then
                CONFIG_DATAVERSE_URL=$(jq -r --arg p "$profile_name" '.profiles[$p].dataverseUrl // empty' "$CONFIG_FILE")
            fi
        else
            # Legacy flat config
            CONFIG_ENV_URL=$(jq -r '.env_url // empty' "$CONFIG_FILE")
            CONFIG_BOT_ID=$(jq -r '.bot_id // empty' "$CONFIG_FILE")
            CONFIG_TENANT=$(jq -r '.tenant // empty' "$CONFIG_FILE")
        fi
    fi
}

# Parse arguments
FORMATS="json,csv,html,md"
DAYS_FILTER=""
ANALYTICS_ONLY=false
CONV_IDS=""
ENV_URL=""
BOT_ID=""
TENANT=""
DATAVERSE_URL=""
DV_URL=""
PVA_URL=""
TOKEN=""
LIST_BOTS=false
LIST_SUBAGENTS=false
ENV_ID=""
PROFILE=""
CONFIG_ENV_URL=""
CONFIG_BOT_ID=""
CONFIG_TENANT=""
CONFIG_ENV_ID=""
CONFIG_DATAVERSE_URL=""
EXPORT_AGENT=false
UPDATE_AGENT=false
CREATE_AGENT=false
DELETE_AGENT=false
AGENT_SCHEMA=""
AGENT_NAME=""
YAML_FILE=""
UPDATE_FIELD=""
UPDATE_VALUE=""
LIST_ENVS=false
ENV_DETAILS=false
FEATURE_FLAGS=false
LIST_CONVERSATIONS=false
CONVERSATIONS_FILE=""
EXPORT_ALL=false
LIST_TRANSCRIPTS=false
FROM_DATAVERSE=false
TRANSCRIPT_ID=""
BOT_GUID=""

# New feature flags
VERBOSE=false
URL_INPUT=""
CLONE_AGENT=false
CLONE_SOURCE=""
CLONE_NEW_NAME=""
DIFF_AGENTS=false
DIFF_AGENT1=""
DIFF_AGENT2=""
OPEN_BROWSER=false
WATCH_MODE=false
WATCH_INTERVAL=5
BACKUP_AGENTS=false
RESTORE_AGENTS=false
BACKUP_DIR=""
SEARCH_CONV=false
SEARCH_TERM=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -e|--env-url) require_option_value "$1" "${2:-}"; ENV_URL="$2"; shift 2 ;;
        -b|--bot-id) require_option_value "$1" "${2:-}"; BOT_ID="$2"; shift 2 ;;
        -c|--conv-id) require_option_value "$1" "${2:-}"; CONV_IDS="$2"; shift 2 ;;
        -o|--output) require_option_value "$1" "${2:-}"; OUTPUT_DIR="$2"; shift 2 ;;
        -t|--tenant) require_option_value "$1" "${2:-}"; TENANT="$2"; shift 2 ;;
        -d|--days) require_option_value "$1" "${2:-}"; DAYS_FILTER="$2"; shift 2 ;;
        -f|--format) require_option_value "$1" "${2:-}"; FORMATS="$2"; shift 2 ;;
        --config) require_option_value "$1" "${2:-}"; CONFIG_FILE="$2"; shift 2 ;;
        --profile|-p) require_option_value "$1" "${2:-}"; PROFILE="$2"; shift 2 ;;
        --analytics-only) ANALYTICS_ONLY=true; shift ;;
        --list-bots) LIST_BOTS=true; shift ;;
        --list-subagents) LIST_SUBAGENTS=true; shift ;;
        --env-id) require_option_value "$1" "${2:-}"; ENV_ID="$2"; shift 2 ;;
        --export-agent) EXPORT_AGENT=true; shift ;;
        --update-agent) UPDATE_AGENT=true; shift ;;
        --create-agent) CREATE_AGENT=true; shift ;;
        --delete-agent) DELETE_AGENT=true; shift ;;
        --agent-schema) require_option_value "$1" "${2:-}"; AGENT_SCHEMA="$2"; shift 2 ;;
        --agent-name) require_option_value "$1" "${2:-}"; AGENT_NAME="$2"; shift 2 ;;
        --yaml-file) require_option_value "$1" "${2:-}"; YAML_FILE="$2"; shift 2 ;;
        --field) require_option_value "$1" "${2:-}"; UPDATE_FIELD="$2"; shift 2 ;;
        --value) require_option_value "$1" "${2:-}"; UPDATE_VALUE="$2"; shift 2 ;;
        --list-envs) LIST_ENVS=true; shift ;;
        --env-details) ENV_DETAILS=true; shift ;;
        --feature-flags) FEATURE_FLAGS=true; shift ;;
        --list-conversations) LIST_CONVERSATIONS=true; shift ;;
        --conversations-file) require_option_value "$1" "${2:-}"; CONVERSATIONS_FILE="$2"; shift 2 ;;
        --export-all) EXPORT_ALL=true; shift ;;
        --list-transcripts) LIST_TRANSCRIPTS=true; shift ;;
        --from-dataverse) FROM_DATAVERSE=true; shift ;;
        --transcript-id) require_option_value "$1" "${2:-}"; TRANSCRIPT_ID="$2"; shift 2 ;;
        --bot-guid) require_option_value "$1" "${2:-}"; BOT_GUID="$2"; shift 2 ;;

        # New feature options
        -v|--verbose) VERBOSE=true; shift ;;
        --url) require_option_value "$1" "${2:-}"; URL_INPUT="$2"; shift 2 ;;
        --clone) CLONE_AGENT=true; shift ;;
        --source|--source-agent) require_option_value "$1" "${2:-}"; CLONE_SOURCE="$2"; shift 2 ;;
        --new-name) require_option_value "$1" "${2:-}"; CLONE_NEW_NAME="$2"; shift 2 ;;
        --diff) DIFF_AGENTS=true; shift ;;
        --agent1) require_option_value "$1" "${2:-}"; DIFF_AGENT1="$2"; shift 2 ;;
        --agent2) require_option_value "$1" "${2:-}"; DIFF_AGENT2="$2"; shift 2 ;;
        --open) OPEN_BROWSER=true; shift ;;
        --watch) WATCH_MODE=true; shift ;;
        --interval) require_option_value "$1" "${2:-}"; WATCH_INTERVAL="$2"; shift 2 ;;
        --backup) BACKUP_AGENTS=true; shift ;;
        --restore) RESTORE_AGENTS=true; shift ;;
        --backup-dir) require_option_value "$1" "${2:-}"; BACKUP_DIR="$2"; shift 2 ;;
        --search) require_option_value "$1" "${2:-}"; SEARCH_CONV=true; SEARCH_TERM="$2"; shift 2 ;;

        # Short aliases
        ls) LIST_BOTS=true; shift ;;
        agents) LIST_SUBAGENTS=true; shift ;;
        envs) LIST_ENVS=true; shift ;;
        export) shift ;;  # Default action, continue to parse other args
        get) EXPORT_AGENT=true; shift ;;
        transcripts) LIST_TRANSCRIPTS=true; shift ;;

        -h|--help) show_help ;;
        *) echo "Unknown option: $1"; show_help ;;
    esac
done

if [ -n "$DAYS_FILTER" ] && ! [[ "$DAYS_FILTER" =~ ^[0-9]+$ ]]; then
    print_error "--days must be an integer (received: $DAYS_FILTER)"
    exit 1
fi

if [ -n "$WATCH_INTERVAL" ] && ! [[ "$WATCH_INTERVAL" =~ ^[0-9]+$ ]]; then
    print_error "--interval must be an integer (received: $WATCH_INTERVAL)"
    exit 1
fi

# Always include html and md for summary reports (dashboard.html and REPORT.md)
# These are generated regardless of -f/--format flag
[[ "$FORMATS" != *"html"* ]] && FORMATS="${FORMATS},html"
[[ "$FORMATS" != *"md"* ]] && FORMATS="${FORMATS},md"

load_config

# ═══════════════════════════════════════════════════════════════
# URL PARSING - Extract IDs from --url parameter
# ═══════════════════════════════════════════════════════════════

if [ -n "$URL_INPUT" ]; then
    print_debug "Parsing URL: $URL_INPUT"
    parse_copilot_url "$URL_INPUT"

    # Use parsed values if not already set
    [ -n "$PARSED_ENV_ID" ] && [ -z "$ENV_ID" ] && ENV_ID="$PARSED_ENV_ID"
    [ -n "$PARSED_CONV_ID" ] && [ -z "$CONV_IDS" ] && CONV_IDS="$PARSED_CONV_ID"
    [ -n "$PARSED_BOT_GUID" ] && BOT_GUID="$PARSED_BOT_GUID"

    print_debug "Extracted: env=$ENV_ID, conv=$CONV_IDS, bot_guid=$BOT_GUID"
fi

# Use defaults if not specified (priority: CLI args > config file > env vars)
ENV_URL="${ENV_URL:-${CONFIG_ENV_URL:-$DEFAULT_ENV_URL}}"
BOT_ID="${BOT_ID:-${CONFIG_BOT_ID:-$DEFAULT_BOT_ID}}"
TENANT="${TENANT:-${CONFIG_TENANT:-$DEFAULT_TENANT}}"
ENV_ID="${ENV_ID:-$CONFIG_ENV_ID}"
DATAVERSE_URL_FROM_CONFIG="$CONFIG_DATAVERSE_URL"

# Set active profile for auth.sh token resolution
export PISTUDIO_ACTIVE_PROFILE="${PROFILE:-default}"
export PISTUDIO_PROFILE_TENANT_ID="${TENANT:-}"

# Validate required parameters for specific operations
validate_required() {
    local missing=()

    # These operations require tenant
    if [ "$LIST_ENVS" = true ] || [ "$LIST_BOTS" = true ] || [ -n "$CONV_IDS" ]; then
        if [ -z "$TENANT" ]; then
            missing+=("COPILOT_TENANT_ID or -t/--tenant")
        fi
    fi

    # These operations require env URL
    if [ "$LIST_BOTS" = true ] || [ "$LIST_SUBAGENTS" = true ] || [ -n "$CONV_IDS" ]; then
        if [ -z "$ENV_URL" ]; then
            missing+=("COPILOT_ENV_URL or -e/--env-url")
        fi
    fi

    # Conversation export requires bot ID
    if [ -n "$CONV_IDS" ] && [ -z "$BOT_ID" ]; then
        missing+=("COPILOT_BOT_ID or -b/--bot-id")
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        print_error "Missing required configuration:"
        for item in "${missing[@]}"; do
            echo "  - $item"
        done
        echo ""
        echo "Set environment variables or use command-line options. Run with -h for help."
        exit 1
    fi
}

# Only validate if not just showing help or listing envs (which discovers values)
if [ "$LIST_ENVS" != true ]; then
    validate_required
fi

print_header

# ═══════════════════════════════════════════════════════════════
# RESOLVE DISPLAY NAMES TO SCHEMA NAMES
# ═══════════════════════════════════════════════════════════════

# Resolve BOT_ID if it looks like a display name (has spaces or special chars)
resolve_names_if_needed() {
    local dv_url=""

    # Try to get Dataverse URL from config or by resolving ENV_ID
    if [ -n "$DATAVERSE_URL_FROM_CONFIG" ]; then
        dv_url="$DATAVERSE_URL_FROM_CONFIG"
    elif [ -n "$ENV_ID" ]; then
        dv_url=$(get_dataverse_url "$ENV_ID" 2>/dev/null)
    fi

    if [ -z "$dv_url" ] || [ "$dv_url" = "null" ]; then
        return 0  # Can't resolve without Dataverse URL, will use as-is
    fi

    # Resolve BOT_ID if it looks like a display name
    if [ -n "$BOT_ID" ]; then
        if [[ "$BOT_ID" =~ [[:space:]] ]] || [[ ! "$BOT_ID" =~ ^[a-zA-Z0-9_]+$ ]]; then
            BOT_ID=$(resolve_bot_schema "$dv_url" "$BOT_ID")
        fi
    fi

    # Resolve AGENT_SCHEMA if it looks like a display name
    if [ -n "$AGENT_SCHEMA" ]; then
        if [[ "$AGENT_SCHEMA" =~ [[:space:]] ]] || [[ ! "$AGENT_SCHEMA" =~ \.(agent|topic|tool|action|flow)\. ]]; then
            AGENT_SCHEMA=$(resolve_agent_schema "$dv_url" "$AGENT_SCHEMA" "9")  # 9 = agent component type
        fi
    fi

    # Resolve DIFF_AGENT1 if it looks like a display name
    if [ -n "$DIFF_AGENT1" ]; then
        if [[ "$DIFF_AGENT1" =~ [[:space:]] ]] || [[ ! "$DIFF_AGENT1" =~ \.(agent|topic|tool|action|flow)\. ]]; then
            DIFF_AGENT1=$(resolve_agent_schema "$dv_url" "$DIFF_AGENT1" "9")
        fi
    fi

    # Resolve DIFF_AGENT2 if it looks like a display name
    if [ -n "$DIFF_AGENT2" ]; then
        if [[ "$DIFF_AGENT2" =~ [[:space:]] ]] || [[ ! "$DIFF_AGENT2" =~ \.(agent|topic|tool|action|flow)\. ]]; then
            DIFF_AGENT2=$(resolve_agent_schema "$dv_url" "$DIFF_AGENT2" "9")
        fi
    fi

    # Resolve CLONE_SOURCE if it looks like a display name
    if [ -n "$CLONE_SOURCE" ]; then
        if [[ "$CLONE_SOURCE" =~ [[:space:]] ]] || [[ ! "$CLONE_SOURCE" =~ \.(agent|topic|tool|action|flow)\. ]]; then
            CLONE_SOURCE=$(resolve_agent_schema "$dv_url" "$CLONE_SOURCE" "9")
        fi
    fi
}

# Resolve names before proceeding (if possible)
resolve_names_if_needed

# Check dependencies
for cmd in jq curl; do
    if ! command -v $cmd &> /dev/null; then
        print_error "$cmd is required but not installed"
        exit 1
    fi
done

# ═══════════════════════════════════════════════════════════════
# OPEN IN BROWSER MODE
# ═══════════════════════════════════════════════════════════════

if [ "$OPEN_BROWSER" = true ]; then
    # Try to get bot GUID if we have bot schema but not GUID
    if [ -z "$BOT_GUID" ] && [ -n "$BOT_ID" ] && [ -n "$ENV_ID" ]; then
        DV_URL=$(get_dataverse_url "$ENV_ID" 2>/dev/null)
        if [ -n "$DV_URL" ]; then
            DV_TOKEN=$(get_access_token "${DV_URL}")
            if [ -n "$DV_TOKEN" ]; then
                BOT_GUID=$(curl -s "${DV_URL}/api/data/v9.2/bots?\$select=botid&\$filter=schemaname%20eq%20'${BOT_ID}'" \
                    -H "Authorization: Bearer $DV_TOKEN" \
                    -H "Accept: application/json" | jq -r '.value[0].botid // empty')
            fi
        fi
    fi

    if [ -z "$ENV_ID" ]; then
        print_error "Environment ID required (--env-id or --url)"
        exit 1
    fi

    open_in_browser "$ENV_ID" "$BOT_GUID" "$CONV_IDS"
    exit 0
fi

# ═══════════════════════════════════════════════════════════════
# CLONE AGENT MODE
# ═══════════════════════════════════════════════════════════════

if [ "$CLONE_AGENT" = true ]; then
    if [ -z "$CLONE_SOURCE" ]; then
        print_error "Source agent required (--source-agent)"
        exit 1
    fi
    if [ -z "$CLONE_NEW_NAME" ]; then
        print_error "New name required (--new-name)"
        exit 1
    fi

    # Get Dataverse URL
    DV_URL="${DATAVERSE_URL_FROM_CONFIG}"
    if [ -z "$DV_URL" ] && [ -n "$ENV_ID" ]; then
        DV_URL=$(get_dataverse_url "$ENV_ID")
    fi

    if [ -z "$DV_URL" ]; then
        print_error "Dataverse URL required. Use --profile or --env-id"
        exit 1
    fi

    print_header
    clone_agent "$DV_URL" "$CLONE_SOURCE" "$CLONE_NEW_NAME"
    exit $?
fi

# ═══════════════════════════════════════════════════════════════
# DIFF AGENTS MODE
# ═══════════════════════════════════════════════════════════════

if [ "$DIFF_AGENTS" = true ]; then
    if [ -z "$DIFF_AGENT1" ] || [ -z "$DIFF_AGENT2" ]; then
        print_error "Two agents required (--agent1 and --agent2)"
        exit 1
    fi

    # Get Dataverse URL
    DV_URL="${DATAVERSE_URL_FROM_CONFIG}"
    if [ -z "$DV_URL" ] && [ -n "$ENV_ID" ]; then
        DV_URL=$(get_dataverse_url "$ENV_ID")
    fi

    if [ -z "$DV_URL" ]; then
        print_error "Dataverse URL required. Use --profile or --env-id"
        exit 1
    fi

    print_header
    diff_agents "$DV_URL" "$DIFF_AGENT1" "$DIFF_AGENT2"
    exit $?
fi

# ═══════════════════════════════════════════════════════════════
# BACKUP AGENTS MODE
# ═══════════════════════════════════════════════════════════════

if [ "$BACKUP_AGENTS" = true ]; then
    # Get Dataverse URL
    DV_URL="${DATAVERSE_URL_FROM_CONFIG}"
    if [ -z "$DV_URL" ] && [ -n "$ENV_ID" ]; then
        DV_URL=$(get_dataverse_url "$ENV_ID")
    fi

    if [ -z "$DV_URL" ]; then
        print_error "Dataverse URL required. Use --profile or --env-id"
        exit 1
    fi

    # Default backup directory
    if [ -z "$BACKUP_DIR" ]; then
        BACKUP_DIR="./backups/agents_$(date +%Y%m%d_%H%M%S)"
    fi

    print_header
    backup_agents "$DV_URL" "$BOT_ID" "$BACKUP_DIR"
    exit $?
fi

# ═══════════════════════════════════════════════════════════════
# RESTORE AGENTS MODE
# ═══════════════════════════════════════════════════════════════

if [ "$RESTORE_AGENTS" = true ]; then
    if [ -z "$BACKUP_DIR" ]; then
        print_error "Backup directory required (--backup-dir)"
        exit 1
    fi
    if [ -z "$BOT_ID" ]; then
        print_error "Target bot required (-b/--bot-id)"
        exit 1
    fi

    # Get Dataverse URL
    DV_URL="${DATAVERSE_URL_FROM_CONFIG}"
    if [ -z "$DV_URL" ] && [ -n "$ENV_ID" ]; then
        DV_URL=$(get_dataverse_url "$ENV_ID")
    fi

    if [ -z "$DV_URL" ]; then
        print_error "Dataverse URL required. Use --profile or --env-id"
        exit 1
    fi

    print_header
    restore_agents "$DV_URL" "$BOT_ID" "$BACKUP_DIR"
    exit $?
fi

# ═══════════════════════════════════════════════════════════════
# SEARCH CONVERSATIONS MODE
# ═══════════════════════════════════════════════════════════════

if [ "$SEARCH_CONV" = true ]; then
    if [ -z "$SEARCH_TERM" ]; then
        print_error "Search term required (--search 'term')"
        exit 1
    fi

    # Get Dataverse URL
    DV_URL="${DATAVERSE_URL_FROM_CONFIG}"
    if [ -z "$DV_URL" ] && [ -n "$ENV_ID" ]; then
        DV_URL=$(get_dataverse_url "$ENV_ID")
    fi

    if [ -z "$DV_URL" ]; then
        print_error "Dataverse URL required. Use --profile or --env-id"
        exit 1
    fi

    print_header
    search_conversations "$DV_URL" "$SEARCH_TERM" "${DAYS_FILTER:-7}"
    exit 0
fi

# ═══════════════════════════════════════════════════════════════
# WATCH MODE
# ═══════════════════════════════════════════════════════════════

if [ "$WATCH_MODE" = true ]; then
    if [ -z "$CONV_IDS" ]; then
        print_error "Conversation ID required (-c or --url)"
        exit 1
    fi
    if [ -z "$BOT_ID" ]; then
        print_error "Bot ID required (-b)"
        exit 1
    fi

    # Get PVA API URL
    PVA_URL=""
    if [ -n "$ENV_ID" ]; then
        PVA_URL=$(get_pva_api_url "$ENV_ID" || true)
    elif [ -n "${ENV_URL:-}" ]; then
        PVA_URL="${ENV_URL%/}"
    fi

    if [ -z "$PVA_URL" ]; then
        print_error "Could not determine PVA API URL. Use --env-id or --profile"
        exit 1
    fi

    print_header
    watch_conversation "$PVA_URL" "$BOT_ID" "$CONV_IDS" "$WATCH_INTERVAL"
    # watch_conversation runs indefinitely until Ctrl+C
fi

# ═══════════════════════════════════════════════════════════════
# LIST ENVIRONMENTS MODE (BAP API)
# ═══════════════════════════════════════════════════════════════

if [ "$LIST_ENVS" = true ]; then
    print_status "Listing Power Platform environments via BAP API..."

    ensure_login
    print_authenticated_as

    ENVS_JSON=$(list_environments)

    if [ -n "$ENVS_JSON" ]; then
        echo ""
        echo "$ENVS_JSON" | jq -r '.value[] | "Environment: \(.properties.displayName)
  ID: \(.name)
  Type: \(.properties.environmentType // "N/A")
  Location: \(.location)
  Dataverse URL: \(.properties.linkedEnvironmentMetadata.instanceUrl // "N/A")
  Schema Type: \(.properties.linkedEnvironmentMetadata.schemaType // "N/A")
  Created: \(.properties.linkedEnvironmentMetadata.createdTime // "N/A")
"' 2>/dev/null

        ENV_COUNT=$(echo "$ENVS_JSON" | jq '.value | length')
        print_status "Found $ENV_COUNT environments"
    else
        print_error "Failed to retrieve environments"
    fi
    exit 0
fi

# ═══════════════════════════════════════════════════════════════
# ENVIRONMENT DETAILS MODE (BAP API)
# ═══════════════════════════════════════════════════════════════

if [ "$ENV_DETAILS" = true ]; then
    if [ -z "$ENV_ID" ]; then
        print_error "Environment ID is required (--env-id)"
        exit 1
    fi

    print_status "Getting environment details for: $ENV_ID"

    ensure_login
    print_authenticated_as

    ENV_JSON=$(get_environment_details "$ENV_ID")

    if [ -n "$ENV_JSON" ]; then
        echo ""
        echo "=== Environment Details ==="
        echo "$ENV_JSON" | jq '{
            name: .name,
            displayName: .properties.displayName,
            environmentType: .properties.environmentType,
            location: .location,
            instanceUrl: .properties.linkedEnvironmentMetadata.instanceUrl,
            instanceApiUrl: .properties.linkedEnvironmentMetadata.instanceApiUrl,
            version: .properties.linkedEnvironmentMetadata.version,
            uniqueName: .properties.linkedEnvironmentMetadata.uniqueName,
            domainName: .properties.linkedEnvironmentMetadata.domainName,
            createdTime: .properties.linkedEnvironmentMetadata.createdTime,
            isDormant: .properties.linkedEnvironmentMetadata.isDormant
        }' 2>/dev/null

        echo ""
        echo "=== Available Permissions ==="
        echo "$ENV_JSON" | jq -r '.properties.permissions | keys[]' 2>/dev/null | sort | head -20
        PERM_COUNT=$(echo "$ENV_JSON" | jq '.properties.permissions | keys | length' 2>/dev/null)
        print_info "Total permissions: $PERM_COUNT"
    else
        print_error "Failed to retrieve environment details"
    fi
    exit 0
fi

# ═══════════════════════════════════════════════════════════════
# FEATURE FLAGS MODE (ECS API)
# ═══════════════════════════════════════════════════════════════

if [ "$FEATURE_FLAGS" = true ]; then
    if [ -z "$ENV_ID" ]; then
        print_error "Environment ID is required (--env-id)"
        exit 1
    fi

    print_status "Getting Copilot Studio feature flags for environment: $ENV_ID"

    FEATURES_JSON=$(get_copilot_features "$TENANT" "$ENV_ID")

    if [ -n "$FEATURES_JSON" ]; then
        echo ""
        echo "=== Copilot Studio Feature Flags ==="
        echo "$FEATURES_JSON" | jq -r 'to_entries[] | "\(.key):
  Enabled: \(.value.params.isEnabled // "N/A")
  Params: \(.value.params | del(.isEnabled) | if . == {} then "none" else . end)
"' 2>/dev/null | head -60

        FLAG_COUNT=$(echo "$FEATURES_JSON" | jq 'keys | length' 2>/dev/null)
        print_status "Found $FLAG_COUNT feature flags"
    else
        print_error "Failed to retrieve feature flags"
    fi
    exit 0
fi

# ═══════════════════════════════════════════════════════════════
# LIST CONVERSATIONS MODE (PVA API)
# ═══════════════════════════════════════════════════════════════

if [ "$LIST_CONVERSATIONS" = true ]; then
    if [ -z "$ENV_ID" ]; then
        print_error "Environment ID is required (--env-id)"
        exit 1
    fi
    if [ -z "$BOT_ID" ]; then
        print_error "Bot ID is required (-b or --bot-id)"
        exit 1
    fi

    print_status "Listing conversations for bot: $BOT_ID"
    print_status "Environment: $ENV_ID"
    ensure_login
    print_authenticated_as

    CONVS_JSON=$(list_conversations "$ENV_ID" "$BOT_ID" || true)

    if [ -n "$CONVS_JSON" ] && [ "$CONVS_JSON" != "null" ]; then
        if ! echo "$CONVS_JSON" | jq -e 'type == "object"' >/dev/null 2>&1; then
            print_error "Unexpected response from PVA API"
            echo "$CONVS_JSON" | head -5
            exit 1
        fi

        # Check if it's an error response
        ERROR_MSG=$(echo "$CONVS_JSON" | jq -r '.error.message // empty' 2>/dev/null || true)
        if [ -n "$ERROR_MSG" ] && [ "$ERROR_MSG" != "null" ]; then
            print_error "API Error: $ERROR_MSG"
            exit 1
        fi

        echo ""
        echo "=== Conversations for $BOT_ID ==="

        # Count conversations (API returns 'entities' array)
        CONV_COUNT=$(echo "$CONVS_JSON" | jq '.entities | length' 2>/dev/null || echo "0")
        if [ -n "$CONV_COUNT" ] && [ "$CONV_COUNT" != "null" ] && [ "$CONV_COUNT" != "0" ]; then
            print_status "Found $CONV_COUNT conversations"
            echo ""

            # Display conversations as table
            echo "$CONVS_JSON" | jq -r '.entities[] | "ID: \(.id)
  Started: \(.startDate // "N/A")
  Modified: \(.modifiedDate // "N/A")
  Status: \(.status // "active")
  Channel: \(.channelId // "N/A")
  Last Step: \(.lastStep // "N/A")
---"' 2>/dev/null | head -150

            # Offer to save to file
            echo ""
            print_info "To export all conversations, use the saved file below:"

            # Create JSON output suitable for --export-all
            OUTPUT_FILE="${OUTPUT_DIR:-./reports}/conversations_${BOT_ID}.json"
            mkdir -p "$(dirname "$OUTPUT_FILE")"
            echo "$CONVS_JSON" | jq '{
                bot_schema: "'"$BOT_ID"'",
                environment_id: "'"$ENV_ID"'",
                extracted_at: (now | todate),
                total_count: (.entities | length),
                conversations: [.entities | to_entries[] | {index: .key, conversationId: .value.id, startDate: .value.startDate, status: .value.status}]
            }' > "$OUTPUT_FILE"
            print_status "Saved to: $OUTPUT_FILE"
            print_info "Use: --export-all --conversations-file '$OUTPUT_FILE'"
        else
            print_warning "No conversations found or response format unexpected"
            echo "$CONVS_JSON" | jq '.' 2>/dev/null || echo "$CONVS_JSON"
        fi
    else
        print_warning "Failed to retrieve conversations from PVA API. Trying Dataverse transcript fallback..."

        FALLBACK_DV_URL=""
        if [ -n "$DATAVERSE_URL_FROM_CONFIG" ]; then
            FALLBACK_DV_URL="$DATAVERSE_URL_FROM_CONFIG"
        elif [ -n "$ENV_ID" ]; then
            FALLBACK_DV_URL=$(get_dataverse_url "$ENV_ID" || true)
        fi

        if [ -n "$FALLBACK_DV_URL" ] && [ "$FALLBACK_DV_URL" != "null" ]; then
            FALLBACK_BOT_GUID=""
            FALLBACK_BOT_GUID=$(get_bot_guid "$FALLBACK_DV_URL" "$BOT_ID" 2>/dev/null || true)
            if [ -n "$FALLBACK_BOT_GUID" ]; then
                print_info "Fallback bot GUID: $FALLBACK_BOT_GUID"
            else
                print_warning "Could not resolve bot GUID for '$BOT_ID'; listing recent transcripts across all bots"
            fi

            TRANSCRIPT_FALLBACK=$(list_transcripts_with_stats "$FALLBACK_DV_URL" "$FALLBACK_BOT_GUID" 50 || echo "[]")
            if echo "$TRANSCRIPT_FALLBACK" | jq -e 'type == "array"' >/dev/null 2>&1; then
                TRANSCRIPT_COUNT=$(echo "$TRANSCRIPT_FALLBACK" | jq 'length')
                if [ "$TRANSCRIPT_COUNT" -gt 0 ]; then
                    print_status "Fallback found $TRANSCRIPT_COUNT transcript(s)"
                    echo ""
                    echo "=== Conversations for $BOT_ID (Dataverse fallback) ==="
                    echo "$TRANSCRIPT_FALLBACK" | jq -r '.[] | "ID: \(.id)
  Started: \(.start_time // "N/A")
  Name: \(.name // "N/A")
  Activities: \(.activity_count // 0)
---"'

                    OUTPUT_FILE="${OUTPUT_DIR:-./reports}/conversations_${BOT_ID}.json"
                    mkdir -p "$(dirname "$OUTPUT_FILE")"
                    echo "$TRANSCRIPT_FALLBACK" | jq '{
                        bot_schema: "'"$BOT_ID"'",
                        environment_id: "'"$ENV_ID"'",
                        extracted_at: (now | todate),
                        source: "dataverse_transcripts_fallback",
                        total_count: length,
                        conversations: [to_entries[] | {
                            index: .key,
                            conversationId: .value.id,
                            startDate: .value.start_time,
                            status: "transcript"
                        }]
                    }' > "$OUTPUT_FILE"
                    print_status "Saved to: $OUTPUT_FILE"
                    print_info "Use: --export-all --conversations-file '$OUTPUT_FILE'"
                    exit 0
                fi

                print_warning "No transcripts found via Dataverse fallback"
                exit 0
            fi
        fi

        print_error "Failed to retrieve conversations"
        exit 1
    fi
    exit 0
fi

# ═══════════════════════════════════════════════════════════════
# EXPORT ALL CONVERSATIONS MODE
# ═══════════════════════════════════════════════════════════════

if [ "$EXPORT_ALL" = true ]; then
    if [ -z "$CONVERSATIONS_FILE" ]; then
        print_error "Conversations file is required. Use --conversations-file 'path/to/file.json'"
        print_info "The file should contain a JSON with 'conversations' array containing 'conversationId' fields"
        print_info "You can get conversation IDs from the Copilot Studio Activity page"
        exit 1
    fi

    if [ ! -f "$CONVERSATIONS_FILE" ]; then
        print_error "Conversations file not found: $CONVERSATIONS_FILE"
        exit 1
    fi

    print_status "Loading conversations from: $CONVERSATIONS_FILE"

    # Extract conversation IDs from the JSON file
    CONV_COUNT=$(jq '.conversations | length' "$CONVERSATIONS_FILE")
    print_status "Found $CONV_COUNT conversations to export"

    # Extract bot schema from file if not provided
    if [ -z "$BOT_ID" ]; then
        BOT_ID=$(jq -r '.bot_schema // empty' "$CONVERSATIONS_FILE")
        if [ -n "$BOT_ID" ]; then
            print_info "Using bot_schema from file: $BOT_ID"
        fi
    fi

    # Extract environment_id from file if not provided
    if [ -z "$ENV_ID" ]; then
        ENV_ID=$(jq -r '.environment_id // empty' "$CONVERSATIONS_FILE")
        if [ -n "$ENV_ID" ]; then
            print_info "Using environment_id from file: $ENV_ID"
        fi
    fi

    # Build comma-separated list of conversation IDs
    CONV_IDS=$(jq -r '.conversations[].conversationId' "$CONVERSATIONS_FILE" | tr '\n' ',' | sed 's/,$//')

    if [ -z "$CONV_IDS" ]; then
        print_error "No conversation IDs found in file"
        exit 1
    fi

    print_info "Exporting conversations: ${CONV_COUNT} total"
    print_info "First conversation: $(echo "$CONV_IDS" | cut -d',' -f1 | cut -c1-50)..."

    # Continue with the normal export flow (CONV_IDS is now set)
fi

# ═══════════════════════════════════════════════════════════════
# LIST BOTS MODE
# ═══════════════════════════════════════════════════════════════

if [ "$LIST_BOTS" = true ]; then
    print_status "Listing bots in environment..."

    ensure_login
    print_authenticated_as

    # Use config Dataverse URL if available (skip BAP discovery)
    if [ -n "${DATAVERSE_URL_FROM_CONFIG:-}" ]; then
        DATAVERSE_URL="$DATAVERSE_URL_FROM_CONFIG"
    # Otherwise get Dataverse URL from environment ID
    elif [ -n "$ENV_ID" ]; then
        print_info "Looking up Dataverse URL for environment: $ENV_ID"
        DATAVERSE_URL=$(get_dataverse_url "$ENV_ID")

        if [ -z "$DATAVERSE_URL" ] || [ "$DATAVERSE_URL" = "null" ]; then
            # Try extracting from env URL if provided
            if [ -n "$ENV_URL" ]; then
                print_info "Trying to derive Dataverse URL from Power Platform environments..."
            fi

            # List available environments and their Dataverse URLs
            print_info "Fetching available environments..."
            ENVS=$(list_environments 2>/dev/null)

            if [ -n "$ENVS" ]; then
                echo ""
                echo "Available environments:"
                echo "$ENVS" | jq -r '.value[] | "  - \(.name): \(.properties.displayName) [\(.properties.linkedEnvironmentMetadata.instanceApiUrl // "No Dataverse")]"'
                echo ""

                # Try to find matching environment
                DATAVERSE_URL=$(echo "$ENVS" | jq -r --arg id "$ENV_ID" '.value[] | select(.name == $id or .properties.displayName == $id) | .properties.linkedEnvironmentMetadata.instanceApiUrl' | head -1)
            fi
        fi
    fi

    if [ -z "$DATAVERSE_URL" ] || [ "$DATAVERSE_URL" = "null" ]; then
        print_error "Could not determine Dataverse URL. Please specify --env-id with a valid environment ID."
        print_info "Run: pistudio envs"
        exit 1
    fi

    print_status "Dataverse URL: $DATAVERSE_URL"

    # List bots
    BOTS_RESULT=$(list_bots "$DATAVERSE_URL")

    if [ -n "$BOTS_RESULT" ]; then
        BOT_COUNT=$(echo "$BOTS_RESULT" | jq '.value | length')
        echo ""
        echo -e "${GREEN}Found $BOT_COUNT bot(s):${NC}"
        echo ""
        echo "$BOTS_RESULT" | jq -r '.value[] | "┌─────────────────────────────────────────────────────────────\n│ Name: \(.name)\n│ Schema Name: \(.schemaname) (use this as --bot-id)\n│ Bot ID: \(.botid)\n│ Created: \(.createdon)\n│ Status: \(.statuscode)\n│ Created By: \(.createdby.fullname // "Unknown")\n└─────────────────────────────────────────────────────────────"'

        echo ""
        echo "To export activities for a bot, use:"
        echo "  $0 -b 'SCHEMA_NAME' -c 'CONVERSATION_ID'"
    else
        print_warning "No bots found or unable to query Dataverse"
    fi

    exit 0
fi

# ═══════════════════════════════════════════════════════════════
# LIST SUBAGENTS MODE
# ═══════════════════════════════════════════════════════════════

if [ "$LIST_SUBAGENTS" = true ]; then
    print_status "Listing sub-agents..."

    ensure_login
    print_authenticated_as

    # Resolve Dataverse URL from environment
    DATAVERSE_URL=$(resolve_dataverse_url) || exit 1
    print_status "Dataverse URL: $DATAVERSE_URL"

    # Get sub-agents (optionally filtered by bot)
    SUBAGENTS_RESULT=$(list_subagents "$DATAVERSE_URL" "$BOT_ID")

    if [ -n "$SUBAGENTS_RESULT" ]; then
        SUBAGENT_COUNT=$(echo "$SUBAGENTS_RESULT" | jq '.value | length')
        echo ""
        if [ -n "$BOT_ID" ]; then
            echo -e "${GREEN}Found $SUBAGENT_COUNT sub-agent(s) for bot '$BOT_ID':${NC}"
        else
            echo -e "${GREEN}Found $SUBAGENT_COUNT sub-agent(s) across all bots:${NC}"
        fi
        echo ""
        echo "$SUBAGENTS_RESULT" | jq -r '.value[] | "┌─────────────────────────────────────────────────────────────\n│ Name: \(.name)\n│ Schema Name: \(.schemaname)\n│ Parent Bot: \(.parentbotid.name // "N/A")\n│ Parent Schema: \(.parentbotid.schemaname // "N/A")\n│ Created: \(.createdon)\n│ Modified: \(.modifiedon)\n│ Created By: \(.createdby.fullname // "Unknown")\n└─────────────────────────────────────────────────────────────"'

        echo ""
        echo "Sub-agent schema names are used in tool_usage.json for analytics."
    else
        print_warning "No sub-agents found"
    fi

    exit 0
fi

# ═══════════════════════════════════════════════════════════════
# LIST TRANSCRIPTS MODE (Dataverse - more reliable than PVA API)
# ═══════════════════════════════════════════════════════════════

if [ "$LIST_TRANSCRIPTS" = true ]; then
    print_status "Listing conversation transcripts from Dataverse..."

    ensure_login
    print_authenticated_as

    # Resolve Dataverse URL
    if [ -n "$DATAVERSE_URL_FROM_CONFIG" ]; then
        DATAVERSE_URL="$DATAVERSE_URL_FROM_CONFIG"
    elif [ -n "$ENV_ID" ]; then
        DATAVERSE_URL=$(get_dataverse_url "$ENV_ID")
    fi

    if [ -z "$DATAVERSE_URL" ] || [ "$DATAVERSE_URL" = "null" ]; then
        print_error "Could not determine Dataverse URL. Specify --env-id or use a profile with dataverseUrl"
        exit 1
    fi
    print_status "Dataverse URL: $DATAVERSE_URL"

    # Resolve bot GUID from schema name if needed
    if [ -z "$BOT_GUID" ] && [ -n "$BOT_ID" ]; then
        print_info "Looking up bot GUID for schema: $BOT_ID"
        BOT_GUID=$(get_bot_guid "$DATAVERSE_URL" "$BOT_ID")
        if [ -n "$BOT_GUID" ]; then
            print_status "Bot GUID: $BOT_GUID"
        else
            print_warning "Could not find bot GUID, listing all transcripts"
        fi
    fi

    # List transcripts with activity counts
    TRANSCRIPTS=$(list_transcripts_with_stats "$DATAVERSE_URL" "$BOT_GUID" 25)

    if [ -n "$TRANSCRIPTS" ] && [ "$TRANSCRIPTS" != "[]" ]; then
        TRANSCRIPT_COUNT=$(echo "$TRANSCRIPTS" | jq 'length')
        echo ""
        echo -e "${GREEN}Found $TRANSCRIPT_COUNT transcript(s):${NC}"
        echo ""
        echo "$TRANSCRIPTS" | jq -r '.[] | "┌─────────────────────────────────────────────────────────────\n│ ID: \(.id)\n│ Name: \(.name)\n│ Start: \(.start_time)\n│ Activities: \(.activity_count)\n└─────────────────────────────────────────────────────────────"'

        echo ""
        echo "To export a specific transcript, use:"
        echo "  $0 --from-dataverse --transcript-id 'TRANSCRIPT_ID' -p PROFILE"
    else
        print_warning "No transcripts found"
    fi

    exit 0
fi

# ═══════════════════════════════════════════════════════════════
# EXPORT AGENT CONFIG MODE
# ═══════════════════════════════════════════════════════════════

if [ "$EXPORT_AGENT" = true ]; then
    if [ -z "$AGENT_SCHEMA" ]; then
        print_error "Agent schema name is required. Use --agent-schema 'schema_name'"
        exit 1
    fi

    print_status "Exporting agent configuration: $AGENT_SCHEMA"

    ensure_login
    print_authenticated_as

    # Resolve Dataverse URL from environment
    DATAVERSE_URL=$(resolve_dataverse_url) || exit 1

    # Export agent configuration
    AGENT_RESULT=$(export_agent_config "$DATAVERSE_URL" "$AGENT_SCHEMA")

    if [ -n "$AGENT_RESULT" ]; then
        AGENT_COUNT=$(echo "$AGENT_RESULT" | jq '.value | length')

        if [ "$AGENT_COUNT" -gt 0 ]; then
            AGENT_NAME=$(echo "$AGENT_RESULT" | jq -r '.value[0].name')
            AGENT_ID=$(echo "$AGENT_RESULT" | jq -r '.value[0].botcomponentid')
            AGENT_DATA=$(echo "$AGENT_RESULT" | jq -r '.value[0].data // empty')
            AGENT_DESC=$(echo "$AGENT_RESULT" | jq -r '.value[0].description // "No description"')
            PARENT_BOT=$(echo "$AGENT_RESULT" | jq -r '.value[0].parentbotid.name // "N/A"')

            echo ""
            echo -e "${GREEN}Agent Configuration:${NC}"
            echo "────────────────────────────────────────────────────────────"
            echo "Name: $AGENT_NAME"
            echo "Schema: $AGENT_SCHEMA"
            echo "Component ID: $AGENT_ID"
            echo "Description: $AGENT_DESC"
            echo "Parent Bot: $PARENT_BOT"
            echo ""

            # Create output directory if needed
            mkdir -p "$OUTPUT_DIR"

            # Save YAML config to file
            SAFE_NAME=$(echo "$AGENT_NAME" | tr ' ' '_' | tr -cd '[:alnum:]_-')
            YAML_FILE="${OUTPUT_DIR}/${SAFE_NAME}_config.yaml"

            if [ -n "$AGENT_DATA" ]; then
                echo "$AGENT_DATA" > "$YAML_FILE"
                print_status "YAML configuration saved to: $YAML_FILE"

                echo ""
                echo -e "${CYAN}YAML Configuration Preview:${NC}"
                echo "────────────────────────────────────────────────────────────"
                head -50 "$YAML_FILE"
                echo ""
                echo "... (see full file for complete configuration)"
            else
                print_warning "No YAML data found for this agent"
            fi

            # Also save full JSON response
            JSON_FILE="${OUTPUT_DIR}/${SAFE_NAME}_full.json"
            echo "$AGENT_RESULT" | jq '.' > "$JSON_FILE"
            print_status "Full JSON saved to: $JSON_FILE"

            echo ""
            echo "To update this agent, use:"
            echo "  $0 --update-agent --agent-schema '$AGENT_SCHEMA' --field description --value 'New description'"
            echo "  $0 --update-agent --agent-schema '$AGENT_SCHEMA' --field data --value '$YAML_FILE'"
        else
            print_warning "No agent found with schema: $AGENT_SCHEMA"
        fi
    else
        print_error "Failed to query agent configuration"
    fi

    exit 0
fi

# ═══════════════════════════════════════════════════════════════
# UPDATE AGENT CONFIG MODE
# ═══════════════════════════════════════════════════════════════

if [ "$UPDATE_AGENT" = true ]; then
    if [ -z "$AGENT_SCHEMA" ]; then
        print_error "Agent schema name is required. Use --agent-schema 'schema_name'"
        exit 1
    fi
    if [ -z "$UPDATE_FIELD" ]; then
        print_error "Field name is required. Use --field 'description' or --field 'data'"
        exit 1
    fi
    if [ -z "$UPDATE_VALUE" ]; then
        print_error "Value is required. Use --value 'new_value'"
        exit 1
    fi

    print_status "Updating agent: $AGENT_SCHEMA"
    print_info "Field: $UPDATE_FIELD"

    ensure_login
    print_authenticated_as

    # Resolve Dataverse URL from environment
    DATAVERSE_URL=$(resolve_dataverse_url) || exit 1

    # Get component ID for the agent
    print_info "Looking up component ID..."
    COMPONENT_ID=$(get_agent_component_id "$DATAVERSE_URL" "$AGENT_SCHEMA")

    if [ -z "$COMPONENT_ID" ]; then
        print_error "Could not find agent with schema: $AGENT_SCHEMA"
        exit 1
    fi

    print_status "Component ID: $COMPONENT_ID"

    # If updating data field and value is a file path, read the file
    ACTUAL_VALUE="$UPDATE_VALUE"
    if [ "$UPDATE_FIELD" = "data" ] && [ -f "$UPDATE_VALUE" ]; then
        print_info "Reading YAML from file: $UPDATE_VALUE"
        ACTUAL_VALUE=$(cat "$UPDATE_VALUE")
    fi

    # Perform the update
    print_info "Sending PATCH request..."
    RESULT=$(update_agent_config "$DATAVERSE_URL" "$COMPONENT_ID" "$UPDATE_FIELD" "$ACTUAL_VALUE")

    # Extract HTTP status code (last line)
    HTTP_CODE=$(echo "$RESULT" | tail -1)
    RESPONSE_BODY=$(echo "$RESULT" | sed '$d')

    if [ "$HTTP_CODE" = "204" ]; then
        print_status "Agent updated successfully!"

        # Verify the update
        print_info "Verifying update..."
        VERIFY_RESULT=$(export_agent_config "$DATAVERSE_URL" "$AGENT_SCHEMA")

        if [ -n "$VERIFY_RESULT" ]; then
            NEW_VALUE=$(echo "$VERIFY_RESULT" | jq -r ".value[0].${UPDATE_FIELD} // empty")
            MODIFIED=$(echo "$VERIFY_RESULT" | jq -r '.value[0].modifiedon')

            echo ""
            echo -e "${GREEN}Update Verified:${NC}"
            echo "────────────────────────────────────────────────────────────"
            echo "Modified: $MODIFIED"

            if [ "$UPDATE_FIELD" = "description" ]; then
                echo "New Description: $NEW_VALUE"
            else
                echo "New $UPDATE_FIELD value applied (length: ${#NEW_VALUE} chars)"
            fi
        fi
    else
        print_error "Update failed with HTTP status: $HTTP_CODE"
        if [ -n "$RESPONSE_BODY" ]; then
            echo "Response: $RESPONSE_BODY"
        fi
        exit 1
    fi

    exit 0
fi

# ═══════════════════════════════════════════════════════════════
# CREATE AGENT MODE
# ═══════════════════════════════════════════════════════════════

if [ "$CREATE_AGENT" = true ]; then
    if [ -z "$BOT_ID" ]; then
        print_error "Parent bot ID is required. Use -b 'bot_schema_name'"
        exit 1
    fi
    if [ -z "$AGENT_NAME" ]; then
        print_error "Agent name is required. Use --agent-name 'My Agent Name'"
        exit 1
    fi

    print_status "Creating new sub-agent: $AGENT_NAME"
    print_info "Parent bot: $BOT_ID"

    ensure_login
    print_authenticated_as

    # Resolve Dataverse URL from environment
    DATAVERSE_URL=$(resolve_dataverse_url) || exit 1

    # Get parent bot ID
    print_info "Looking up parent bot ID..."
    PARENT_BOT_ID=$(get_parent_bot_id "$DATAVERSE_URL" "$BOT_ID")

    if [ -z "$PARENT_BOT_ID" ]; then
        print_error "Could not find bot with schema: $BOT_ID"
        exit 1
    fi

    print_status "Parent bot ID: $PARENT_BOT_ID"

    # Load YAML config
    if [ -n "$YAML_FILE" ] && [ -f "$YAML_FILE" ]; then
        print_info "Loading YAML configuration from: $YAML_FILE"
        YAML_DATA=$(cat "$YAML_FILE")
    else
        # Create default YAML config
        print_info "Using default YAML configuration"
        YAML_DATA="kind: AgentDialog
response:
  activity:
  mode: Generated

inputs:
  - kind: AutomaticTaskInput
    propertyName: query
    description: The input query or topic

beginDialog:
  kind: OnToolSelected
  id: main
  description: ${AGENT_NAME}

settings:
  instructions: |-
    You are ${AGENT_NAME}.
    Respond helpfully to user queries.

inputType:
  properties:
    query:
      displayName: query
      description: The input query
      isRequired: true
      type: String

outputType:
  properties:
    result:
      displayName: result
      description: The output result
      type: String"
    fi

    # Extract description from YAML beginDialog.description if available
    AGENT_DESC=$(echo "$YAML_DATA" | grep -A1 'beginDialog:' | grep 'description:' | sed 's/.*description: *//' | head -1)
    if [ -z "$AGENT_DESC" ]; then
        AGENT_DESC="Created via CLI"
    fi

    # Create the agent
    RESULT=$(create_agent "$DATAVERSE_URL" "$AGENT_NAME" "$PARENT_BOT_ID" "$BOT_ID" "$YAML_DATA" "$AGENT_DESC")

    # Extract HTTP status code (last line)
    HTTP_CODE=$(echo "$RESULT" | tail -1)
    RESPONSE_BODY=$(echo "$RESULT" | sed '$d')

    if [ "$HTTP_CODE" = "201" ]; then
        print_status "Agent created successfully!"

        # Parse the response to get details
        NEW_SCHEMA=$(echo "$RESPONSE_BODY" | jq -r '.schemaname')
        NEW_ID=$(echo "$RESPONSE_BODY" | jq -r '.botcomponentid')
        CREATED_ON=$(echo "$RESPONSE_BODY" | jq -r '.createdon')

        echo ""
        echo -e "${GREEN}New Agent Details:${NC}"
        echo "────────────────────────────────────────────────────────────"
        echo "Name: $AGENT_NAME"
        echo "Schema: $NEW_SCHEMA"
        echo "Component ID: $NEW_ID"
        echo "Created: $CREATED_ON"
        echo ""
        echo "To export this agent's config:"
        echo "  $0 --export-agent --agent-schema '$NEW_SCHEMA'"
        echo ""
        echo "To update this agent:"
        echo "  $0 --update-agent --agent-schema '$NEW_SCHEMA' --field data --value 'config.yaml'"
        echo ""
        echo "To delete this agent:"
        echo "  $0 --delete-agent --agent-schema '$NEW_SCHEMA'"
    else
        print_error "Failed to create agent (HTTP $HTTP_CODE)"
        if [ -n "$RESPONSE_BODY" ]; then
            echo "$RESPONSE_BODY" | jq -r '.error.message // .' 2>/dev/null || echo "$RESPONSE_BODY"
        fi
        exit 1
    fi

    exit 0
fi

# ═══════════════════════════════════════════════════════════════
# DELETE AGENT MODE
# ═══════════════════════════════════════════════════════════════

if [ "$DELETE_AGENT" = true ]; then
    if [ -z "$AGENT_SCHEMA" ]; then
        print_error "Agent schema name is required. Use --agent-schema 'schema_name'"
        exit 1
    fi

    print_warning "Deleting agent: $AGENT_SCHEMA"

    ensure_login
    print_authenticated_as

    # Resolve Dataverse URL from environment
    DATAVERSE_URL=$(resolve_dataverse_url) || exit 1

    # Get component ID
    print_info "Looking up component ID..."
    COMPONENT_ID=$(get_agent_component_id "$DATAVERSE_URL" "$AGENT_SCHEMA")

    if [ -z "$COMPONENT_ID" ]; then
        print_error "Could not find agent with schema: $AGENT_SCHEMA"
        exit 1
    fi

    print_status "Component ID: $COMPONENT_ID"

    # Confirm deletion
    echo ""
    echo -e "${YELLOW}Are you sure you want to delete this agent?${NC}"
    echo "This action cannot be undone."
    echo ""
    read -p "Type 'yes' to confirm: " CONFIRM

    if [ "$CONFIRM" != "yes" ]; then
        print_info "Deletion cancelled"
        exit 0
    fi

    # Delete the agent
    print_info "Sending DELETE request..."
    RESULT=$(delete_agent "$DATAVERSE_URL" "$COMPONENT_ID")

    # Extract HTTP status code (last line)
    HTTP_CODE=$(echo "$RESULT" | tail -1)

    if [ "$HTTP_CODE" = "204" ]; then
        print_status "Agent deleted successfully!"
    else
        print_error "Delete failed with HTTP status: $HTTP_CODE"
        exit 1
    fi

    exit 0
fi

# Setup output directory
if [ "$ANALYTICS_ONLY" = true ]; then
    REPORT_DIR="$OUTPUT_DIR"
    if [ ! -f "${REPORT_DIR}/raw_activities.json" ]; then
        print_error "No raw_activities.json found in $REPORT_DIR"
        exit 1
    fi
else
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    REPORT_DIR="${OUTPUT_DIR}/copilot_export_${TIMESTAMP}"
    mkdir -p "$REPORT_DIR"
fi

print_status "Output directory: $REPORT_DIR"

# Authenticate if not analytics-only
if [ "$ANALYTICS_ONLY" = false ]; then
    print_status "Checking authentication..."
    ensure_login
    print_authenticated_as

    TOKEN=$(get_access_token "$RESOURCE")
fi

# Function to fetch conversation history
fetch_history() {
    local conv_id="$1"
    local encoded_conv_id=$(echo "$conv_id" | sed 's/:/%3A/g' | sed 's/@/%40/g')

    # Determine the correct PVA API URL
    local pva_url=""
    if [ -n "$ENV_ID" ]; then
        pva_url=$(get_pva_api_url "$ENV_ID")
    else
        pva_url="${ENV_URL:-}"
    fi

    if [ -z "$pva_url" ]; then
        print_error "Could not resolve PVA API URL"
        return 1
    fi

    local history
    history=$(curl -sS "${pva_url}/powervirtualagents/bots/${BOT_ID}/channels/pva-studio/conversations/${encoded_conv_id}/history?api-version=1&pageSize=${PAGE_SIZE}&filterType=All" \
        -H 'accept: application/json' \
        -H "authorization: Bearer $TOKEN" \
        -H 'origin: https://copilotstudio.preview.microsoft.com' 2>/dev/null || true)

    if [ -z "$history" ]; then
        print_warning "Failed to fetch history for conversation: ${conv_id:0:30}..." >&2
        return 1
    fi

    echo "$history"
}

# Fetch data if not analytics-only
if [ "$ANALYTICS_ONLY" = false ]; then
    # ═══════════════════════════════════════════════════════════════
    # FROM_DATAVERSE MODE - Export from Dataverse transcripts table
    # More reliable than PVA API which can fail for some environments
    # ═══════════════════════════════════════════════════════════════
    if [ "$FROM_DATAVERSE" = true ]; then
        if [ -z "$TRANSCRIPT_ID" ]; then
            print_error "Transcript ID required. Use --transcript-id 'GUID' or run --list-transcripts first"
            exit 1
        fi

        # Resolve Dataverse URL
        if [ -n "$DATAVERSE_URL_FROM_CONFIG" ]; then
            DATAVERSE_URL="$DATAVERSE_URL_FROM_CONFIG"
        elif [ -n "$ENV_ID" ]; then
            DATAVERSE_URL=$(get_dataverse_url "$ENV_ID")
        fi

        if [ -z "$DATAVERSE_URL" ] || [ "$DATAVERSE_URL" = "null" ]; then
            print_error "Could not determine Dataverse URL. Specify --env-id or use a profile with dataverseUrl"
            exit 1
        fi

        print_status "Dataverse URL: $DATAVERSE_URL"
        print_status "Fetching transcript: $TRANSCRIPT_ID"

        # Fetch transcript content from Dataverse
        TRANSCRIPT_CONTENT=$(fetch_transcript "$DATAVERSE_URL" "$TRANSCRIPT_ID")

        if [ -n "$TRANSCRIPT_CONTENT" ] && [ "$TRANSCRIPT_CONTENT" != "null" ]; then
            ALL_ACTIVITIES="$TRANSCRIPT_CONTENT"
            ACTIVITY_COUNT=$(echo "$ALL_ACTIVITIES" | jq '.activities | length' 2>/dev/null || echo "0")
            print_status "Retrieved $ACTIVITY_COUNT activities from Dataverse transcript"
        else
            print_error "Failed to fetch transcript or transcript is empty"
            exit 1
        fi

    # ═══════════════════════════════════════════════════════════════
    # STANDARD MODE - Export from PVA API (original behavior)
    # ═══════════════════════════════════════════════════════════════
    else
        if [ -z "$CONV_IDS" ]; then
            print_error "No conversation ID specified. Use -c flag or --from-dataverse with --transcript-id"
            exit 1
        fi

        # Handle multiple conversation IDs
        IFS=',' read -ra CONV_ARRAY <<< "$CONV_IDS"
        ALL_ACTIVITIES='{"activities":[]}'

        for conv_id in "${CONV_ARRAY[@]}"; do
            conv_id=$(echo "$conv_id" | xargs) # trim whitespace
            print_status "Fetching conversation: ${conv_id:0:30}..."

            HISTORY=$(fetch_history "$conv_id" || true)

            if [ -n "$HISTORY" ] && [ "$HISTORY" != "null" ]; then
                # Merge activities
                ALL_ACTIVITIES=$(echo "$ALL_ACTIVITIES" "$HISTORY" | jq -s '.[0].activities += .[1].activities | .[0]')
            fi
        done
    fi  # End of FROM_DATAVERSE conditional

    # Apply date filter if specified
    if [ -n "$DAYS_FILTER" ]; then
        CUTOFF_DATE=$(date -v-${DAYS_FILTER}d +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -d "-${DAYS_FILTER} days" +%Y-%m-%dT%H:%M:%S)
        print_info "Filtering activities after: $CUTOFF_DATE"
        ALL_ACTIVITIES=$(echo "$ALL_ACTIVITIES" | jq --arg cutoff "$CUTOFF_DATE" '.activities |= [.[] | select(.timestamp >= $cutoff)]')
    fi

    # Save raw data
    echo "$ALL_ACTIVITIES" | jq '.' > "${REPORT_DIR}/raw_activities.json"
    print_status "Saved raw_activities.json"
fi

# Load raw data for analysis
RAW_DATA=$(cat "${REPORT_DIR}/raw_activities.json")

print_status "Generating analytics..."

# ═══════════════════════════════════════════════════════════════
# ANALYTICS GENERATION - ENHANCED WITH PHASE SEGMENTATION
# ═══════════════════════════════════════════════════════════════

# 1. Summary Statistics
echo "$RAW_DATA" | jq '{
    export_info: {
        timestamp: (now | todate),
        bot_id: "'"$BOT_ID"'",
        total_conversations: (if "'"$CONV_IDS"'" != "" then ("'"$CONV_IDS"'" | split(",") | length) else 1 end)
    },
    activity_summary: {
        total: (.activities | length),
        messages: ([.activities[] | select(.type == "message")] | length),
        events: ([.activities[] | select(.type == "event")] | length),
        user_messages: ([.activities[] | select(.type == "message" and .from.role == "user")] | length),
        bot_messages: ([.activities[] | select(.type == "message" and .from.role == "bot")] | length)
    },
    time_range: {
        start: ([.activities[].timestamp] | min),
        end: ([.activities[].timestamp] | max)
    }
}' > "${REPORT_DIR}/summary.json"

# 2. Tool Usage Analytics
echo "$RAW_DATA" | jq '[.activities[] | select(.type == "event") | .value.steps // empty] | flatten | group_by(.) | map({
    tool: .[0],
    count: length,
    category: (if .[0] | startswith("P:") then "builtin" elif .[0] | contains(".agent.") then "custom_agent" else "other" end)
}) | sort_by(-.count)' > "${REPORT_DIR}/tool_usage.json"
print_status "Generated tool_usage.json"

# 3. Execution Time Metrics
echo "$RAW_DATA" | jq '[.activities[] | select(.type == "event" and .value.executionTime) | {
    step_id: .value.stepId,
    task: .value.taskDialogId,
    execution_time: .value.executionTime,
    state: .value.state,
    timestamp: .timestamp
}] | {
    total_steps: length,
    completed: ([.[] | select(.state == "completed")] | length),
    execution_times: [.[].execution_time | select(. != null)],
    by_task: (group_by(.task) | map({
        task: .[0].task,
        count: length,
        states: (group_by(.state) | map({state: .[0].state, count: length}))
    }))
}' > "${REPORT_DIR}/execution_metrics.json"
print_status "Generated execution_metrics.json"

# 4. AI Observations/Insights Extraction
echo "$RAW_DATA" | jq '[.activities[] | select(.type == "event" and .value.observation) | {
    timestamp: .timestamp,
    task: .value.taskDialogId,
    observation: .value.observation,
    execution_time: .value.executionTime
}]' > "${REPORT_DIR}/ai_observations.json"
print_status "Generated ai_observations.json"

# 5. Messages with context
echo "$RAW_DATA" | jq '[.activities[] | select(.type == "message") | {
    id: .id,
    timestamp: .timestamp,
    role: .from.role,
    sender: .from.name,
    text: .text,
    reply_to: .replyToId,
    has_attachments: ((.attachments | length) > 0)
}] | sort_by(.timestamp)' > "${REPORT_DIR}/messages.json"
print_status "Generated messages.json"

# 6. Dynamic Plan Timeline
echo "$RAW_DATA" | jq '[.activities[] | select(.type == "event" and (.name | startswith("DynamicPlan"))) | {
    timestamp: .timestamp,
    event: .name,
    plan_id: (.value.planId // .value.planIdentifier),
    step_id: .value.stepId,
    steps: .value.steps,
    is_final: .value.isFinalPlan,
    state: .value.state,
    cancelled: .value.wasCancelled
}] | sort_by(.timestamp)' > "${REPORT_DIR}/plan_timeline.json"
print_status "Generated plan_timeline.json"

# ═══════════════════════════════════════════════════════════════
# 7. PHASE-BASED ANALYTICS (Research Agent Segmentation)
# ═══════════════════════════════════════════════════════════════

# Extract phase information from messages
echo "$RAW_DATA" | jq '
# Sort all activities by timestamp
.activities | sort_by(.timestamp) |

# Extract phase markers and task descriptions
[.[] | select(.type == "message" and .from.role == "bot") |
  if (.text | test("^Phase Router - Current phase: [0-9]+$")) then
    {type: "phase_start", phase: (.text | capture("phase: (?<p>[0-9]+)").p | tonumber), timestamp: .timestamp}
  elif (.text | test("^\\[[0-9]+/[0-9]+\\]")) then
    {type: "phase_task", phase: (.text | capture("^\\[(?<p>[0-9]+)/").p | tonumber), task: (.text | capture("^\\[[0-9]+/[0-9]+\\] (?<t>.+)$").t), timestamp: .timestamp}
  else
    null
  end
] | [.[] | select(. != null)] |

# Group to build phase definitions
group_by(.phase) | map({
  phase: .[0].phase,
  task: ([.[] | select(.type == "phase_task") | .task] | first // "Unknown Task"),
  start_time: ([.[] | .timestamp] | min)
}) | sort_by(.phase)
' > "${REPORT_DIR}/phase_definitions.json"
print_status "Generated phase_definitions.json"

# Now create detailed phase analytics with tool usage per phase
echo "$RAW_DATA" | jq --slurpfile phases "${REPORT_DIR}/phase_definitions.json" '
# Get sorted activities
.activities | sort_by(.timestamp) as $activities |

# Get all timestamps for phase boundaries
[$phases[0][] | {phase: .phase, start: .start_time}] | sort_by(.start) as $boundaries |

# For each phase, find activities in that time window
[range(0; ($boundaries | length)) as $i |
  $boundaries[$i] as $current |
  (if $i < (($boundaries | length) - 1) then $boundaries[$i + 1].start else null end) as $next_start |

  # Get phase definition
  ($phases[0][] | select(.phase == $current.phase)) as $def |

  # Filter activities for this phase window
  [$activities[] | select(
    .timestamp >= $current.start and
    (if $next_start then .timestamp < $next_start else true end)
  )] as $phase_activities |

  # Count events and extract tool usage
  {
    phase: $current.phase,
    task: ($def.task // "Unknown"),
    start_time: $current.start,
    end_time: ($phase_activities | last | .timestamp // $current.start),

    # Activity counts
    total_activities: ($phase_activities | length),
    messages: ([$phase_activities[] | select(.type == "message")] | length),
    events: ([$phase_activities[] | select(.type == "event")] | length),

    # Tool usage for this phase
    tool_usage: (
      [$phase_activities[] | select(.type == "event") | .value.steps // empty] |
      flatten |
      group_by(.) |
      map({tool: .[0], count: length}) |
      sort_by(-.count)
    ),

    # Search count (UniversalSearchTool calls)
    search_count: (
      [$phase_activities[] | select(.type == "event") | .value.steps // empty] |
      flatten |
      [.[] | select(. == "P:UniversalSearchTool")] |
      length
    ),

    # Messages in this phase
    bot_messages: ([$phase_activities[] | select(.type == "message" and .from.role == "bot") | .text] | length),

    # Observations count
    observations: ([$phase_activities[] | select(.type == "event" and .value.observation)] | length),

    # Duration in seconds (approximate)
    duration_seconds: (
      if ($phase_activities | length) > 1 then
        (($phase_activities | last | .timestamp) as $end |
         ($phase_activities | first | .timestamp) as $start |
         # Parse ISO timestamps and compute difference
         (($end | split(".")[0] | strptime("%Y-%m-%dT%H:%M:%S") | mktime) -
          ($start | split(".")[0] | strptime("%Y-%m-%dT%H:%M:%S") | mktime)))
      else 0 end
    )
  }
] | sort_by(.phase)
' > "${REPORT_DIR}/phase_analytics.json"
print_status "Generated phase_analytics.json"

# Create phase summary with key metrics
echo "$RAW_DATA" | jq --slurpfile phase_data "${REPORT_DIR}/phase_analytics.json" '
{
  total_phases: ($phase_data[0] | length),
  phases: $phase_data[0],

  # Aggregate metrics
  totals: {
    total_searches: ([$phase_data[0][].search_count] | add // 0),
    total_observations: ([$phase_data[0][].observations] | add // 0),
    total_duration_seconds: ([$phase_data[0][].duration_seconds] | add // 0),
    avg_searches_per_phase: (if ($phase_data[0] | length) > 0 then (([$phase_data[0][].search_count] | add // 0) / ($phase_data[0] | length)) else 0 end),
    avg_duration_per_phase: (if ($phase_data[0] | length) > 0 then (([$phase_data[0][].duration_seconds] | add // 0) / ($phase_data[0] | length)) else 0 end)
  },

  # Top tools across all phases
  top_tools: (
    if ($phase_data[0] | length) > 0 then
      ([$phase_data[0][].tool_usage[] | select(. != null)] |
      group_by(.tool) |
      map({tool: .[0].tool, total: ([.[].count] | add // 0)}) |
      sort_by(-.total) |
      .[0:10])
    else [] end
  ),

  # Phase rankings
  rankings: {
    by_searches: ([$phase_data[0][] | {phase: .phase, task: .task, searches: .search_count}] | sort_by(-.searches)),
    by_duration: ([$phase_data[0][] | {phase: .phase, task: .task, duration: .duration_seconds}] | sort_by(-.duration)),
    by_observations: ([$phase_data[0][] | {phase: .phase, task: .task, observations: .observations}] | sort_by(-.observations))
  }
}
' > "${REPORT_DIR}/phase_summary.json"
print_status "Generated phase_summary.json"

# Extract content per phase (what the agent found)
echo "$RAW_DATA" | jq --slurpfile phases "${REPORT_DIR}/phase_definitions.json" '
.activities | sort_by(.timestamp) as $activities |
[$phases[0][] | {phase: .phase, start: .start_time}] | sort_by(.start) as $boundaries |

[range(0; ($boundaries | length)) as $i |
  $boundaries[$i] as $current |
  (if $i < (($boundaries | length) - 1) then $boundaries[$i + 1].start else null end) as $next_start |
  ($phases[0][] | select(.phase == $current.phase)) as $def |

  [$activities[] | select(
    .timestamp >= $current.start and
    (if $next_start then .timestamp < $next_start else true end) and
    .type == "message" and .from.role == "bot" and
    (.text | test("^Phase Router|^\\[[0-9]+/[0-9]+\\]") | not)
  )] as $content_messages |

  {
    phase: $current.phase,
    task: ($def.task // "Unknown"),
    findings: [$content_messages[] | .text],
    finding_count: ($content_messages | length)
  }
] | sort_by(.phase)
' > "${REPORT_DIR}/phase_findings.json"
print_status "Generated phase_findings.json"

# Create observations grouped by phase
echo "$RAW_DATA" | jq --slurpfile phases "${REPORT_DIR}/phase_definitions.json" '
.activities | sort_by(.timestamp) as $activities |
[$phases[0][] | {phase: .phase, start: .start_time, task: .task}] | sort_by(.start) as $boundaries |

[range(0; ($boundaries | length)) as $i |
  $boundaries[$i] as $current |
  (if $i < (($boundaries | length) - 1) then $boundaries[$i + 1].start else null end) as $next_start |

  [$activities[] | select(
    .timestamp >= $current.start and
    (if $next_start then .timestamp < $next_start else true end) and
    .type == "event" and .value.observation
  )] as $obs |

  {
    phase: $current.phase,
    task: $current.task,
    observations: [$obs[] | {
      timestamp: .timestamp,
      observation: .value.observation
    }],
    observation_count: ($obs | length)
  }
] | [.[] | select(.observation_count > 0)] | sort_by(.phase)
' > "${REPORT_DIR}/phase_observations.json"
print_status "Generated phase_observations.json"

# Extract all searches with queries, results, and phase info
echo "$RAW_DATA" | jq --slurpfile phases "${REPORT_DIR}/phase_definitions.json" '
.activities | sort_by(.timestamp) as $activities |
[$phases[0][] | {phase: .phase, start: .start_time, task: .task}] | sort_by(.start) as $boundaries |

# Function to find phase for a timestamp
def get_phase_for_timestamp($ts):
  . as $bounds |
  reduce range(0; $bounds | length) as $i (
    {phase: -1, task: "Unknown"};
    if ($i < ($bounds | length - 1)) then
      if $ts >= $bounds[$i].start and $ts < $bounds[$i + 1].start then
        {phase: $bounds[$i].phase, task: $bounds[$i].task}
      else . end
    else
      if $ts >= $bounds[$i].start then
        {phase: $bounds[$i].phase, task: $bounds[$i].task}
      else . end
    end
  );

# Extract GenerativeAnswersSupportData events (contain search queries and results)
[$activities[] | select(.name == "GenerativeAnswersSupportData")] |
[to_entries[] |
  .value as $event |
  ($boundaries | get_phase_for_timestamp($event.timestamp)) as $phase_info |
  {
    id: .key,
    timestamp: $event.timestamp,
    phase: $phase_info.phase,
    phase_task: $phase_info.task,
    query: ($event.value.rewrittenMessage // $event.value.message // "Unknown query"),
    search_terms: ($event.value.searchTerms // []),
    result_count: (($event.value.searchResults // []) | length),
    results: [($event.value.searchResults // [])[] | {
      title: .Title,
      url: .Url,
      snippet: (.Snippet // .Text // "" | .[0:300])
    }][0:5],
    citations: [($event.value.verifiedSearchResults // [])[] | {
      title: (.snippet // "" | .[0:150]),
      url: .url,
      source: .searchType
    }][0:10]
  }
] | sort_by(.timestamp)
' > "${REPORT_DIR}/search_data.json"
print_status "Generated search_data.json"

# ═══════════════════════════════════════════════════════════════
# CSV EXPORT
# ═══════════════════════════════════════════════════════════════

if [[ "$FORMATS" == *"csv"* ]]; then
    # Messages CSV
    echo "timestamp,role,sender,text_preview,reply_to" > "${REPORT_DIR}/messages.csv"
    echo "$RAW_DATA" | jq -r '.activities[] | select(.type == "message") |
        [.timestamp, .from.role, .from.name, (.text | gsub("\n"; " ") | gsub("\""; "\"\"") | .[0:300]), .replyToId] | @csv' \
        >> "${REPORT_DIR}/messages.csv"

    # Tool usage CSV
    echo "tool,count,category" > "${REPORT_DIR}/tool_usage.csv"
    cat "${REPORT_DIR}/tool_usage.json" | jq -r '.[] | [.tool, .count, .category] | @csv' >> "${REPORT_DIR}/tool_usage.csv"

    # AI observations CSV
    echo "timestamp,task,observation_preview,execution_time" > "${REPORT_DIR}/ai_observations.csv"
    cat "${REPORT_DIR}/ai_observations.json" | jq -r '.[] | [.timestamp, .task, (.observation | tostring | gsub("\n"; " ") | .[0:500]), .execution_time] | @csv' >> "${REPORT_DIR}/ai_observations.csv"

    print_status "Generated CSV files"
fi

# ═══════════════════════════════════════════════════════════════
# HTML DASHBOARD
# ═══════════════════════════════════════════════════════════════

if [[ "$FORMATS" == *"html"* ]]; then
    SUMMARY=$(cat "${REPORT_DIR}/summary.json")
    TOOL_USAGE=$(cat "${REPORT_DIR}/tool_usage.json")
    MESSAGES=$(cat "${REPORT_DIR}/messages.json")
    PHASE_SUMMARY=$(cat "${REPORT_DIR}/phase_summary.json" 2>/dev/null || echo '{"total_phases":0,"phases":[],"totals":{}}')
    PHASE_FINDINGS=$(cat "${REPORT_DIR}/phase_findings.json" 2>/dev/null || echo '[]')
    SEARCH_DATA=$(cat "${REPORT_DIR}/search_data.json" 2>/dev/null || echo '[]')

    TOTAL_ACTIVITIES=$(echo "$SUMMARY" | jq '.activity_summary.total')
    TOTAL_MESSAGES=$(echo "$SUMMARY" | jq '.activity_summary.messages')
    USER_MESSAGES=$(echo "$SUMMARY" | jq '.activity_summary.user_messages')
    BOT_MESSAGES=$(echo "$SUMMARY" | jq '.activity_summary.bot_messages')
    TIME_START=$(echo "$SUMMARY" | jq -r '.time_range.start')
    TIME_END=$(echo "$SUMMARY" | jq -r '.time_range.end')
    TOTAL_PHASES=$(echo "$PHASE_SUMMARY" | jq '.total_phases // 0')
    TOTAL_SEARCHES=$(echo "$PHASE_SUMMARY" | jq '.totals.total_searches // 0')
    TOTAL_DURATION=$(echo "$PHASE_SUMMARY" | jq '.totals.total_duration_seconds // 0')

    # Get the directory where the script is located
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    TEMPLATE_FILE="${SCRIPT_DIR}/../templates/dashboard.html"

    if [[ ! -f "$TEMPLATE_FILE" ]]; then
        print_error "Dashboard template not found at $TEMPLATE_FILE"
        print_status "Skipping HTML dashboard generation"
    else
        GENERATED_INFO="◆ Generated: $(date) ◆ Bot: $BOT_ID ◆ Agent Activity Analytics"

        # Write JSON data to temp files for safe inclusion
        echo "$TOOL_USAGE" > "${REPORT_DIR}/.tmp_tool_usage.json"
        echo "$MESSAGES" > "${REPORT_DIR}/.tmp_messages.json"
        echo "$PHASE_SUMMARY" > "${REPORT_DIR}/.tmp_phase_summary.json"
        echo "$PHASE_FINDINGS" > "${REPORT_DIR}/.tmp_phase_findings.json"
        echo "$SEARCH_DATA" > "${REPORT_DIR}/.tmp_search_data.json"

        # Use awk for safe substitution of all values including multiline JSON
        awk -v generated_info="$GENERATED_INFO" \
            -v total_activities="$TOTAL_ACTIVITIES" \
            -v total_phases="$TOTAL_PHASES" \
            -v total_searches="$TOTAL_SEARCHES" \
            -v total_duration="$TOTAL_DURATION" \
            -v total_messages="$TOTAL_MESSAGES" \
            -v user_messages="$USER_MESSAGES" \
            -v bot_messages="$BOT_MESSAGES" \
            -v time_start="$TIME_START" \
            -v time_end="$TIME_END" \
            -v tool_usage_file="${REPORT_DIR}/.tmp_tool_usage.json" \
            -v messages_file="${REPORT_DIR}/.tmp_messages.json" \
            -v phase_summary_file="${REPORT_DIR}/.tmp_phase_summary.json" \
            -v phase_findings_file="${REPORT_DIR}/.tmp_phase_findings.json" \
            -v search_data_file="${REPORT_DIR}/.tmp_search_data.json" \
            '
            BEGIN {
                # Read JSON files into variables
                while ((getline line < tool_usage_file) > 0) tool_usage = tool_usage line "\n"
                close(tool_usage_file)
                while ((getline line < messages_file) > 0) messages = messages line "\n"
                close(messages_file)
                while ((getline line < phase_summary_file) > 0) phase_summary = phase_summary line "\n"
                close(phase_summary_file)
                while ((getline line < phase_findings_file) > 0) phase_findings = phase_findings line "\n"
                close(phase_findings_file)
                while ((getline line < search_data_file) > 0) search_data = search_data line "\n"
                close(search_data_file)
                # Remove trailing newline
                sub(/\n$/, "", tool_usage)
                sub(/\n$/, "", messages)
                sub(/\n$/, "", phase_summary)
                sub(/\n$/, "", phase_findings)
                sub(/\n$/, "", search_data)
            }
            {
                gsub(/\{\{GENERATED_INFO\}\}/, generated_info)
                gsub(/\{\{TOTAL_ACTIVITIES\}\}/, total_activities)
                gsub(/\{\{TOTAL_PHASES\}\}/, total_phases)
                gsub(/\{\{TOTAL_SEARCHES\}\}/, total_searches)
                gsub(/\{\{TOTAL_DURATION\}\}/, total_duration)
                gsub(/\{\{TOTAL_MESSAGES\}\}/, total_messages)
                gsub(/\{\{USER_MESSAGES\}\}/, user_messages)
                gsub(/\{\{BOT_MESSAGES\}\}/, bot_messages)
                gsub(/\{\{TIME_START\}\}/, time_start)
                gsub(/\{\{TIME_END\}\}/, time_end)
                gsub(/\{\{TOOL_USAGE\}\}/, tool_usage)
                gsub(/\{\{MESSAGES\}\}/, messages)
                gsub(/\{\{PHASE_SUMMARY\}\}/, phase_summary)
                gsub(/\{\{PHASE_FINDINGS\}\}/, phase_findings)
                gsub(/\{\{SEARCH_DATA\}\}/, search_data)
                print
            }
            ' "$TEMPLATE_FILE" > "${REPORT_DIR}/dashboard.html"

        # Clean up temp files
        rm -f "${REPORT_DIR}/.tmp_"*.json

        print_status "Generated dashboard.html from template"
    fi
fi

# Placeholder for removed embedded HTML - the script continues below
if false; then
    cat > /dev/null << 'HTMLHEAD_REMOVED'
    <style>
        :root {
            --bg-deep: #0a0e17;
            --bg-surface: #111827;
            --bg-elevated: #1a2234;
            --bg-glass: rgba(17, 24, 39, 0.7);
            --border-subtle: rgba(56, 189, 248, 0.1);
            --border-glow: rgba(56, 189, 248, 0.3);
            --text-primary: #f0f4f8;
            --text-secondary: #8b9dc3;
            --text-muted: #4a5568;
            --accent-cyan: #22d3ee;
            --accent-teal: #2dd4bf;
            --accent-violet: #a78bfa;
            --accent-rose: #fb7185;
            --accent-amber: #fbbf24;
            --glow-cyan: 0 0 40px rgba(34, 211, 238, 0.15);
            --glow-violet: 0 0 40px rgba(167, 139, 250, 0.15);
        }

        * { margin: 0; padding: 0; box-sizing: border-box; }

        body {
            font-family: 'Outfit', sans-serif;
            background: var(--bg-deep);
            color: var(--text-primary);
            line-height: 1.7;
            min-height: 100vh;
            position: relative;
            overflow-x: hidden;
        }

        /* Atmospheric background */
        body::before {
            content: '';
            position: fixed;
            inset: 0;
            background:
                radial-gradient(ellipse 80% 50% at 20% -20%, rgba(34, 211, 238, 0.08) 0%, transparent 50%),
                radial-gradient(ellipse 60% 40% at 80% 100%, rgba(167, 139, 250, 0.06) 0%, transparent 50%),
                radial-gradient(circle at 50% 50%, rgba(45, 212, 191, 0.03) 0%, transparent 70%);
            pointer-events: none;
            z-index: 0;
        }

        /* Noise texture overlay */
        body::after {
            content: '';
            position: fixed;
            inset: 0;
            background-image: url("data:image/svg+xml,%3Csvg viewBox='0 0 256 256' xmlns='http://www.w3.org/2000/svg'%3E%3Cfilter id='noise'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.9' numOctaves='4' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23noise)'/%3E%3C/svg%3E");
            opacity: 0.015;
            pointer-events: none;
            z-index: 1;
        }

        .container {
            max-width: 1680px;
            margin: 0 auto;
            padding: 3rem 2.5rem;
            position: relative;
            z-index: 2;
        }

        /* Hero header */
        .hero {
            margin-bottom: 3rem;
            padding-bottom: 2rem;
            border-bottom: 1px solid var(--border-subtle);
            animation: fadeInDown 0.6s ease-out;
        }

        h1 {
            font-family: 'Outfit', sans-serif;
            font-size: 3rem;
            font-weight: 800;
            letter-spacing: -0.02em;
            margin-bottom: 0.75rem;
            background: linear-gradient(135deg, var(--accent-cyan) 0%, var(--accent-teal) 50%, var(--accent-violet) 100%);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            background-clip: text;
            text-shadow: var(--glow-cyan);
        }

        h2 {
            font-family: 'Outfit', sans-serif;
            font-size: 1.5rem;
            font-weight: 600;
            letter-spacing: -0.01em;
            margin: 3rem 0 1.5rem;
            color: var(--text-primary);
            display: flex;
            align-items: center;
            gap: 0.75rem;
        }

        h2::before {
            content: '';
            width: 4px;
            height: 1.5rem;
            background: linear-gradient(180deg, var(--accent-cyan), var(--accent-violet));
            border-radius: 2px;
        }

        .subtitle {
            font-family: 'JetBrains Mono', monospace;
            color: var(--text-secondary);
            margin-bottom: 0;
            font-size: 0.875rem;
            font-weight: 400;
            letter-spacing: 0.02em;
        }

        /* Grid layouts */
        .grid {
            display: grid;
            grid-template-columns: repeat(5, 1fr);
            gap: 1.25rem;
            margin-bottom: 2.5rem;
        }
        .grid-2 { display: grid; grid-template-columns: repeat(2, 1fr); gap: 1.5rem; margin-bottom: 2.5rem; }
        .grid-3 { display: grid; grid-template-columns: repeat(3, 1fr); gap: 1.5rem; margin-bottom: 2.5rem; }
        @media (max-width: 1400px) { .grid { grid-template-columns: repeat(3, 1fr); } }
        @media (max-width: 1200px) { .grid-2, .grid-3 { grid-template-columns: 1fr; } }
        @media (max-width: 900px) { .grid { grid-template-columns: repeat(2, 1fr); } }

        /* Glassmorphism cards */
        .card {
            background: var(--bg-glass);
            backdrop-filter: blur(12px);
            -webkit-backdrop-filter: blur(12px);
            border-radius: 16px;
            padding: 1.75rem;
            border: 1px solid var(--border-subtle);
            position: relative;
            overflow: hidden;
            transition: all 0.3s cubic-bezier(0.4, 0, 0.2, 1);
            animation: fadeInUp 0.5s ease-out backwards;
        }

        .card::before {
            content: '';
            position: absolute;
            top: 0;
            left: 0;
            right: 0;
            height: 1px;
            background: linear-gradient(90deg, transparent, var(--border-glow), transparent);
            opacity: 0;
            transition: opacity 0.3s;
        }

        .card:hover {
            transform: translateY(-4px);
            border-color: var(--border-glow);
            box-shadow: var(--glow-cyan);
        }

        .card:hover::before { opacity: 1; }

        .card:nth-child(1) { animation-delay: 0.1s; }
        .card:nth-child(2) { animation-delay: 0.15s; }
        .card:nth-child(3) { animation-delay: 0.2s; }
        .card:nth-child(4) { animation-delay: 0.25s; }
        .card:nth-child(5) { animation-delay: 0.3s; }

        .card-title {
            font-family: 'JetBrains Mono', monospace;
            font-size: 0.7rem;
            color: var(--text-muted);
            text-transform: uppercase;
            letter-spacing: 0.15em;
            margin-bottom: 0.75rem;
            font-weight: 500;
        }

        .card-value {
            font-family: 'Outfit', sans-serif;
            font-size: 2.75rem;
            font-weight: 700;
            color: var(--text-primary);
            line-height: 1;
            letter-spacing: -0.02em;
        }

        .card-small {
            font-family: 'JetBrains Mono', monospace;
            font-size: 0.75rem;
            color: var(--text-muted);
            margin-top: 0.5rem;
        }

        .card-accent { border-left: 3px solid var(--accent-cyan); }
        .card-accent-green { border-left: 3px solid var(--accent-teal); }
        .card-accent-purple { border-left: 3px solid var(--accent-violet); }
        .card-accent-pink { border-left: 3px solid var(--accent-rose); }
        .card-accent-amber { border-left: 3px solid var(--accent-amber); }

        /* Glow indicator on card values */
        .card-accent .card-value { color: var(--accent-cyan); text-shadow: 0 0 30px rgba(34, 211, 238, 0.3); }
        .card-accent-green .card-value { color: var(--accent-teal); text-shadow: 0 0 30px rgba(45, 212, 191, 0.3); }
        .card-accent-purple .card-value { color: var(--accent-violet); text-shadow: 0 0 30px rgba(167, 139, 250, 0.3); }
        .card-accent-pink .card-value { color: var(--accent-rose); text-shadow: 0 0 30px rgba(251, 113, 133, 0.3); }

        /* Chart containers */
        .chart-container {
            background: var(--bg-glass);
            backdrop-filter: blur(12px);
            -webkit-backdrop-filter: blur(12px);
            border-radius: 20px;
            padding: 2rem;
            border: 1px solid var(--border-subtle);
            margin-bottom: 2rem;
            animation: fadeInUp 0.6s ease-out backwards;
        }

        .chart-title {
            font-family: 'Outfit', sans-serif;
            font-size: 1.125rem;
            font-weight: 600;
            margin-bottom: 1.5rem;
            color: var(--text-primary);
            display: flex;
            align-items: center;
            gap: 0.75rem;
            letter-spacing: -0.01em;
        }

        .chart-title .icon {
            font-size: 1.25rem;
            width: 2.5rem;
            height: 2.5rem;
            display: flex;
            align-items: center;
            justify-content: center;
            background: var(--bg-elevated);
            border-radius: 10px;
            border: 1px solid var(--border-subtle);
        }

        /* Phase Timeline */
        .phase-timeline { display: flex; flex-direction: column; gap: 1.25rem; }

        .phase-item {
            background: linear-gradient(145deg, var(--bg-elevated) 0%, var(--bg-deep) 100%);
            border-radius: 16px;
            padding: 1.5rem;
            border: 1px solid var(--border-subtle);
            position: relative;
            overflow: hidden;
            transition: all 0.3s cubic-bezier(0.4, 0, 0.2, 1);
            animation: fadeInUp 0.5s ease-out backwards;
        }

        .phase-item:hover {
            border-color: var(--border-glow);
            box-shadow: var(--glow-cyan);
            transform: translateX(4px);
        }

        .phase-item::before {
            content: '';
            position: absolute;
            left: 0;
            top: 0;
            bottom: 0;
            width: 3px;
            background: linear-gradient(180deg, var(--accent-cyan), var(--accent-violet));
        }

        .phase-item::after {
            content: '';
            position: absolute;
            top: 0;
            right: 0;
            width: 200px;
            height: 200px;
            background: radial-gradient(circle, var(--accent-cyan) 0%, transparent 70%);
            opacity: 0.02;
            pointer-events: none;
        }

        .phase-header { display: flex; justify-content: space-between; align-items: flex-start; margin-bottom: 1rem; }

        .phase-number {
            font-family: 'JetBrains Mono', monospace;
            background: linear-gradient(135deg, var(--accent-cyan), var(--accent-teal));
            color: var(--bg-deep);
            font-weight: 700;
            padding: 0.35rem 0.9rem;
            border-radius: 8px;
            font-size: 0.75rem;
            letter-spacing: 0.05em;
            box-shadow: 0 0 20px rgba(34, 211, 238, 0.2);
        }

        .phase-task {
            font-family: 'Outfit', sans-serif;
            font-size: 1.1rem;
            font-weight: 500;
            color: var(--text-primary);
            flex: 1;
            margin-left: 1rem;
            line-height: 1.4;
        }

        .phase-metrics { display: flex; gap: 2rem; flex-wrap: wrap; margin-top: 0.5rem; }

        .phase-metric { display: flex; flex-direction: column; min-width: 100px; }

        .phase-metric-label {
            font-family: 'JetBrains Mono', monospace;
            font-size: 0.65rem;
            color: var(--text-muted);
            text-transform: uppercase;
            letter-spacing: 0.1em;
            margin-bottom: 0.25rem;
        }

        .phase-metric-value {
            font-family: 'Outfit', sans-serif;
            font-size: 1.5rem;
            font-weight: 600;
            color: var(--text-primary);
        }

        .phase-metric-value.highlight {
            color: var(--accent-cyan);
            text-shadow: 0 0 20px rgba(34, 211, 238, 0.3);
        }

        .phase-tools { display: flex; flex-wrap: wrap; gap: 0.5rem; margin-top: 1rem; }

        .phase-findings {
            margin-top: 1.25rem;
            padding-top: 1.25rem;
            border-top: 1px solid var(--border-subtle);
        }

        .phase-finding {
            font-family: 'Outfit', sans-serif;
            font-size: 0.875rem;
            color: var(--text-secondary);
            margin-bottom: 0.75rem;
            padding: 0.75rem 1rem;
            background: rgba(0, 0, 0, 0.2);
            border-radius: 8px;
            border-left: 2px solid var(--accent-violet);
            line-height: 1.6;
        }

        /* Progress bars */
        .progress-bar {
            height: 6px;
            background: rgba(255, 255, 255, 0.05);
            border-radius: 3px;
            overflow: hidden;
            margin-top: 0.5rem;
        }

        .progress-fill {
            height: 100%;
            border-radius: 3px;
            transition: width 0.8s cubic-bezier(0.4, 0, 0.2, 1);
            position: relative;
        }

        .progress-fill::after {
            content: '';
            position: absolute;
            inset: 0;
            background: linear-gradient(90deg, transparent, rgba(255,255,255,0.2), transparent);
            animation: shimmer 2s infinite;
        }

        .progress-fill.blue { background: linear-gradient(90deg, var(--accent-cyan), var(--accent-teal)); box-shadow: 0 0 10px rgba(34, 211, 238, 0.3); }
        .progress-fill.green { background: linear-gradient(90deg, var(--accent-teal), #10b981); box-shadow: 0 0 10px rgba(45, 212, 191, 0.3); }
        .progress-fill.purple { background: linear-gradient(90deg, var(--accent-violet), #c084fc); box-shadow: 0 0 10px rgba(167, 139, 250, 0.3); }

        /* Tool badges */
        .tool-list { display: flex; flex-wrap: wrap; gap: 0.5rem; margin-top: 1rem; }

        .tool-badge {
            font-family: 'JetBrains Mono', monospace;
            background: var(--bg-deep);
            padding: 0.4rem 0.8rem;
            border-radius: 8px;
            font-size: 0.75rem;
            display: flex;
            align-items: center;
            gap: 0.5rem;
            transition: all 0.2s;
        }

        .tool-badge:hover { transform: translateY(-2px); }

        .tool-badge.builtin {
            border: 1px solid rgba(34, 211, 238, 0.3);
            color: var(--accent-cyan);
            box-shadow: 0 0 10px rgba(34, 211, 238, 0.1);
        }

        .tool-badge.custom_agent {
            border: 1px solid rgba(45, 212, 191, 0.3);
            color: var(--accent-teal);
            box-shadow: 0 0 10px rgba(45, 212, 191, 0.1);
        }

        .tool-badge.other {
            border: 1px solid rgba(167, 139, 250, 0.3);
            color: var(--accent-violet);
            box-shadow: 0 0 10px rgba(167, 139, 250, 0.1);
        }

        .tool-count {
            background: rgba(255,255,255,0.1);
            padding: 0.15rem 0.5rem;
            border-radius: 6px;
            font-size: 0.65rem;
            font-weight: 600;
        }

        /* Messages */
        .messages-container {
            background: var(--bg-glass);
            backdrop-filter: blur(12px);
            border-radius: 16px;
            padding: 1.5rem;
            border: 1px solid var(--border-subtle);
            max-height: 700px;
            overflow-y: auto;
        }

        .message {
            padding: 1.25rem;
            margin-bottom: 1rem;
            border-radius: 12px;
            animation: fadeInUp 0.3s ease-out;
        }

        .message.user {
            background: linear-gradient(145deg, rgba(34, 211, 238, 0.08) 0%, transparent 100%);
            border-left: 3px solid var(--accent-cyan);
        }

        .message.bot {
            background: linear-gradient(145deg, rgba(167, 139, 250, 0.08) 0%, transparent 100%);
            border-left: 3px solid var(--accent-violet);
        }

        .message-header {
            display: flex;
            justify-content: space-between;
            margin-bottom: 0.75rem;
            font-size: 0.75rem;
        }

        .message-role {
            font-family: 'JetBrains Mono', monospace;
            font-weight: 600;
            text-transform: uppercase;
            letter-spacing: 0.1em;
        }

        .message-role.user { color: var(--accent-cyan); }
        .message-role.bot { color: var(--accent-violet); }

        .message-time {
            font-family: 'JetBrains Mono', monospace;
            color: var(--text-muted);
        }

        .message-text {
            font-family: 'Outfit', sans-serif;
            color: var(--text-secondary);
            white-space: pre-wrap;
            word-break: break-word;
            font-size: 0.9rem;
            line-height: 1.7;
        }

        /* Rankings table */
        .rankings-table {
            width: 100%;
            border-collapse: collapse;
            font-family: 'Outfit', sans-serif;
        }

        .rankings-table th {
            font-family: 'JetBrains Mono', monospace;
            text-align: left;
            padding: 1rem 0.75rem;
            color: var(--text-muted);
            font-weight: 500;
            font-size: 0.7rem;
            text-transform: uppercase;
            letter-spacing: 0.1em;
            border-bottom: 1px solid var(--border-subtle);
        }

        .rankings-table td {
            padding: 1rem 0.75rem;
            border-bottom: 1px solid rgba(255,255,255,0.03);
            color: var(--text-secondary);
        }

        .rankings-table tr { transition: all 0.2s; }
        .rankings-table tr:hover { background: rgba(34, 211, 238, 0.05); }

        .rank-badge {
            font-family: 'JetBrains Mono', monospace;
            background: linear-gradient(135deg, var(--accent-cyan), var(--accent-violet));
            color: var(--bg-deep);
            padding: 0.25rem 0.6rem;
            border-radius: 6px;
            font-size: 0.7rem;
            font-weight: 700;
        }

        /* Tabs */
        .tabs {
            display: flex;
            gap: 0.25rem;
            margin-bottom: 1.5rem;
            padding: 0.25rem;
            background: var(--bg-deep);
            border-radius: 12px;
            border: 1px solid var(--border-subtle);
        }

        .tab {
            font-family: 'Outfit', sans-serif;
            padding: 0.75rem 1.5rem;
            border-radius: 10px;
            cursor: pointer;
            color: var(--text-muted);
            font-weight: 500;
            font-size: 0.9rem;
            transition: all 0.3s cubic-bezier(0.4, 0, 0.2, 1);
            border: none;
            background: transparent;
        }

        .tab:hover {
            color: var(--text-primary);
            background: rgba(255,255,255,0.03);
        }

        .tab.active {
            background: linear-gradient(135deg, var(--accent-cyan), var(--accent-teal));
            color: var(--bg-deep);
            font-weight: 600;
            box-shadow: 0 0 20px rgba(34, 211, 238, 0.2);
        }

        .tab-content { display: none; animation: fadeInUp 0.4s ease-out; }
        .tab-content.active { display: block; }

        /* Scrollbar styling */
        ::-webkit-scrollbar { width: 6px; height: 6px; }
        ::-webkit-scrollbar-track { background: transparent; }
        ::-webkit-scrollbar-thumb { background: var(--border-glow); border-radius: 3px; }
        ::-webkit-scrollbar-thumb:hover { background: var(--accent-cyan); }

        /* Search Table */
        .search-controls {
            display: flex;
            gap: 1rem;
            margin-bottom: 1.5rem;
            flex-wrap: wrap;
            align-items: center;
        }

        .search-input {
            font-family: 'Outfit', sans-serif;
            flex: 1;
            min-width: 250px;
            padding: 0.875rem 1.25rem;
            border-radius: 12px;
            border: 1px solid var(--border-subtle);
            background: var(--bg-deep);
            color: var(--text-primary);
            font-size: 0.9rem;
            transition: all 0.3s;
        }

        .search-input::placeholder { color: var(--text-muted); }

        .search-input:focus {
            outline: none;
            border-color: var(--accent-cyan);
            box-shadow: 0 0 0 3px rgba(34, 211, 238, 0.1), var(--glow-cyan);
        }

        .filter-select {
            font-family: 'Outfit', sans-serif;
            padding: 0.875rem 1.25rem;
            border-radius: 12px;
            border: 1px solid var(--border-subtle);
            background: var(--bg-deep);
            color: var(--text-primary);
            font-size: 0.9rem;
            cursor: pointer;
            transition: all 0.3s;
        }

        .filter-select:focus {
            outline: none;
            border-color: var(--accent-cyan);
            box-shadow: 0 0 0 3px rgba(34, 211, 238, 0.1);
        }

        .search-table {
            width: 100%;
            border-collapse: collapse;
            font-size: 0.875rem;
        }

        .search-table th {
            font-family: 'JetBrains Mono', monospace;
            text-align: left;
            padding: 1rem;
            background: var(--bg-deep);
            color: var(--text-muted);
            font-weight: 600;
            font-size: 0.7rem;
            text-transform: uppercase;
            letter-spacing: 0.1em;
            border-bottom: 1px solid var(--border-subtle);
            cursor: pointer;
            user-select: none;
            white-space: nowrap;
            transition: all 0.2s;
        }

        .search-table th:hover { color: var(--text-primary); }
        .search-table th.sorted-asc::after { content: ' ↑'; color: var(--accent-cyan); }
        .search-table th.sorted-desc::after { content: ' ↓'; color: var(--accent-cyan); }

        .search-table td {
            padding: 1rem;
            border-bottom: 1px solid rgba(255,255,255,0.03);
            vertical-align: top;
        }

        .search-table tr { transition: all 0.2s; }
        .search-table tr:hover { background: rgba(34, 211, 238, 0.03); }

        .search-table .query-cell { max-width: 450px; line-height: 1.5; }

        .search-table .phase-badge {
            font-family: 'JetBrains Mono', monospace;
            display: inline-block;
            padding: 0.3rem 0.6rem;
            border-radius: 6px;
            font-size: 0.7rem;
            font-weight: 600;
        }

        .search-table .results-preview {
            font-size: 0.8rem;
            color: var(--text-muted);
            margin-top: 0.75rem;
        }

        .search-table .result-link {
            color: var(--accent-cyan);
            text-decoration: none;
            display: block;
            margin-bottom: 0.35rem;
            transition: color 0.2s;
        }

        .search-table .result-link:hover { color: var(--accent-teal); text-decoration: underline; }

        .expand-btn {
            font-family: 'JetBrains Mono', monospace;
            background: rgba(34, 211, 238, 0.1);
            border: 1px solid rgba(34, 211, 238, 0.2);
            color: var(--accent-cyan);
            cursor: pointer;
            font-size: 0.75rem;
            padding: 0.35rem 0.7rem;
            border-radius: 6px;
            transition: all 0.2s;
        }

        .expand-btn:hover {
            background: rgba(34, 211, 238, 0.2);
            box-shadow: 0 0 10px rgba(34, 211, 238, 0.2);
        }

        .table-info {
            font-family: 'JetBrains Mono', monospace;
            color: var(--text-muted);
            font-size: 0.8rem;
            margin-bottom: 1rem;
        }

        .no-results {
            text-align: center;
            padding: 3rem;
            color: var(--text-muted);
            font-size: 1rem;
        }

        /* Animations */
        @keyframes fadeInUp {
            from { opacity: 0; transform: translateY(20px); }
            to { opacity: 1; transform: translateY(0); }
        }

        @keyframes fadeInDown {
            from { opacity: 0; transform: translateY(-20px); }
            to { opacity: 1; transform: translateY(0); }
        }

        @keyframes shimmer {
            0% { transform: translateX(-100%); }
            100% { transform: translateX(100%); }
        }

        @keyframes pulse {
            0%, 100% { opacity: 1; }
            50% { opacity: 0.5; }
        }

        /* Footer */
        .footer {
            text-align: center;
            margin-top: 4rem;
            padding-top: 2rem;
            border-top: 1px solid var(--border-subtle);
        }

        .footer p {
            font-family: 'JetBrains Mono', monospace;
            color: var(--text-muted);
            font-size: 0.75rem;
            letter-spacing: 0.05em;
        }

        .footer .time-range {
            color: var(--text-secondary);
            margin-bottom: 0.5rem;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="hero">
            <h1>Intelligence Command Center</h1>
HTMLHEAD

    echo "            <p class=\"subtitle\">◆ Generated: $(date) ◆ Bot: $BOT_ID ◆ Agent Activity Analytics</p>" >> "${REPORT_DIR}/dashboard.html"
    echo "        </div>" >> "${REPORT_DIR}/dashboard.html"

    cat >> "${REPORT_DIR}/dashboard.html" << HTMLSTATS

        <!-- Summary Cards -->
        <div class="grid">
            <div class="card card-accent">
                <div class="card-title">Total Activities</div>
                <div class="card-value">$TOTAL_ACTIVITIES</div>
            </div>
            <div class="card card-accent-green">
                <div class="card-title">Research Phases</div>
                <div class="card-value">$TOTAL_PHASES</div>
            </div>
            <div class="card card-accent-purple">
                <div class="card-title">Web Searches</div>
                <div class="card-value">$TOTAL_SEARCHES</div>
            </div>
            <div class="card card-accent-pink">
                <div class="card-title">Duration</div>
                <div class="card-value" style="font-size: 1.5rem;">${TOTAL_DURATION}s</div>
            </div>
            <div class="card">
                <div class="card-title">Messages</div>
                <div class="card-value">$TOTAL_MESSAGES</div>
                <div class="card-small">User: $USER_MESSAGES | Bot: $BOT_MESSAGES</div>
            </div>
        </div>

        <!-- Phase Analytics Section -->
        <h2>📊 Research Phase Analytics</h2>

        <div class="grid-2">
            <div class="chart-container">
                <div class="chart-title"><span class="icon">🔍</span> Searches by Phase</div>
                <canvas id="searchByPhaseChart" height="200"></canvas>
            </div>
            <div class="chart-container">
                <div class="chart-title"><span class="icon">⏱️</span> Duration by Phase (seconds)</div>
                <canvas id="durationByPhaseChart" height="200"></canvas>
            </div>
        </div>

        <!-- Phase Timeline -->
        <div class="chart-container">
            <div class="chart-title"><span class="icon">🔬</span> Research Agent Timeline</div>
            <div class="phase-timeline" id="phaseTimeline"></div>
        </div>

        <!-- Rankings -->
        <div class="grid-3">
            <div class="chart-container">
                <div class="chart-title"><span class="icon">🏆</span> Top by Searches</div>
                <table class="rankings-table" id="rankingsBySearches"></table>
            </div>
            <div class="chart-container">
                <div class="chart-title"><span class="icon">⏰</span> Top by Duration</div>
                <table class="rankings-table" id="rankingsByDuration"></table>
            </div>
            <div class="chart-container">
                <div class="chart-title"><span class="icon">📝</span> Top by Observations</div>
                <table class="rankings-table" id="rankingsByObservations"></table>
            </div>
        </div>

        <!-- Tool Usage Section -->
        <h2>🛠️ Tool Usage Analytics</h2>

        <div class="grid-2">
            <div class="chart-container">
                <div class="chart-title"><span class="icon">📊</span> Overall Tool Usage</div>
                <canvas id="toolChart" height="200"></canvas>
            </div>
            <div class="chart-container">
                <div class="chart-title"><span class="icon">🏷️</span> All Tools</div>
                <div class="tool-list" id="toolList"></div>
            </div>
        </div>

        <!-- Data Explorer Section -->
        <h2>🔍 Data Explorer</h2>

        <div class="tabs">
            <div class="tab active" onclick="switchTab('searches')">All Searches</div>
            <div class="tab" onclick="switchTab('messages')">Messages</div>
            <div class="tab" onclick="switchTab('findings')">Phase Findings</div>
        </div>

        <div id="searches-tab" class="tab-content active">
            <div class="chart-container">
                <div class="search-controls">
                    <input type="text" class="search-input" id="searchFilter" placeholder="Filter by query text...">
                    <select class="filter-select" id="phaseFilter">
                        <option value="">All Phases</option>
                    </select>
                    <select class="filter-select" id="sortBy">
                        <option value="timestamp-desc">Newest First</option>
                        <option value="timestamp-asc">Oldest First</option>
                        <option value="phase-asc">Phase (0→11)</option>
                        <option value="phase-desc">Phase (11→0)</option>
                        <option value="results-desc">Most Results</option>
                    </select>
                </div>
                <div class="table-info" id="tableInfo">Loading...</div>
                <div style="overflow-x: auto;">
                    <table class="search-table" id="searchTable">
                        <thead>
                            <tr>
                                <th data-sort="phase" style="width: 100px;">Phase</th>
                                <th data-sort="timestamp" style="width: 150px;">Time</th>
                                <th data-sort="query">Search Query</th>
                                <th data-sort="results" style="width: 80px;">Results</th>
                            </tr>
                        </thead>
                        <tbody id="searchTableBody"></tbody>
                    </table>
                </div>
            </div>
        </div>

        <div id="messages-tab" class="tab-content">
            <div class="messages-container" id="messages"></div>
        </div>

        <div id="findings-tab" class="tab-content">
            <div class="chart-container" id="findingsContainer"></div>
        </div>

        <div style="text-align: center; margin-top: 2rem; color: #64748b; font-size: 0.875rem;">
            <p>Time Range: $TIME_START → $TIME_END</p>
        </div>
    </div>

    <script>
        const toolUsage = $TOOL_USAGE;
        const messages = $MESSAGES;
        const phaseSummary = $PHASE_SUMMARY;
        const phaseFindings = $PHASE_FINDINGS;
        const searchData = $SEARCH_DATA;

        // Color palette
        const colors = [
            '#3b82f6', '#10b981', '#8b5cf6', '#ec4899', '#f59e0b',
            '#06b6d4', '#84cc16', '#f43f5e', '#6366f1', '#14b8a6',
            '#a855f7', '#eab308'
        ];

        // Tab switching
        function switchTab(tab) {
            document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
            document.querySelectorAll('.tab-content').forEach(c => c.classList.remove('active'));
            event.target.classList.add('active');
            document.getElementById(tab + '-tab').classList.add('active');
        }

        // Searches by Phase Chart
        if (phaseSummary.phases && phaseSummary.phases.length > 0) {
            const searchCtx = document.getElementById('searchByPhaseChart').getContext('2d');
            new Chart(searchCtx, {
                type: 'bar',
                data: {
                    labels: phaseSummary.phases.map(p => 'Phase ' + p.phase),
                    datasets: [{
                        label: 'Searches',
                        data: phaseSummary.phases.map(p => p.search_count),
                        backgroundColor: phaseSummary.phases.map((_, i) => colors[i % colors.length] + '80'),
                        borderColor: phaseSummary.phases.map((_, i) => colors[i % colors.length]),
                        borderWidth: 2,
                        borderRadius: 6
                    }]
                },
                options: {
                    responsive: true,
                    plugins: {
                        legend: { display: false },
                        tooltip: {
                            callbacks: {
                                title: (items) => phaseSummary.phases[items[0].dataIndex].task
                            }
                        }
                    },
                    scales: {
                        y: { beginAtZero: true, grid: { color: '#334155' }, ticks: { color: '#94a3b8' } },
                        x: { grid: { display: false }, ticks: { color: '#94a3b8' } }
                    }
                }
            });

            // Duration by Phase Chart
            const durationCtx = document.getElementById('durationByPhaseChart').getContext('2d');
            new Chart(durationCtx, {
                type: 'bar',
                data: {
                    labels: phaseSummary.phases.map(p => 'Phase ' + p.phase),
                    datasets: [{
                        label: 'Duration (s)',
                        data: phaseSummary.phases.map(p => p.duration_seconds),
                        backgroundColor: phaseSummary.phases.map((_, i) => colors[(i + 3) % colors.length] + '80'),
                        borderColor: phaseSummary.phases.map((_, i) => colors[(i + 3) % colors.length]),
                        borderWidth: 2,
                        borderRadius: 6
                    }]
                },
                options: {
                    responsive: true,
                    plugins: {
                        legend: { display: false },
                        tooltip: {
                            callbacks: {
                                title: (items) => phaseSummary.phases[items[0].dataIndex].task
                            }
                        }
                    },
                    scales: {
                        y: { beginAtZero: true, grid: { color: '#334155' }, ticks: { color: '#94a3b8' } },
                        x: { grid: { display: false }, ticks: { color: '#94a3b8' } }
                    }
                }
            });

            // Phase Timeline
            const timeline = document.getElementById('phaseTimeline');
            const maxSearches = Math.max(...phaseSummary.phases.map(p => p.search_count), 1);
            const maxDuration = Math.max(...phaseSummary.phases.map(p => p.duration_seconds), 1);

            phaseSummary.phases.forEach((phase, i) => {
                const findings = phaseFindings.find(f => f.phase === phase.phase);
                const findingsHtml = findings && findings.findings.length > 0
                    ? '<div class="phase-findings">' + findings.findings.slice(0, 3).map((f, idx) =>
                        '<div class="phase-finding" style="margin-bottom: 0.75rem; padding: 0.5rem; background: rgba(0,0,0,0.2); border-radius: 4px;">' +
                        f.substring(0, 800) + (f.length > 800 ? '...' : '') + '</div>'
                      ).join('') +
                      (findings.findings.length > 3 ? '<div style="color: #64748b; font-size: 0.8rem; margin-top: 0.5rem;">+ ' + (findings.findings.length - 3) + ' more findings (see Findings tab)</div>' : '') +
                      '</div>'
                    : '';

                const toolsHtml = phase.tool_usage && phase.tool_usage.length > 0
                    ? '<div class="phase-tools">' + phase.tool_usage.slice(0, 5).map(t =>
                        '<span class="tool-badge ' + (t.tool.startsWith('P:') ? 'builtin' : 'other') + '">' +
                        t.tool.replace('P:', '').split('.').pop() +
                        '<span class="tool-count">' + t.count + '</span></span>'
                      ).join('') + '</div>'
                    : '';

                timeline.innerHTML += \`
                    <div class="phase-item" style="border-left-color: \${colors[i % colors.length]}">
                        <div class="phase-header">
                            <span class="phase-number" style="background: \${colors[i % colors.length]}">Phase \${phase.phase}</span>
                            <span class="phase-task">\${phase.task}</span>
                        </div>
                        <div class="phase-metrics">
                            <div class="phase-metric">
                                <span class="phase-metric-label">Searches</span>
                                <span class="phase-metric-value highlight">\${phase.search_count}</span>
                                <div class="progress-bar" style="width: 80px;">
                                    <div class="progress-fill blue" style="width: \${(phase.search_count / maxSearches) * 100}%"></div>
                                </div>
                            </div>
                            <div class="phase-metric">
                                <span class="phase-metric-label">Duration</span>
                                <span class="phase-metric-value">\${phase.duration_seconds}s</span>
                                <div class="progress-bar" style="width: 80px;">
                                    <div class="progress-fill purple" style="width: \${(phase.duration_seconds / maxDuration) * 100}%"></div>
                                </div>
                            </div>
                            <div class="phase-metric">
                                <span class="phase-metric-label">Observations</span>
                                <span class="phase-metric-value">\${phase.observations}</span>
                            </div>
                            <div class="phase-metric">
                                <span class="phase-metric-label">Activities</span>
                                <span class="phase-metric-value">\${phase.total_activities}</span>
                            </div>
                        </div>
                        \${toolsHtml}
                        \${findingsHtml}
                    </div>
                \`;
            });

            // Rankings tables
            function renderRankings(elementId, data, valueKey, valueLabel) {
                const table = document.getElementById(elementId);
                table.innerHTML = '<tr><th>#</th><th>Phase</th><th>' + valueLabel + '</th></tr>';
                data.slice(0, 5).forEach((item, i) => {
                    table.innerHTML += \`
                        <tr>
                            <td><span class="rank-badge">\${i + 1}</span></td>
                            <td>\${item.task.substring(0, 30)}</td>
                            <td>\${item[valueKey]}</td>
                        </tr>
                    \`;
                });
            }

            if (phaseSummary.rankings) {
                renderRankings('rankingsBySearches', phaseSummary.rankings.by_searches, 'searches', 'Searches');
                renderRankings('rankingsByDuration', phaseSummary.rankings.by_duration, 'duration', 'Duration (s)');
                renderRankings('rankingsByObservations', phaseSummary.rankings.by_observations, 'observations', 'Observations');
            }
        }

        // Tool usage chart
        const toolCtx = document.getElementById('toolChart').getContext('2d');
        new Chart(toolCtx, {
            type: 'doughnut',
            data: {
                labels: toolUsage.slice(0, 8).map(t => t.tool.replace('P:', '').split('.').pop()),
                datasets: [{
                    data: toolUsage.slice(0, 8).map(t => t.count),
                    backgroundColor: colors.slice(0, 8).map(c => c + '80'),
                    borderColor: colors.slice(0, 8),
                    borderWidth: 2
                }]
            },
            options: {
                responsive: true,
                plugins: {
                    legend: { position: 'right', labels: { color: '#94a3b8', padding: 15 } }
                }
            }
        });

        // Tool badges
        const toolList = document.getElementById('toolList');
        toolUsage.forEach(t => {
            const badge = document.createElement('span');
            badge.className = 'tool-badge ' + t.category;
            badge.innerHTML = t.tool.replace('P:', '').split('.').pop() + '<span class="tool-count">' + t.count + '</span>';
            toolList.appendChild(badge);
        });

        // Messages
        const messagesDiv = document.getElementById('messages');
        messages.forEach(m => {
            const div = document.createElement('div');
            div.className = 'message ' + m.role;
            div.innerHTML = \`
                <div class="message-header">
                    <span class="message-role \${m.role}">\${m.role}</span>
                    <span class="message-time">\${new Date(m.timestamp).toLocaleString()}</span>
                </div>
                <div class="message-text">\${(m.text || '[No text]').substring(0, 2000)}</div>
            \`;
            messagesDiv.appendChild(div);
        });

        // Findings by phase - full content with expandable sections
        const findingsContainer = document.getElementById('findingsContainer');
        phaseFindings.forEach((phase, i) => {
            if (phase.findings && phase.findings.length > 0) {
                findingsContainer.innerHTML += \`
                    <div style="margin-bottom: 1.5rem; padding: 1rem; background: #0f172a; border-radius: 8px; border-left: 4px solid \${colors[i % colors.length]}">
                        <div style="font-weight: 600; color: \${colors[i % colors.length]}; margin-bottom: 0.75rem; font-size: 1.1rem;">
                            Phase \${phase.phase}: \${phase.task}
                        </div>
                        <div style="color: #64748b; font-size: 0.8rem; margin-bottom: 0.5rem;">\${phase.findings.length} finding(s)</div>
                        \${phase.findings.map((f, idx) => \`
                            <div style="color: #cbd5e1; margin-bottom: 1rem; padding: 0.75rem; background: rgba(0,0,0,0.3); border-radius: 6px; font-size: 0.9rem; line-height: 1.5; white-space: pre-wrap; word-wrap: break-word;">
                                \${f}
                            </div>
                        \`).join('')}
                    </div>
                \`;
            }
        });

        // ========== SEARCH DATA TABLE ==========
        let filteredSearchData = [...searchData];
        let currentSort = { field: 'timestamp', dir: 'desc' };
        const expandedRows = new Set();

        // Populate phase filter dropdown
        const phaseFilter = document.getElementById('phaseFilter');
        const uniquePhases = [...new Set(searchData.map(s => s.phase))].sort((a, b) => a - b);
        uniquePhases.forEach(phase => {
            const opt = document.createElement('option');
            opt.value = phase;
            const phaseInfo = phaseSummary.phases?.find(p => p.phase === phase);
            opt.textContent = 'Phase ' + phase + (phaseInfo ? ': ' + phaseInfo.task.substring(0, 30) + '...' : '');
            phaseFilter.appendChild(opt);
        });

        function formatTime(ts) {
            const d = new Date(ts);
            return d.toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit', second: '2-digit' });
        }

        function renderSearchTable() {
            const tbody = document.getElementById('searchTableBody');
            const tableInfo = document.getElementById('tableInfo');

            if (filteredSearchData.length === 0) {
                tbody.innerHTML = '<tr><td colspan="4" class="no-results">No searches match your filters</td></tr>';
                tableInfo.textContent = '0 searches found';
                return;
            }

            tableInfo.textContent = filteredSearchData.length + ' of ' + searchData.length + ' searches';

            tbody.innerHTML = filteredSearchData.map((search, idx) => {
                const isExpanded = expandedRows.has(search.id);
                const phaseColor = colors[search.phase % colors.length];

                const citationsHtml = search.citations && search.citations.length > 0
                    ? search.citations.slice(0, isExpanded ? 20 : 3).map(c =>
                        '<a href="' + (c.url || '#') + '" target="_blank" class="result-link" title="' + (c.source || '') + '">' +
                        (c.title || c.url || 'Link').substring(0, 60) + (c.title && c.title.length > 60 ? '...' : '') + '</a>'
                    ).join('') +
                    (search.citations.length > 3 && !isExpanded ? '<button class="expand-btn" onclick="toggleExpand(' + search.id + ')">+ ' + (search.citations.length - 3) + ' more</button>' : '')
                    : '<span style="color: #64748b; font-size: 0.8rem;">No citations</span>';

                return \`
                    <tr data-id="\${search.id}">
                        <td>
                            <span class="phase-badge" style="background: \${phaseColor}20; color: \${phaseColor}; border: 1px solid \${phaseColor}40;">
                                Phase \${search.phase}
                            </span>
                            <div style="font-size: 0.75rem; color: #64748b; margin-top: 0.25rem;">\${(search.phase_task || '').substring(0, 25)}...</div>
                        </td>
                        <td style="white-space: nowrap; color: #94a3b8;">\${formatTime(search.timestamp)}</td>
                        <td class="query-cell">
                            <div style="color: #f1f5f9; margin-bottom: 0.5rem;">\${search.query}</div>
                            <div class="results-preview">\${citationsHtml}</div>
                        </td>
                        <td style="text-align: center;">
                            <span style="font-size: 1.25rem; font-weight: 600; color: \${search.citations?.length > 5 ? '#10b981' : search.citations?.length > 0 ? '#f59e0b' : '#64748b'};">
                                \${search.citations?.length || 0}
                            </span>
                        </td>
                    </tr>
                \`;
            }).join('');
        }

        function toggleExpand(id) {
            if (expandedRows.has(id)) {
                expandedRows.delete(id);
            } else {
                expandedRows.add(id);
            }
            renderSearchTable();
        }

        function applyFilters() {
            const textFilter = document.getElementById('searchFilter').value.toLowerCase();
            const phaseValue = document.getElementById('phaseFilter').value;
            const sortValue = document.getElementById('sortBy').value;

            filteredSearchData = searchData.filter(s => {
                const matchesText = !textFilter || s.query.toLowerCase().includes(textFilter);
                const matchesPhase = !phaseValue || s.phase == phaseValue;
                return matchesText && matchesPhase;
            });

            // Apply sorting
            const [field, dir] = sortValue.split('-');
            filteredSearchData.sort((a, b) => {
                let valA, valB;
                switch (field) {
                    case 'timestamp':
                        valA = new Date(a.timestamp).getTime();
                        valB = new Date(b.timestamp).getTime();
                        break;
                    case 'phase':
                        valA = a.phase;
                        valB = b.phase;
                        break;
                    case 'results':
                        valA = a.citations?.length || 0;
                        valB = b.citations?.length || 0;
                        break;
                    default:
                        valA = a[field];
                        valB = b[field];
                }
                return dir === 'asc' ? (valA > valB ? 1 : -1) : (valA < valB ? 1 : -1);
            });

            renderSearchTable();
        }

        // Event listeners for filters
        document.getElementById('searchFilter').addEventListener('input', applyFilters);
        document.getElementById('phaseFilter').addEventListener('change', applyFilters);
        document.getElementById('sortBy').addEventListener('change', applyFilters);

        // Make toggleExpand available globally
        window.toggleExpand = toggleExpand;

        // Initial render
        applyFilters();
    </script>
</body>
</html>
HTMLHEAD_REMOVED
fi

# ═══════════════════════════════════════════════════════════════
# MARKDOWN REPORT
# ═══════════════════════════════════════════════════════════════

if [[ "$FORMATS" == *"md"* ]]; then
    SUMMARY=$(cat "${REPORT_DIR}/summary.json")
    PHASE_SUMMARY=$(cat "${REPORT_DIR}/phase_summary.json" 2>/dev/null || echo '{}')
    PHASE_ANALYTICS=$(cat "${REPORT_DIR}/phase_analytics.json" 2>/dev/null || echo '[]')
    PHASE_FINDINGS=$(cat "${REPORT_DIR}/phase_findings.json" 2>/dev/null || echo '[]')

    cat > "${REPORT_DIR}/REPORT.md" << EOF
# Copilot Studio Agent Activity Report

**Generated:** $(date)
**Bot ID:** $BOT_ID
**Conversation(s):** $CONV_IDS

---

## Executive Summary

| Metric | Value |
|--------|-------|
| Total Activities | $(echo "$SUMMARY" | jq '.activity_summary.total') |
| Messages | $(echo "$SUMMARY" | jq '.activity_summary.messages') |
| User Messages | $(echo "$SUMMARY" | jq '.activity_summary.user_messages') |
| Bot Messages | $(echo "$SUMMARY" | jq '.activity_summary.bot_messages') |
| Events | $(echo "$SUMMARY" | jq '.activity_summary.events') |

**Time Range:** $(echo "$SUMMARY" | jq -r '.time_range.start') → $(echo "$SUMMARY" | jq -r '.time_range.end')

---

## Phase Overview

| # | Research Agent Task | Searches | Duration | Observations |
|---|---------------------|----------|----------|--------------|
EOF

    # Add phase overview table (compute duration display from duration_seconds)
    echo "$PHASE_ANALYTICS" | jq -r '.[] | "| \(.phase) | \(.task // "Unknown") | \(.search_count // 0) | \(if .duration_seconds then "\(.duration_seconds)s" else "N/A" end) | \(.observations // 0) |"' >> "${REPORT_DIR}/REPORT.md"

    cat >> "${REPORT_DIR}/REPORT.md" << EOF

### Aggregate Metrics

| Metric | Value |
|--------|-------|
| Total Phases | $(echo "$PHASE_SUMMARY" | jq '.total_phases // 0') |
| Total Searches | $(echo "$PHASE_SUMMARY" | jq '.totals.total_searches // 0') |
| Total Duration | $(echo "$PHASE_SUMMARY" | jq -r 'if .totals.total_duration_seconds then "\(.totals.total_duration_seconds)s (\(.totals.total_duration_seconds / 60 | floor)m \(.totals.total_duration_seconds % 60)s)" else "N/A" end') |
| Average Searches/Phase | $(echo "$PHASE_SUMMARY" | jq '.totals.avg_searches_per_phase // 0 | . * 10 | floor / 10') |

---

## Phase Rankings

### By Search Volume
EOF

    echo "$PHASE_SUMMARY" | jq -r '.rankings.by_searches // [] | .[:5][] | "1. **Phase \(.phase)** - \(.task // "Unknown"): \(.searches // 0) searches"' >> "${REPORT_DIR}/REPORT.md"

    cat >> "${REPORT_DIR}/REPORT.md" << 'EOF'

### By Duration
EOF

    echo "$PHASE_SUMMARY" | jq -r '.rankings.by_duration // [] | .[:5][] | "1. **Phase \(.phase)** - \(.task // "Unknown"): \(.duration // 0)s"' >> "${REPORT_DIR}/REPORT.md"

    cat >> "${REPORT_DIR}/REPORT.md" << 'EOF'

### By Observations
EOF

    echo "$PHASE_SUMMARY" | jq -r '.rankings.by_observations // [] | .[:5][] | "1. **Phase \(.phase)** - \(.task // "Unknown"): \(.observations // 0) observations"' >> "${REPORT_DIR}/REPORT.md"

    cat >> "${REPORT_DIR}/REPORT.md" << 'EOF'

---

## Detailed Phase Analysis

EOF

    # Add detailed analysis for each phase
    echo "$PHASE_ANALYTICS" | jq -r '.[] | "### Phase \(.phase): \(.task // "Unknown")\n\n| Metric | Value |\n|--------|-------|\n| Searches | \(.search_count // 0) |\n| Duration | \(if .duration_seconds then "\(.duration_seconds)s" else "N/A" end) |\n| Observations | \(.observations // 0) |\n| Start Time | \(.start_time // "N/A") |\n| End Time | \(.end_time // "N/A") |\n\n#### Tools Used\n"' >> "${REPORT_DIR}/REPORT.md"

    # Add tool usage per phase
    echo "$PHASE_ANALYTICS" | jq -r '.[] | . as $phase | "**Phase \(.phase):** " + ((.tool_usage // []) | map("\(.tool | split(".") | last) (\(.count))") | join(", ") | if . == "" then "None" else . end) + "\n"' >> "${REPORT_DIR}/REPORT.md"

    cat >> "${REPORT_DIR}/REPORT.md" << 'EOF'

---

## Key Findings by Phase

EOF

    # Add findings per phase
    echo "$PHASE_FINDINGS" | jq -r '.[] | select(.findings and (.findings | length > 0)) | "### Phase \(.phase): \(.task // "Unknown")\n\n" + (.findings[:5] | map("- " + (. | tostring | .[0:300])) | join("\n")) + "\n"' >> "${REPORT_DIR}/REPORT.md"

    cat >> "${REPORT_DIR}/REPORT.md" << 'EOF'

---

## Overall Tool Usage

| Tool | Count | Type |
|------|-------|------|
EOF

    cat "${REPORT_DIR}/tool_usage.json" | jq -r '.[] | "| \(.tool | split(".") | last) | \(.count) | \(.category) |"' >> "${REPORT_DIR}/REPORT.md"

    cat >> "${REPORT_DIR}/REPORT.md" << 'EOF'

---

## AI Observations Timeline

EOF

    cat "${REPORT_DIR}/ai_observations.json" | jq -r '.[:20][] | "### \(.timestamp)\n**Task:** \(.task // "N/A")\n**Execution Time:** \(.execution_time // "N/A")\n\n\(.observation | tostring | .[0:800])\n\n---\n"' >> "${REPORT_DIR}/REPORT.md"

    cat >> "${REPORT_DIR}/REPORT.md" << 'EOF'

---

## Conversation Timeline (Condensed)

EOF

    # Show condensed timeline - key messages only
    cat "${REPORT_DIR}/messages.json" | jq -r '[.[] | select(.role == "user" or (.text and (.text | test("Phase Router|\\[\\d+/\\d+\\]|completed|error"; "i"))))][:30][] | "**\(.timestamp)** - \(.role | ascii_upcase): \(.text // "[No text]" | .[0:200])\n"' >> "${REPORT_DIR}/REPORT.md"

    cat >> "${REPORT_DIR}/REPORT.md" << 'EOF'

---

*Report generated by Copilot Studio CLI Export Tool*
EOF

    print_status "Generated REPORT.md"
fi

# ═══════════════════════════════════════════════════════════════
# COMPLETION
# ═══════════════════════════════════════════════════════════════

echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                 Export Complete! ✨                        ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "📁 Reports saved to: $REPORT_DIR"
echo ""
echo "📊 Files generated:"
ls -lh "$REPORT_DIR" | grep -v "^total" | awk '{printf "   %-30s %s\n", $NF, $5}'
echo ""
echo "🚀 Quick commands:"
echo "   open ${REPORT_DIR}/dashboard.html    # View HTML dashboard"
echo "   cat ${REPORT_DIR}/summary.json | jq  # View summary"
echo "   open ${REPORT_DIR}/messages.csv      # Open in Excel"
