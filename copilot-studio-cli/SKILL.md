---
name: copilot-studio-cli
description: |
  CLI for managing Microsoft Copilot Studio copilots, sub-agents, and conversation analytics via Power Platform and Dataverse APIs.
  Use this skill when:
  - Managing Copilot Studio copilots (list, create, remove, restore)
  - Exporting conversation activities and generating analytics
  - Listing, creating, updating, cloning, or deleting sub-agents
  - Discovering Power Platform environments and bots
  - Querying Copilot Studio feature flags
  - Searching or watching conversations in real-time
  Trigger keywords: copilot studio, power platform, dataverse, bot activities, sub-agent, conversation export, pistudio
---

# πStudio (Copilot Studio) CLI

Bash CLI for managing Microsoft Copilot Studio copilots, sub-agents, and conversation analytics. Pure `curl` + `jq` — no external SDK dependencies.

**Primary entry point:** `bin/pistudio` (wrapper that translates subcommands into underlying `--flag` syntax)

## Dependencies

```bash
brew install jq    # macOS (or apt install jq on Linux)
# curl and base64 are pre-installed
# No m365 CLI, az CLI, or Node.js required
```

## Quick Start

```bash
# 1. Authenticate (opens browser for SSO)
pistudio login -p dev

# 2. Preflight checks
pistudio doctor -p dev

# 3. Explore
pistudio envs
pistudio bots -p dev

# 4. Export conversations
pistudio convs -p dev
pistudio convs export <conversation-id> -p dev

# 5. Manage agents
pistudio agents -p dev
pistudio agents get 'My Agent' -p dev
```

## Authentication

Built-in OAuth2 — no external CLI needed.

```bash
# Browser SSO with PKCE (default)
pistudio login -p dev

# Device code flow (headless/SSH)
pistudio login -p dev --device-code

# Check auth status
pistudio status -p dev

# Sign out
pistudio logout -p dev
```

Uses the Azure CLI public client app ID. Tokens stored in `~/.config/pistudio/tokens/` (chmod 0600) with per-process session caching and automatic refresh.

## Configuration

Profiles in `config/copilot-export.json`:

```json
{
  "defaultProfile": "dev",
  "profiles": {
    "dev": {
      "name": "My DEV",
      "tenantId": "YOUR_TENANT_ID",
      "environmentId": "YOUR_ENV_ID",
      "environmentUrl": "https://YOUR_ENV_ID.environment.api.powerplatform.com",
      "dataverseUrl": "https://YOUR_ORG.api.crm.dynamics.com",
      "botId": "your_bot_schema_name",
      "protected": false
    },
    "prod": {
      "name": "My PROD",
      "tenantId": "YOUR_TENANT_ID",
      "environmentId": "YOUR_PROD_ENV_ID",
      "environmentUrl": "https://YOUR_PROD_ENV_ID.environment.api.powerplatform.com",
      "dataverseUrl": "https://YOUR_PROD_ORG.api.crm.dynamics.com",
      "botId": "your_prod_bot_schema",
      "protected": true
    }
  }
}
```

Environment variable overrides: `COPILOT_ENV_URL`, `COPILOT_BOT_ID`, `COPILOT_TENANT_ID`, `COPILOT_APP_ID`, `PISTUDIO_CONFIG_FILE`, `PISTUDIO_EXPORT_SCRIPT`.

## Commands Reference

### Discovery

```bash
pistudio envs                         # List environments
pistudio envs details <env-id>        # Environment info, permissions, capacity
pistudio envs flags <env-id>          # Feature flags
pistudio bots -p dev                  # List bots
pistudio open -p dev                  # Open Copilot Studio in browser
```

### Copilot Management

```bash
pistudio copilot list -p dev
pistudio copilot get --name "My Copilot" -p dev
pistudio copilot create --name "Research Agent" --schema my_research -p dev
pistudio copilot remove --name "Old Bot" --yes-really-delete --confirm "Old Bot" -p dev
pistudio copilot restore --from-backup ./backups/bot_20260123 --name "My Bot" -p dev
```

### Sub-Agent Management

