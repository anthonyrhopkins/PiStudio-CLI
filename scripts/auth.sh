#!/usr/bin/env bash
#
# auth.sh - Pure curl+jq OAuth2 authentication for Copilot Studio CLI
#
# Replaces m365/az CLI dependencies with direct Azure AD device code flow.
# Uses the Azure CLI public client app ID (04b07795-8ddb-461a-bbee-02f9e1bf7b46).
#
# Source this file from bin/pistudio or scripts/export-activities.sh:
#   source "${SCRIPT_DIR}/auth.sh"
#
# Dependencies: curl, jq, base64
#

# Guard against double-sourcing
[[ -n "${_PISTUDIO_AUTH_LOADED:-}" ]] && return 0
_PISTUDIO_AUTH_LOADED=1

# ─── Constants ────────────────────────────────────────────────
PISTUDIO_CLIENT_ID="${PISTUDIO_CLIENT_ID:-04b07795-8ddb-461a-bbee-02f9e1bf7b46}"
PISTUDIO_AUTH_DIR="${PISTUDIO_AUTH_DIR:-${HOME}/.config/pistudio/tokens}"
PISTUDIO_SESSION_DIR="${TMPDIR:-/tmp}/pistudio-session-tokens.$$"
PISTUDIO_LOGIN_AUTHORITY="https://login.microsoftonline.com"

# ─── Session cache setup ─────────────────────────────────────
_pistudio_setup_session_cache() {
    if [[ ! -d "$PISTUDIO_SESSION_DIR" ]]; then
        mkdir -p "$PISTUDIO_SESSION_DIR"
        chmod 0700 "$PISTUDIO_SESSION_DIR"
    fi
}

_pistudio_cleanup_session() {
    rm -rf "$PISTUDIO_SESSION_DIR" 2>/dev/null || true
}

# Install cleanup trap (chain with existing traps)
_pistudio_install_trap() {
    local existing_trap
    existing_trap=$(trap -p EXIT | sed "s/^trap -- '//; s/' EXIT$//" || true)
    if [[ -n "$existing_trap" ]]; then
        # shellcheck disable=SC2064
        trap "${existing_trap}; _pistudio_cleanup_session" EXIT
    else
        trap '_pistudio_cleanup_session' EXIT
    fi
}
_pistudio_install_trap

# ─── PKCE Helpers ─────────────────────────────────────────────

_pistudio_generate_code_verifier() {
    # 64-char base64url random string (RFC 7636 §4.1)
    # Uses openssl rand to avoid SIGPIPE with /dev/urandom | head under pipefail
    local raw
    raw=$(openssl rand -base64 48 2>/dev/null | tr '+/' '-_' | tr -d '=\n')
    printf '%s' "${raw:0:64}"
}

_pistudio_generate_code_challenge() {
    # S256 challenge: SHA256(verifier) → base64url (RFC 7636 §4.2)
    local verifier="$1"
    printf '%s' "$verifier" \
        | openssl dgst -sha256 -binary 2>/dev/null \
        | openssl base64 -A 2>/dev/null \
        | tr '+/' '-_' | tr -d '='
}

# ─── Browser Login Helpers ────────────────────────────────────

_pistudio_detect_listener() {
    # Returns the best available tool for a localhost HTTP listener
    if command -v python3 &>/dev/null; then
        echo "python3"
    elif command -v node &>/dev/null; then
        echo "node"
    elif command -v nc &>/dev/null; then
        echo "nc"
    else
        return 1
    fi
}

_pistudio_find_free_port() {
    local port attempts=0
    while (( attempts < 20 )); do
        port=$(( RANDOM % 16384 + 49152 ))
        # Test if port is free using /dev/tcp (bash builtin)
        if ! (echo >/dev/tcp/127.0.0.1/$port) 2>/dev/null; then
            echo "$port"
            return 0
        fi
        (( attempts++ ))
    done
    return 1
}

