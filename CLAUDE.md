# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**Start here:** Read `copilot-studio-cli.skill` first for quick command reference and workflows.

## Project Overview

Bash CLI for managing Microsoft Copilot Studio agents via Power Platform and Dataverse APIs. Uses pure `curl`+`jq` OAuth2 device code flow for authentication (no external CLI dependencies).

## Commands

**Prefer `bin/pistudio`** over raw `export-activities.sh` flags. It translates human-friendly subcommands into the underlying `--flag` syntax. Any `--flag` arguments pass through unchanged.

```bash
# Preferred CLI wrapper (see bin/pistudio --help for full reference)
pistudio envs                              # List environments
pistudio bots -p dev                   # List bots
pistudio agents -p dev                 # List sub-agents
pistudio agents get 'Phase Router'         # Export agent config (display names work)
pistudio convs -p dev                  # List conversations
pistudio convs export <id>                 # Export conversation
pistudio analytics ./reports/some_export   # Regenerate analytics from existing data
pistudio login -p dev_prod             # Login with tenant from profile
pistudio status                            # Auth status + active profile

# Underlying script (pistudio wraps this — use directly only when needed)
chmod +x scripts/*.sh

# List environments (discovery)
./scripts/export-activities.sh --list-envs

# List bots in environment
./scripts/export-activities.sh --list-bots

# List sub-agents for a bot
./scripts/export-activities.sh --list-subagents -b 'bot_schema_name'

# Export conversation activities
./scripts/export-activities.sh -c 'conversation-uuid' -b 'bot_schema_name'

# Export with date filter
./scripts/export-activities.sh -c 'conv1,conv2' --days 7

# Export sub-agent configuration to YAML
./scripts/export-activities.sh --export-agent --agent-schema 'bot.agent.Agent_Xyz'

# Create new sub-agent
./scripts/export-activities.sh --create-agent -b 'bot_schema' --agent-name 'My Agent' --yaml-file './config.yaml'

# Update sub-agent
./scripts/export-activities.sh --update-agent --agent-schema 'bot.agent.Agent_X' --field data --value './config.yaml'

# Delete sub-agent
./scripts/export-activities.sh --delete-agent --agent-schema 'bot.agent.Agent_X'

# Get feature flags
./scripts/export-activities.sh --feature-flags --env-id 'env-id'

# Re-generate analytics from existing export
./scripts/export-activities.sh --analytics-only -o ./reports/existing_export

# List conversation transcripts from Dataverse (more reliable than PVA API)
./scripts/export-activities.sh --list-transcripts --profile your_profile

# Export using Dataverse transcripts (fallback when PVA API fails)
./scripts/export-activities.sh --from-dataverse --transcript-id 'transcript-guid' --profile your_profile

# Export with bot GUID filter
./scripts/export-activities.sh --from-dataverse --bot-guid 'bot-guid' --profile your_profile
```

## Architecture

Single Bash script (`scripts/export-activities.sh`) with shared auth module (`scripts/auth.sh`):
1. Authenticates via Azure AD OAuth2 device code flow (pure curl+jq)
2. Calls Power Platform BAP API for environment discovery
3. Calls Dataverse API for bot/agent CRUD operations
4. Calls DirectLine API for conversation history
5. Uses `jq` for JSON processing and analytics generation
6. Generates HTML dashboard, CSV, JSON, and Markdown reports

### Auth Module (`scripts/auth.sh`)

Shared module sourced by both `bin/pistudio` and `scripts/export-activities.sh`. Uses the Azure CLI public client app ID (`04b07795-8ddb-461a-bbee-02f9e1bf7b46`).

- **Device code flow**: `pistudio_login(profile, tenant_id)` — interactive login
- **Token refresh**: `get_access_token(resource)` — exchanges refresh token for resource-scoped access tokens
- **JWT decode**: Pure bash+base64 for extracting tenant/user from tokens
- **Storage**: Refresh tokens in `~/.config/pistudio/tokens/{profile}.json` (chmod 0600)
- **Session cache**: Per-process access token cache in `$TMPDIR`, cleaned on EXIT
- **Fallback**: Optional m365/az CLI fallback if refresh token unavailable

## Dataverse Transcripts (Fallback Mode)