```bash
# List and inspect
pistudio agents -p dev
pistudio agents get 'My Agent' -p dev              # Accepts display names or schema names

# Create and update
pistudio agents create 'New Agent' -b bot_schema --yaml-file ./config.yaml -p dev
pistudio agents update bot.agent.Agent_X --field data --value ./config.yaml -p dev

# Clone and compare
pistudio agents clone bot.agent.Agent_X --name 'Agent Copy' -p dev
pistudio agents diff bot.agent.Agent_A bot.agent.Agent_B -p dev

# Backup and restore
pistudio agents backup -b bot_schema -p dev
pistudio agents restore --dir ./backups/agents_20260123 -b bot_schema -p dev

# Delete (requires safety flags)
pistudio agents delete bot.agent.Agent_X --yes-really-delete --confirm bot.agent.Agent_X -p dev
```

### Conversation Export & Analytics

```bash
# List and export
pistudio convs -p dev
pistudio convs export <conversation-id> -p dev
pistudio convs export '<id1>,<id2>' --days 7

# Search and watch
pistudio convs search 'error message' -p dev
pistudio convs watch <conversation-id> --interval 3

# Regenerate analytics from existing export
pistudio analytics ./reports/copilot_export_TIMESTAMP
```

### Dataverse Transcripts (Fallback)

When PVA API DNS doesn't resolve, use Dataverse mode:

```bash
pistudio transcripts -p prod
pistudio transcripts export <transcript-id> -p prod
pistudio transcripts export --bot-guid <bot-guid> -p prod
```

## Safety & Audit

All write operations enforce these guardrails:

| Guard | What It Does |
|-------|-------------|
| Tenant check | Active Azure AD tenant must match profile `tenantId` |
| Protected profiles | Profiles named `*prod*` or `"protected": true` require `--i-know-this-is-prod` |
| `--yes-really-delete` | Required for any delete operation |
| `--confirm <name>` | Must repeat exact copilot/agent name or ID |
| Auto-backup | Backups before every delete; delete fails closed if backup fails |
| Audit log | All mutations logged to `logs/audit/operations.jsonl` |
| `--dry-run` | Print translated command without executing |

## Output Structure

Exports go to `./reports/copilot_export_TIMESTAMP/`:

| File | Contents |
|------|----------|
| `raw_activities.json` | Full DirectLine activities (source data) |
| `messages.json` / `messages.csv` | Extracted conversation messages |
| `tool_usage.json` / `tool_usage.csv` | Sub-agent and tool invocation stats |
| `ai_observations.json` / `ai_observations.csv` | AI research findings |
| `execution_metrics.json` | Timing and performance data |
| `search_data.json` | All web searches with queries and citations |
| `phase_analytics.json` | Per-phase metrics |
| `phase_summary.json` | Aggregated stats with rankings |
| `plan_timeline.json` | Dynamic plan events from Phase Router |
| `dashboard.html` | Interactive Chart.js visualization |
| `REPORT.md` | Markdown summary with phase-by-phase analysis |

## Architecture

```
bin/pistudio              CLI wrapper — subcommands → --flag syntax
  ├── scripts/auth.sh     Shared auth (PKCE, device code, token refresh)
  └── scripts/export-activities.sh   Core engine (~5700 lines)
        ├── Power Platform BAP API   Environment discovery
        ├── Dataverse API            Bot/agent CRUD, transcripts
        ├── DirectLine API           Conversation history
        └── jq                       Analytics pipeline + report generation
```

## Troubleshooting

| Error | Solution |
|-------|----------|
| "Could not determine Dataverse URL" | Pass `--env-id` or add `dataverseUrl` to profile |
| PVA API DNS resolution failure | Use `pistudio transcripts` (Dataverse fallback) |
| Authentication errors | Run `pistudio login -p <profile>` |
| Tenant mismatch on writes | Ensure `tenantId` in profile matches active session |
| Missing permissions | Need Dataverse API access for bot/agent operations |

## Trigger Keywords

Use this skill when:
- Managing Copilot Studio copilots or sub-agents
- Exporting conversation activities or generating analytics
- Discovering Power Platform environments, bots, or feature flags
- Searching or monitoring conversations
- Working with Dataverse transcripts