_pistudio_success_html() {
    cat <<'HTMLEOF'
HTTP/1.1 200 OK
Content-Type: text/html; charset=utf-8
Connection: close

<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>pistudio - Logged In</title>
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, sans-serif;
         display: flex; justify-content: center; align-items: center;
         min-height: 100vh; margin: 0; background: #f8f9fa; }
  .card { text-align: center; padding: 3rem; background: #fff;
          border-radius: 12px; box-shadow: 0 2px 12px rgba(0,0,0,0.08); }
  .check { font-size: 4rem; margin-bottom: 1rem; }
  h1 { color: #1a7f37; font-size: 1.5rem; margin: 0 0 0.5rem; }
  p  { color: #666; margin: 0; }
</style></head>
<body><div class="card">
  <div class="check">&#x2705;</div>
  <h1>Authentication successful</h1>
  <p>You can close this tab and return to the terminal.</p>
</div></body></html>
HTMLEOF
}

_pistudio_run_listener() {
    local port="$1" tool="$2" output_file="$3" state="$4"

    # All background processes redirect stdout/stderr to /dev/null so that
    # command substitution $(...) returns immediately after echo $!
    case "$tool" in
        python3)
            python3 -c "
import http.server, urllib.parse, sys, os
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        qs = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        code = qs.get('code', [''])[0]
        st = qs.get('state', [''])[0]
        if code and st == '$state':
            with open('$output_file', 'w') as f:
                f.write(code)
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.end_headers()
            self.wfile.write(b'''<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>pistudio</title>
<style>body{font-family:-apple-system,sans-serif;display:flex;justify-content:center;align-items:center;min-height:100vh;margin:0;background:#f8f9fa}
.card{text-align:center;padding:3rem;background:#fff;border-radius:12px;box-shadow:0 2px 12px rgba(0,0,0,.08)}
.check{font-size:4rem;margin-bottom:1rem}h1{color:#1a7f37;font-size:1.5rem;margin:0 0 .5rem}p{color:#666;margin:0}</style></head>
<body><div class=\"card\"><div class=\"check\">&#x2705;</div><h1>Authentication successful</h1><p>You can close this tab and return to the terminal.</p></div></body></html>''')
        else:
            self.send_response(400)
            self.send_header('Content-Type', 'text/plain')
            self.end_headers()
            self.wfile.write(b'Bad request: missing code or state mismatch')
        # Shut down after first request
        import threading
        threading.Thread(target=self.server.shutdown).start()
    def log_message(self, *a): pass
s = http.server.HTTPServer(('127.0.0.1', $port), H)
s.handle_request()
" </dev/null >/dev/null 2>/dev/null &
            ;;
        node)
            node -e "
const http = require('http'), url = require('url'), fs = require('fs');
const s = http.createServer((req, res) => {
  const q = new URL(req.url, 'http://localhost').searchParams;
  const code = q.get('code'), st = q.get('state');
  if (code && st === '$state') {
    fs.writeFileSync('$output_file', code);
    res.writeHead(200, {'Content-Type':'text/html'});
    res.end('<html><body style=\"font-family:sans-serif;text-align:center;padding:4rem\"><h1 style=\"color:#1a7f37\">&#x2705; Authentication successful</h1><p>You can close this tab.</p></body></html>');
  } else {
    res.writeHead(400); res.end('Bad request');
  }
  s.close();
});
s.listen($port, '127.0.0.1');
" </dev/null >/dev/null 2>/dev/null &
            ;;
        nc)
            # nc fallback: single-shot listener, parse code from GET request
            {
                local request
                request=$(nc -l 127.0.0.1 "$port" 2>/dev/null || nc -l "$port" 2>/dev/null)
                local code_param
                code_param=$(printf '%s' "$request" | head -1 | grep -oE 'code=[^& ]+' | head -1 | cut -d= -f2)
                local state_param
                state_param=$(printf '%s' "$request" | head -1 | grep -oE 'state=[^& ]+' | head -1 | cut -d= -f2)
                if [[ -n "$code_param" && "$state_param" == "$state" ]]; then
                    printf '%s' "$code_param" > "$output_file"
                fi
            } </dev/null >/dev/null 2>/dev/null &
            ;;
    esac
    echo $!
}

