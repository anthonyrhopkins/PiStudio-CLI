#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

stub_bin="$tmp_dir/bin"
mkdir -p "$stub_bin"

export STUB_LOG="$tmp_dir/stub.log"
export REMOVE_MARKER="$tmp_dir/remove.called"
export BACKUP_MARKER="$tmp_dir/backup.called"

# ─── Pre-populate auth token files for auth.sh ───────────────
# auth.sh reads from PISTUDIO_AUTH_DIR/{profile}.json
auth_dir="$tmp_dir/tokens"
mkdir -p "$auth_dir"
chmod 0700 "$auth_dir"

# The tenant ID used in tests. STUB_TENANT_ID can override.
create_token_file() {
    local profile="$1"
    local tenant="${2:-t-tenant}"
    local user="${3:-stub@example.com}"
    cat >"$auth_dir/${profile}.json" <<JSON
{"tenant_id":"$tenant","refresh_token":"stub-refresh-token","user":"$user","acquired_at":"2026-01-01T00:00:00Z"}
JSON
    chmod 0600 "$auth_dir/${profile}.json"
}

create_token_file "dev" "t-tenant" "stub@example.com"
create_token_file "prod" "t-tenant" "stub@example.com"
create_token_file "default" "t-tenant" "stub@example.com"

export PISTUDIO_AUTH_DIR="$auth_dir"

# ─── Mock curl for Dataverse bot queries and deletes ──────────
# This curl wrapper intercepts Dataverse API calls and returns stub data.
# All other calls pass through to the real curl.
cat >"$stub_bin/curl" <<'CURLEOF'
#!/usr/bin/env bash

log="${STUB_LOG:?}"