The PVA API URL generation (`get_pva_api_url()`) can fail for some environments when DNS doesn't resolve the generated URL pattern. The `--from-dataverse` mode provides a more reliable alternative by fetching conversation data directly from the Dataverse `conversationtranscripts` table.

### When to Use Dataverse Mode

- PVA API returns DNS resolution errors
- Environment URL pattern doesn't resolve
- You need to list all conversations for a bot
- You want more reliable data access

### Workflow

```bash
# 1. List available transcripts
./scripts/export-activities.sh --list-transcripts --profile your_profile

# 2. Export specific transcript
./scripts/export-activities.sh --from-dataverse --transcript-id 'abc123-...' --profile your_profile
```

### How It Works

1. Queries Dataverse `conversationtranscripts` table filtered by `schemaname eq 'pva-studio'`
2. Optionally filters by bot GUID from the `bots` table
3. Extracts the `content` field which contains JSON-encoded activities
4. Processes activities through the same analytics pipeline as PVA API exports

## Configuration

Environment variables or `config/copilot-export.json`:
- `COPILOT_ENV_URL` - Power Platform environment API URL
- `COPILOT_BOT_ID` - Bot schema name
- `COPILOT_TENANT_ID` - Azure AD tenant ID
- `COPILOT_APP_ID` - Optional custom app registration (defaults to Azure CLI app)

### Example Configuration

```bash
export COPILOT_ENV_URL="https://YOUR_ENV_ID.environment.api.powerplatform.com"
export COPILOT_BOT_ID="your_bot_schema_name"
export COPILOT_TENANT_ID="YOUR_TENANT_ID"
```

| Resource | Value |
|----------|-------|
| Environment | Your environment name |
| Dataverse URL | `https://YOUR_ORG.api.crm.dynamics.com` |
| Bot | Your bot display name |

**Note:** The PVA API URL generation may fail for some environments. Use `--from-dataverse` mode as a fallback.

### Finding Configuration Values

```bash
# Get tenant ID and user for current logged-in session
pistudio status -p dev

# List environments
pistudio envs -p dev

# Environment URL pattern
# https://{ENV_ID}.environment.api.powerplatform.com
```

**Note:** Always pass `--profile` or `--env-id` to ensure the correct Dataverse URL is used for your environment.

## Dependencies

- `jq` - JSON processing
- `curl` - HTTP requests
- `base64` - JWT decoding (pre-installed on macOS/Linux)

## Output Structure

Exports go to `./reports/copilot_export_TIMESTAMP/`:

### Core Files
| File | Description |
|------|-------------|
| `raw_activities.json` | Full DirectLine activities (source data) |
| `messages.json/csv` | Extracted conversation messages |
| `tool_usage.json/csv` | Sub-agent and tool invocation stats |
| `ai_observations.json/csv` | AI research observations with findings |
| `execution_metrics.json` | Timing and performance data |
| `plan_timeline.json` | Dynamic plan events from Phase Router |

### Phase Analytics Files
| File | Description |
|------|-------------|
| `phase_definitions.json` | Phase boundaries detected from "Starting phase X" messages |
| `phase_analytics.json` | Per-phase metrics (activities, searches, duration) |
| `phase_summary.json` | Aggregated stats with rankings by searches/duration/observations |
| `phase_findings.json` | Research findings extracted per phase |
| `phase_observations.json` | AI observations grouped by phase |
| `search_data.json` | All web searches with queries, citations, and phase mapping |

### Reports
| File | Description |
|------|-------------|
| `dashboard.html` | Interactive HTML dashboard with Chart.js |
| `REPORT.md` | Markdown summary with phase-by-phase analysis |

## Phase-Based Analytics

The script detects multi-agent orchestration patterns by parsing "Phase Router" messages that follow the format:

```
Starting phase X of Y: [Task Description]...
```

### How Phase Detection Works

1. **Phase Boundary Detection**: Scans bot messages for `Starting phase \d+ of \d+:` pattern
2. **Time Window Segmentation**: Activities are assigned to phases based on timestamp ranges
3. **Metric Aggregation**: Each phase tracks:
   - Total activities, messages, events
   - Tool usage breakdown (search, context capture, SharePoint actions)
   - Search count and observation count
   - Duration in seconds

### Example Phase Structure (Multi-Phase Research Agent)