# ─── Browser Auth Code Flow (PKCE) ───────────────────────────

pistudio_login_browser() {
    local profile="${1:-default}"
    local tenant_id="${2:-common}"
    local login_hint="${3:-}"

    _pistudio_ensure_auth_dir

    # 1. Detect listener tool; fall back to device code if unavailable
    local listener_tool
    listener_tool=$(_pistudio_detect_listener) || {
        echo "warning: no listener tool found (python3/node/nc). Falling back to device code flow." >&2
        pistudio_login "$profile" "$tenant_id"
        return $?
    }

    # 2. Generate PKCE pair
    local code_verifier code_challenge
    code_verifier=$(_pistudio_generate_code_verifier)
    code_challenge=$(_pistudio_generate_code_challenge "$code_verifier")

    # 3. Find a free port
    local port
    port=$(_pistudio_find_free_port) || {
        echo "warning: could not find free port. Falling back to device code flow." >&2
        pistudio_login "$profile" "$tenant_id"
        return $?
    }

    local redirect_uri="http://localhost:${port}"
    local state
    state=$(openssl rand -hex 16 2>/dev/null)

    # 4. Build authorize URL
    local endpoint="${PISTUDIO_LOGIN_AUTHORITY}/${tenant_id}/oauth2/v2.0"
    local scope="https://management.azure.com/.default offline_access"
    local authorize_url="${endpoint}/authorize"
    authorize_url+="?client_id=${PISTUDIO_CLIENT_ID}"
    authorize_url+="&response_type=code"
    authorize_url+="&redirect_uri=$(printf '%s' "$redirect_uri" | jq -sRr @uri)"
    authorize_url+="&scope=$(printf '%s' "$scope" | jq -sRr @uri)"
    authorize_url+="&code_challenge=${code_challenge}"
    authorize_url+="&code_challenge_method=S256"
    authorize_url+="&state=${state}"
    authorize_url+="&prompt=select_account"
    if [[ -n "$login_hint" ]]; then
        authorize_url+="&login_hint=$(printf '%s' "$login_hint" | jq -sRr @uri)"
    fi

    # 5. Start localhost listener
    local code_file="${TMPDIR:-/tmp}/pistudio-auth-code.$$"
    rm -f "$code_file"

    local listener_pid
    listener_pid=$(_pistudio_run_listener "$port" "$listener_tool" "$code_file" "$state")

    # Ensure listener cleanup on exit (SC2064: single quotes so vars expand at signal time)
    # shellcheck disable=SC2064
    trap "kill ${listener_pid} 2>/dev/null; rm -f '${code_file}'" RETURN 2>/dev/null || true

    # 6. Open browser
    echo "Opening browser for authentication..."
    if [[ "$(uname)" == "Darwin" ]]; then
        open "$authorize_url" 2>/dev/null
    elif command -v xdg-open &>/dev/null; then
        xdg-open "$authorize_url" 2>/dev/null
    else
        echo ""
        echo "Open this URL in your browser:"
        echo "  $authorize_url"
        echo ""
    fi

    echo "Waiting for browser login (listening on localhost:${port})..."

    # 7. Wait for auth code (up to 120s)
    local elapsed=0
    while (( elapsed < 120 )); do
        if [[ -s "$code_file" ]]; then
            break
        fi
        sleep 1
        (( elapsed++ ))
    done

    if [[ ! -s "$code_file" ]]; then
        kill "$listener_pid" 2>/dev/null || true
        rm -f "$code_file"
        echo "error: timed out waiting for browser login (120s)" >&2
        echo "hint: try 'pistudio login --device-code' as fallback" >&2
        return 1
    fi

    local auth_code
    auth_code=$(cat "$code_file")
    rm -f "$code_file"

    # 8. Exchange code for tokens
    local token_response
    token_response=$(curl -sS --connect-timeout 10 --max-time 30 \
        -X POST "${endpoint}/token" \
        -d "grant_type=authorization_code" \
        -d "client_id=${PISTUDIO_CLIENT_ID}" \
        -d "code=${auth_code}" \
        -d "code_verifier=${code_verifier}" \
        --data-urlencode "redirect_uri=${redirect_uri}" \
        --data-urlencode "scope=${scope}")

    local error access_token refresh_token
    error=$(printf '%s' "$token_response" | jq -r '.error // empty')
    if [[ -n "$error" ]]; then
        local error_desc
        error_desc=$(printf '%s' "$token_response" | jq -r '.error_description // empty')
        echo "error: token exchange failed: ${error}${error_desc:+ — $error_desc}" >&2
        return 1
    fi

    access_token=$(printf '%s' "$token_response" | jq -r '.access_token // empty')
    refresh_token=$(printf '%s' "$token_response" | jq -r '.refresh_token // empty')

    if [[ -z "$access_token" || -z "$refresh_token" ]]; then
        echo "error: token response missing access_token or refresh_token" >&2
        return 1
    fi

    # 9. Extract user info (identical to device code flow)
    local jwt_payload user_email resolved_tenant
    jwt_payload=$(_pistudio_decode_jwt_payload "$access_token") || true
    user_email=$(printf '%s' "$jwt_payload" | jq -r '.upn // .unique_name // .preferred_username // empty')
    resolved_tenant=$(printf '%s' "$jwt_payload" | jq -r '.tid // empty')

    if [[ "$tenant_id" == "common" && -n "$resolved_tenant" ]]; then
        tenant_id="$resolved_tenant"
    fi

    # 10. Store tokens (same format as device code flow)
    _pistudio_write_token_file "$profile" "$tenant_id" "$refresh_token" "$user_email"

    # Cache the access token in session
    _pistudio_setup_session_cache
    local key
    key=$(printf '%s' "https://management.azure.com" | tr -c '[:alnum:]' '_' | tr '[:upper:]' '[:lower:]')
    printf '%s' "$access_token" > "${PISTUDIO_SESSION_DIR}/${key}.token"

    echo "Logged in as ${user_email:-unknown} (tenant: ${tenant_id})"
    return 0
}