# Check if this is a Dataverse bot query (used by copilot get/remove)
for arg in "$@"; do
    case "$arg" in
        *api/data/v9.2/bots*)
            echo "curl $*" >>"$log"

            # Check if it's a DELETE request
            is_delete=false
            for a in "$@"; do
                [[ "$a" == "DELETE" ]] && is_delete=true
            done

            if $is_delete; then
                # Simulate Dataverse DELETE response
                : > "${REMOVE_MARKER:?}"
                # Write to the output file if -o flag is present
                for (( i=1; i<=$#; i++ )); do
                    eval "a=\${$i}"
                    if [[ "$a" == "-o" ]]; then
                        eval "outfile=\${$((i+1))}"
                        echo '{}' > "$outfile"
                    fi
                done
                # If -w flag present, print status code
                for (( i=1; i<=$#; i++ )); do
                    eval "a=\${$i}"
                    if [[ "$a" == "-w" ]]; then
                        printf '204'
                    fi
                done
                exit 0
            fi

            # Check if this is a filter by name query
            for a in "$@"; do
                if [[ "$a" == *"filter"*"name"* ]]; then
                    cat <<JSON
{"value":[{"name":"Target Copilot","botid":"00000000-0000-0000-0000-000000000001","schemaname":"target_copilot_schema","statecode":0,"statuscode":1,"createdon":"2026-01-01","modifiedon":"2026-01-01"}]}
JSON
                    exit 0
                fi
            done

            # Default bot list response
            cat <<JSON
{"value":[{"name":"Target Copilot","botid":"00000000-0000-0000-0000-000000000001","schemaname":"target_copilot_schema","statecode":0,"statuscode":1,"createdon":"2026-01-01","modifiedon":"2026-01-01"}]}
JSON
            exit 0
            ;;
    esac
done

# Check for token endpoint (auth.sh refresh token exchange)
for arg in "$@"; do
    case "$arg" in
        *login.microsoftonline.com*token*)
            echo "curl [token-refresh] $*" >>"$log"
            # Return a stub access token and refresh token
            # JWT: header.payload.signature — payload has tid and upn
            # Stub JWT payload: {"tid":"TENANT","upn":"USER","exp":9999999999}
            stub_tenant="${STUB_TENANT_ID:-t-tenant}"
            stub_user="${STUB_USER:-stub@example.com}"
            # Build a minimal JWT with base64url-encoded payload
            payload=$(printf '{"tid":"%s","upn":"%s","exp":9999999999}' "$stub_tenant" "$stub_user" | base64 | tr '+/' '-_' | tr -d '=\n')
            stub_token="eyJ0eXAiOiJKV1QifQ.${payload}.stub-signature"
            cat <<JSON
{"access_token":"$stub_token","refresh_token":"stub-refresh-token-rotated","expires_in":3600}
JSON
            exit 0
            ;;
    esac
done

# Pass through to real curl for anything else
exec /usr/bin/curl "$@"
CURLEOF
chmod +x "$stub_bin/curl"

# ─── Export stub (backup/restore) ─────────────────────────────
cat >"$tmp_dir/export-stub.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "export-stub $*" >>"${STUB_LOG:?}"
if [[ "${1:-}" == "--backup" ]]; then
  if [[ "${EXPORT_BACKUP_FAIL:-}" == "1" ]]; then
    exit 42
  fi
  : > "${BACKUP_MARKER:?}"
  exit 0
fi
exit 0
EOF
chmod +x "$tmp_dir/export-stub.sh"

# ─── Config ──────────────────────────────────────────────────
cat >"$tmp_dir/config.json" <<'EOF'
{
  "defaultProfile": "dev",
  "profiles": {
    "dev": {
      "name": "Dev",
      "tenantId": "t-tenant",
      "environmentId": "env-0000",
      "dataverseUrl": "https://example.crm.dynamics.com",
      "botId": "dev_bot"
    },
    "prod": {
      "name": "Prod",
      "tenantId": "t-tenant",
      "environmentId": "env-0000",
      "dataverseUrl": "https://example.crm.dynamics.com",
      "botId": "prod_bot",
      "protected": true
    }
  }
}
EOF

export PATH="$stub_bin:$PATH"
export PISTUDIO_CONFIG_FILE="$tmp_dir/config.json"
export PISTUDIO_EXPORT_SCRIPT="$tmp_dir/export-stub.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

assert_rc() {
  local expected="$1"; shift
  set +e
  "$@"
  local rc=$?
  set -e
  [[ "$rc" == "$expected" ]] || fail "expected rc=$expected got rc=$rc for: $*"
}

assert_file_exists() {
  [[ -f "$1" ]] || fail "expected file to exist: $1"
}

assert_file_missing() {
  [[ ! -f "$1" ]] || fail "expected file to be missing: $1"
}

cd "$ROOT_DIR"

echo "== safety: copilot remove requires yes-really-delete"
assert_rc 1 bin/pistudio copilot remove --name "Target Copilot" -p dev --confirm "Target Copilot"

echo "== safety: copilot remove requires confirm"
assert_rc 1 bin/pistudio copilot remove --name "Target Copilot" -p dev --yes-really-delete

echo "== safety: protected profile requires prod ack for writes"
assert_rc 1 bin/pistudio --dry-run copilot create --name "X" --schema "x" -p prod
assert_rc 0 bin/pistudio --dry-run copilot create --name "X" --schema "x" -p prod --i-know-this-is-prod

echo "== safety: tenant mismatch blocks writes"
# Update the token file to have a different tenant
create_token_file "dev" "other-tenant" "stub@example.com"
export STUB_TENANT_ID="other-tenant"
assert_rc 1 bin/pistudio --dry-run copilot create --name "X" --schema "x" -p dev
# Restore
create_token_file "dev" "t-tenant" "stub@example.com"
export STUB_TENANT_ID="t-tenant"

echo "== safety: backup failure blocks delete"
rm -f "$REMOVE_MARKER" "$BACKUP_MARKER"
export EXPORT_BACKUP_FAIL=1
assert_rc 42 bin/pistudio copilot remove --name "Target Copilot" -p dev --force --yes-really-delete --confirm "Target Copilot"
assert_file_missing "$REMOVE_MARKER"
assert_file_missing "$BACKUP_MARKER"
unset EXPORT_BACKUP_FAIL

echo "== safety: backup runs before delete (happy path)"
rm -f "$REMOVE_MARKER" "$BACKUP_MARKER"
assert_rc 0 bin/pistudio copilot remove --name "Target Copilot" -p dev --force --yes-really-delete --confirm "Target Copilot"
assert_file_exists "$BACKUP_MARKER"
assert_file_exists "$REMOVE_MARKER"

echo "== safety: agents delete requires yes + confirm (dry-run)"
assert_rc 1 bin/pistudio --dry-run agents delete foo.agent.Agent_123 -p dev --confirm foo.agent.Agent_123
assert_rc 1 bin/pistudio --dry-run agents delete foo.agent.Agent_123 -p dev --yes-really-delete
assert_rc 0 bin/pistudio --dry-run agents delete foo.agent.Agent_123 -p dev --yes-really-delete --confirm foo.agent.Agent_123

echo "ALL SAFETY TESTS PASSED"