| Phase | Task | Typical Tools |
|-------|------|---------------|
| 0 | Discovering leadership team | UniversalSearchTool, SharePoint-CreateItem |
| 1 | Finding executive social profiles | UniversalSearchTool (multiple) |
| 2 | Analyzing company social media presence | UniversalSearchTool, CaptureContextTool |
| 3 | Researching industry context | UniversalSearchTool |
| 4 | Analyzing financial performance | UniversalSearchTool |
| 5 | Gathering recent developments | UniversalSearchTool |
| 6 | Researching patents and IP | UniversalSearchTool |
| 7 | Analyzing SEC filings | UniversalSearchTool |
| 8 | Gathering hiring intelligence | UniversalSearchTool, SendMessageTool |
| 9 | Researching event participation | UniversalSearchTool |
| 10 | Checking FDA regulations | UniversalSearchTool |
| 11 | Researching government contracts | UniversalSearchTool (heavy - 45 searches) |

## Search Data Extraction

The script extracts all web searches from `GenerativeAnswersSupportData` events:

```json
{
  "id": 0,
  "timestamp": "2026-01-21T06:01:07Z",
  "phase": 0,
  "phase_task": "Discovering leadership team...",
  "query": "Acme Corp executive team LinkedIn profiles",
  "result_count": 3,
  "citations": [
    {
      "title": "Acme Corp CEO and Key Executive Team | Craft.co...",
      "url": "https://craft.co/acme-corp/executives",
      "source": "AzoresBingUnscopedSearch"
    }
  ]
}
```

### Key Fields in GenerativeAnswersSupportData
- `rewrittenMessage` - The actual search query sent to Bing
- `verifiedSearchResults` - Array of citations with `url`, `snippet`, `searchType`
- `searchTerms` - Keywords extracted from the query

## Interactive Dashboard

The HTML dashboard (`dashboard.html`) includes:

### Tabs
1. **All Searches** - Sortable/filterable table of all web searches
2. **Messages** - Conversation timeline with expandable content
3. **Phase Findings** - Research findings organized by phase

### Search Table Features
- **Text filter**: Search queries by keyword
- **Phase filter**: Dropdown to filter by specific phase (0-11)
- **Sort options**: Newest/oldest first, by phase, by result count
- **Expandable rows**: Click to reveal all citations with clickable URLs
- **Phase color coding**: Each phase has a distinct color badge

### Charts (Chart.js)
- Tool usage distribution (doughnut chart)
- Phase duration comparison (bar chart)
- Search activity by phase (bar chart)

## Regenerating Analytics

To regenerate analytics from an existing export without re-fetching data:

```bash
./scripts/export-activities.sh --analytics-only -o ./reports/copilot_export_20260121_011216
```

This is useful for:
- Testing dashboard changes
- Regenerating reports after script updates
- Debugging analytics extraction logic

**Known issue:** Dataverse-sourced data can have `null` text fields on activities, which breaks the analytics jq pipeline (`null cannot be matched, as it is not a string`). Sanitize before running analytics:

```bash
jq '(.activities[] | select(.text == null) | .text) |= ""' raw_activities.json > /tmp/sanitized.json && mv /tmp/sanitized.json raw_activities.json
```

## Tool Categories

The script categorizes tools into:

| Category | Pattern | Examples |
|----------|---------|----------|
| `builtin` | `P:*` prefix | `P:UniversalSearchTool`, `P:CaptureContextTool`, `P:SendMessageTool` |
| `other` | Custom actions | `auto_agent_*.action.SharePoint-CreateItem`, `auto_agent_*.topic.Start` |

## Common jq Queries

```bash
# Count activities by type
cat raw_activities.json | jq '[.activities[].type] | group_by(.) | map({type: .[0], count: length})'

# Extract all search queries
cat raw_activities.json | jq '[.activities[] | select(.name == "GenerativeAnswersSupportData") | .value.rewrittenMessage] | unique'

# Find phase boundaries
cat raw_activities.json | jq '[.activities[] | select(.type == "message" and .from.role == "bot") | select(.text | test("Starting phase \\d+"))] | .[].text'

# Get tool invocations per phase
cat phase_analytics.json | jq '.[] | {phase: .phase, task: .task, tools: .tool_usage}'
```