# ─── JWT Decode ───────────────────────────────────────────────

_pistudio_decode_jwt_payload() {
    # Decode the payload (second segment) of a JWT.
    # Pure bash + base64 — no python or node needed.
    local token="$1"
    local payload

    # Extract second segment
    payload=$(printf '%s' "$token" | cut -d. -f2)
    [[ -z "$payload" ]] && return 1

    # Base64url → base64: replace - with +, _ with /
    payload="${payload//-/+}"
    payload="${payload//_//}"

    # Pad to multiple of 4
    local pad=$(( 4 - ${#payload} % 4 ))
    if (( pad < 4 )); then
        local i
        for (( i=0; i<pad; i++ )); do
            payload="${payload}="
        done
    fi

    # Decode
    printf '%s' "$payload" | base64 -d 2>/dev/null || printf '%s' "$payload" | base64 -D 2>/dev/null || return 1
}

# ─── Token File Helpers ───────────────────────────────────────

_pistudio_token_file() {
    local profile="${1:-default}"
    echo "${PISTUDIO_AUTH_DIR}/${profile}.json"
}

_pistudio_ensure_auth_dir() {
    if [[ ! -d "$PISTUDIO_AUTH_DIR" ]]; then
        mkdir -p "$PISTUDIO_AUTH_DIR"
        chmod 0700 "$PISTUDIO_AUTH_DIR"
    fi
}

_pistudio_read_token_field() {
    local profile="$1" field="$2"
    local file
    file=$(_pistudio_token_file "$profile")
    [[ -f "$file" ]] || return 1
    jq -r --arg f "$field" '.[$f] // empty' "$file" 2>/dev/null
}

_pistudio_write_token_file() {
    local profile="$1" tenant_id="$2" refresh_token="$3" user="$4"
    _pistudio_ensure_auth_dir
    local file tmpfile
    file=$(_pistudio_token_file "$profile")
    tmpfile="${file}.tmp.$$"

    jq -n \
        --arg tenant_id "$tenant_id" \
        --arg refresh_token "$refresh_token" \
        --arg user "$user" \
        --arg acquired_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        '{tenant_id: $tenant_id, refresh_token: $refresh_token, user: $user, acquired_at: $acquired_at}' \
        > "$tmpfile"
    chmod 0600 "$tmpfile"
    mv "$tmpfile" "$file"
}

# ─── File Locking (mkdir-based, macOS compatible) ─────────────

_pistudio_lock() {
    local lockdir="${PISTUDIO_AUTH_DIR}/.lock"
    local attempts=0
    while ! mkdir "$lockdir" 2>/dev/null; do
        (( attempts++ ))
        if (( attempts > 50 )); then
            # Stale lock — remove and retry
            rm -rf "$lockdir" 2>/dev/null || true
            mkdir "$lockdir" 2>/dev/null || true
            return 0
        fi
        sleep 0.1
    done
}

_pistudio_unlock() {
    local lockdir="${PISTUDIO_AUTH_DIR}/.lock"
    rmdir "$lockdir" 2>/dev/null || true
}

# ─── Device Code Flow ────────────────────────────────────────

pistudio_login() {
    local profile="${1:-default}"
    local tenant_id="${2:-common}"

    _pistudio_ensure_auth_dir

    local endpoint="${PISTUDIO_LOGIN_AUTHORITY}/${tenant_id}/oauth2/v2.0"

    # Step 1: Request device code
    local device_response
    device_response=$(curl -sS --connect-timeout 10 --max-time 30 \
        -X POST "${endpoint}/devicecode" \
        -d "client_id=${PISTUDIO_CLIENT_ID}" \
        -d "scope=https://management.azure.com/.default offline_access")

    local device_code user_code verification_uri interval message
    device_code=$(printf '%s' "$device_response" | jq -r '.device_code // empty')
    user_code=$(printf '%s' "$device_response" | jq -r '.user_code // empty')
    verification_uri=$(printf '%s' "$device_response" | jq -r '.verification_uri // empty')
    interval=$(printf '%s' "$device_response" | jq -r '.interval // 5')
    message=$(printf '%s' "$device_response" | jq -r '.message // empty')

    if [[ -z "$device_code" || -z "$user_code" ]]; then
        local error_desc
        error_desc=$(printf '%s' "$device_response" | jq -r '.error_description // .error // empty')
        echo "error: failed to initiate device code flow${error_desc:+: $error_desc}" >&2
        return 1
    fi

    # Step 2: Show instructions
    echo ""
    if [[ -n "$message" ]]; then
        echo "$message"
    else
        echo "To sign in, use a web browser to open the page ${verification_uri:-https://microsoft.com/devicelogin} and enter the code ${user_code} to authenticate."
    fi
    echo ""

    # Step 3: Poll for token
    local token_response error
    while true; do
        sleep "$interval"

        token_response=$(curl -sS --connect-timeout 10 --max-time 30 \
            -X POST "${endpoint}/token" \
            -d "grant_type=urn:ietf:params:oauth:grant-type:device_code" \
            -d "client_id=${PISTUDIO_CLIENT_ID}" \
            -d "device_code=${device_code}")

        error=$(printf '%s' "$token_response" | jq -r '.error // empty')

        case "$error" in
            authorization_pending)
                # Still waiting for user
                continue
                ;;
            slow_down)
                (( interval += 5 ))
                continue
                ;;
            "")
                # Success — no error field
                break
                ;;
            *)
                local error_desc
                error_desc=$(printf '%s' "$token_response" | jq -r '.error_description // empty')
                echo "error: authentication failed: ${error}${error_desc:+ — $error_desc}" >&2
                return 1
                ;;
        esac
    done

    local access_token refresh_token
    access_token=$(printf '%s' "$token_response" | jq -r '.access_token // empty')
    refresh_token=$(printf '%s' "$token_response" | jq -r '.refresh_token // empty')

    if [[ -z "$access_token" || -z "$refresh_token" ]]; then
        echo "error: token response missing access_token or refresh_token" >&2
        return 1
    fi

    # Extract user info from the access token JWT
    local jwt_payload user_email resolved_tenant
    jwt_payload=$(_pistudio_decode_jwt_payload "$access_token") || true
    user_email=$(printf '%s' "$jwt_payload" | jq -r '.upn // .unique_name // .preferred_username // empty')
    resolved_tenant=$(printf '%s' "$jwt_payload" | jq -r '.tid // empty')

    # Use resolved tenant if we logged in with "common"
    if [[ "$tenant_id" == "common" && -n "$resolved_tenant" ]]; then
        tenant_id="$resolved_tenant"
    fi

    # Store tokens
    _pistudio_write_token_file "$profile" "$tenant_id" "$refresh_token" "$user_email"

    # Cache the access token in session
    _pistudio_setup_session_cache
    local key
    key=$(printf '%s' "https://management.azure.com" | tr -c '[:alnum:]' '_' | tr '[:upper:]' '[:lower:]')
    printf '%s' "$access_token" > "${PISTUDIO_SESSION_DIR}/${key}.token"

    echo "Logged in as ${user_email:-unknown} (tenant: ${tenant_id})"
    return 0
}

pistudio_logout() {
    local profile="${1:-default}"
    local file
    file=$(_pistudio_token_file "$profile")
    if [[ -f "$file" ]]; then
        rm -f "$file"
        echo "Logged out (profile: ${profile})"
    else
        echo "No stored credentials for profile: ${profile}"
    fi
}

pistudio_status() {
    local profile="${1:-default}"
    local file
    file=$(_pistudio_token_file "$profile")

    if [[ ! -f "$file" ]]; then
        jq -n '{logged_in: false}'
        return 0
    fi

    local tenant_id user acquired_at
    tenant_id=$(_pistudio_read_token_field "$profile" "tenant_id") || true
    user=$(_pistudio_read_token_field "$profile" "user") || true
    acquired_at=$(_pistudio_read_token_field "$profile" "acquired_at") || true

    jq -n \
        --argjson logged_in true \
        --arg connectedAs "${user:-unknown}" \
        --arg tenantId "${tenant_id:-unknown}" \
        --arg acquiredAt "${acquired_at:-}" \
        '{logged_in: $logged_in, connectedAs: $connectedAs, tenantId: $tenantId, acquiredAt: $acquiredAt}'
}

pistudio_has_valid_token() {
    local profile="${1:-default}"
    local file
    file=$(_pistudio_token_file "$profile")
    [[ -f "$file" ]] || return 1

    local refresh_token
    refresh_token=$(_pistudio_read_token_field "$profile" "refresh_token") || true
    [[ -n "$refresh_token" ]] || return 1

    return 0
}

# ─── Token Refresh ────────────────────────────────────────────

get_access_token() {
    local resource="$1"

    _pistudio_setup_session_cache

    # 1. Check session cache
    local key
    key=$(printf '%s' "$resource" | tr -c '[:alnum:]' '_' | tr '[:upper:]' '[:lower:]')
    local cache_file="${PISTUDIO_SESSION_DIR}/${key}.token"

    if [[ -s "$cache_file" ]]; then
        # Check if cached token is still valid (rough — JWT exp claim)
        local cached_token jwt_payload exp_time now_time
        cached_token=$(cat "$cache_file")
        jwt_payload=$(_pistudio_decode_jwt_payload "$cached_token" 2>/dev/null) || true
        exp_time=$(printf '%s' "$jwt_payload" | jq -r '.exp // 0' 2>/dev/null || echo 0)
        now_time=$(date +%s)

        if (( exp_time > now_time + 120 )); then
            printf '%s' "$cached_token"
            return 0
        fi
    fi

    # 2. Determine profile — use PISTUDIO_ACTIVE_PROFILE if set
    local profile="${PISTUDIO_ACTIVE_PROFILE:-default}"

    # 3. Try refresh token exchange
    local refresh_token tenant_id
    refresh_token=$(_pistudio_read_token_field "$profile" "refresh_token") || true
    tenant_id=$(_pistudio_read_token_field "$profile" "tenant_id") || true

    if [[ -n "$refresh_token" && -n "$tenant_id" ]]; then
        local token_response
        token_response=$(_pistudio_refresh_token "$tenant_id" "$refresh_token" "$resource")

        local new_access_token new_refresh_token error
        error=$(printf '%s' "$token_response" | jq -r '.error // empty')
        new_access_token=$(printf '%s' "$token_response" | jq -r '.access_token // empty')
        new_refresh_token=$(printf '%s' "$token_response" | jq -r '.refresh_token // empty')

        if [[ -n "$new_access_token" && -z "$error" ]]; then
            # Cache access token in session
            printf '%s' "$new_access_token" > "$cache_file"

            # Update stored refresh token if rotated (atomic write)
            if [[ -n "$new_refresh_token" ]]; then
                _pistudio_lock
                local current_user
                current_user=$(_pistudio_read_token_field "$profile" "user") || true
                _pistudio_write_token_file "$profile" "$tenant_id" "$new_refresh_token" "$current_user"
                _pistudio_unlock
            fi

            printf '%s' "$new_access_token"
            return 0
        fi

        # Handle invalid_grant (expired refresh token)
        if [[ "$error" == "invalid_grant" ]]; then
            echo "warning: refresh token expired for profile '$profile'. Re-login required." >&2
            rm -f "$(_pistudio_token_file "$profile")"
        fi
    fi

    # 4. Fallback: try m365 if available
    if command -v m365 &>/dev/null; then
        local token
        token=$(m365 util accesstoken get --resource "$resource" 2>/dev/null || true)
        if [[ -n "$token" && "$token" != "null" ]]; then
            printf '%s' "$token" > "$cache_file"
            printf '%s' "$token"
            return 0
        fi
    fi

    # 5. Fallback: try az CLI if available
    if command -v az &>/dev/null; then
        local token
        local -a az_args=(account get-access-token --resource "$resource" --query accessToken -o tsv)
        # Use profile's tenant for cross-tenant token acquisition
        if [[ -n "${PISTUDIO_PROFILE_TENANT_ID:-}" ]]; then
            az_args+=(--tenant "${PISTUDIO_PROFILE_TENANT_ID}")
        fi
        token=$(az "${az_args[@]}" 2>/dev/null || true)
        if [[ -n "$token" && "$token" != "null" ]]; then
            printf '%s' "$token" > "$cache_file"
            printf '%s' "$token"
            return 0
        fi
    fi

    echo ""
    return 1
}

_pistudio_refresh_token() {
    local tenant_id="$1"
    local refresh_token="$2"
    local resource="$3"

    curl -sS --connect-timeout 10 --max-time 30 \
        -X POST "${PISTUDIO_LOGIN_AUTHORITY}/${tenant_id}/oauth2/v2.0/token" \
        -d "grant_type=refresh_token" \
        -d "client_id=${PISTUDIO_CLIENT_ID}" \
        -d "refresh_token=${refresh_token}" \
        --data-urlencode "scope=${resource}/.default offline_access"
}

# ─── Identity Helpers ─────────────────────────────────────────

get_active_tenant_id() {
    local profile="${PISTUDIO_ACTIVE_PROFILE:-default}"

    # 1. From stored token file
    local tid
    tid=$(_pistudio_read_token_field "$profile" "tenant_id") || true
    if [[ -n "$tid" ]]; then
        echo "$tid"
        return 0
    fi

    # 2. Fallback: decode from a cached session token
    if [[ -d "$PISTUDIO_SESSION_DIR" ]]; then
        for f in "$PISTUDIO_SESSION_DIR"/*.token; do
            [[ -f "$f" ]] || continue
            local payload
            payload=$(_pistudio_decode_jwt_payload "$(cat "$f")" 2>/dev/null) || continue
            tid=$(printf '%s' "$payload" | jq -r '.tid // empty')
            if [[ -n "$tid" ]]; then
                echo "$tid"
                return 0
            fi
        done
    fi

    # 3. Use profile's configured tenant if available
    if [[ -n "${PISTUDIO_PROFILE_TENANT_ID:-}" ]]; then
        echo "${PISTUDIO_PROFILE_TENANT_ID}"
        return 0
    fi

    # 4. Fallback: m365/az
    if command -v m365 &>/dev/null; then
        local m365_out
        m365_out=$(m365 status --output json 2>/dev/null || true)
        if printf '%s' "$m365_out" | jq -e 'type=="object"' >/dev/null 2>&1; then
            tid=$(printf '%s' "$m365_out" | jq -r '.tenantId // empty')
            [[ -n "$tid" ]] && echo "$tid" && return 0
        fi
    fi
    if command -v az &>/dev/null; then
        local az_out
        az_out=$(az account show --output json 2>/dev/null || true)
        if printf '%s' "$az_out" | jq -e 'type=="object"' >/dev/null 2>&1; then
            tid=$(printf '%s' "$az_out" | jq -r '.tenantId // empty')
            [[ -n "$tid" ]] && echo "$tid" && return 0
        fi
    fi

    echo ""
}

get_active_user() {
    local profile="${PISTUDIO_ACTIVE_PROFILE:-default}"

    # 1. From stored token file
    local user
    user=$(_pistudio_read_token_field "$profile" "user") || true
    if [[ -n "$user" ]]; then
        echo "$user"
        return 0
    fi

    # 2. Fallback: decode from a cached session token
    if [[ -d "$PISTUDIO_SESSION_DIR" ]]; then
        for f in "$PISTUDIO_SESSION_DIR"/*.token; do
            [[ -f "$f" ]] || continue
            local payload
            payload=$(_pistudio_decode_jwt_payload "$(cat "$f")" 2>/dev/null) || continue
            user=$(printf '%s' "$payload" | jq -r '.upn // .unique_name // .preferred_username // empty')
            if [[ -n "$user" ]]; then
                echo "$user"
                return 0
            fi
        done
    fi

    # 3. Fallback: m365/az
    if command -v m365 &>/dev/null; then
        local m365_out
        m365_out=$(m365 status --output json 2>/dev/null || true)
        if printf '%s' "$m365_out" | jq -e 'type=="object"' >/dev/null 2>&1; then
            user=$(printf '%s' "$m365_out" | jq -r '.connectedAs // empty')
            [[ -n "$user" ]] && echo "$user" && return 0
        fi
    fi
    if command -v az &>/dev/null; then
        local az_out
        az_out=$(az account show --output json 2>/dev/null || true)
        if printf '%s' "$az_out" | jq -e 'type=="object"' >/dev/null 2>&1; then
            user=$(printf '%s' "$az_out" | jq -r '.user.name // empty')
            [[ -n "$user" ]] && echo "$user" && return 0
        fi
    fi

    echo "${USER:-unknown}"
}
