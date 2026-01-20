# πStudio (Copilot Studio) CLI

A safe-by-default command-line tool for managing Microsoft Copilot Studio copilots, sub-agents, and conversation analytics. Pure Bash with no SDK dependencies — just `curl`, `jq`, and your Azure AD credentials.

## Why I Built This

Copilot Studio is powerful, but the portal is a ceiling. You can't script it, you can't diff agents, you can't export a conversation and actually see what happened inside a multi-phase research run. I needed programmatic access to everything — agents, conversations, the raw execution data — with safety guardrails I could trust against production.

So I built it. Pure `curl` + `jq`, no SDKs, no dependencies I don't control.

[In the beginning was the command line](https://web.stanford.edu/class/cs81n/command.txt) — and that's exactly where AI agents live now too. Built for both humans and AI to unlock the full power of Copilot Studio from the terminal.

## The Bigger Picture: AI Building AI

This CLI was designed to be operated by AI coding assistants — Claude, Codex, whatever comes next. The `.skill` file and `CLAUDE.md` teach them how to use every command. That means:

- **Claude can read an agent's YAML config, rewrite the instructions, and deploy the update** — one session, no portal
- **Claude can export a conversation, analyze what the agent actually did, and improve it** — a real feedback loop
- **You can build skills that give any AI assistant full Copilot Studio expertise** — the knowledge compounds

Agents in Copilot Studio are just structured config — YAML, JSON, topics, actions. AI assistants are great at exactly that. The CLI is the bridge between "Claude editing a file" and "that file becoming a live agent."

But here's the thing most people miss: **the agents themselves aren't the gold — the data they produce is.**

Every conversation export contains `raw_activities.json` — a complete behavioral trace of everything the agent did. Every search query it ran, every citation it found, every tool it called, every decision it made, with full timing data. That's not a chat log. That's structured intelligence you can mine, analyze across runs, and feed back into better agents.

The portal shows you a chat bubble. This CLI gives you the full execution trace. Get your shovels.

## Features

### Authentication (Zero SDK Dependencies)
- **Browser SSO with PKCE** — opens your browser, catches the callback on localhost, done
- **Device code flow** — for headless/SSH environments (`--device-code`)
- **Automatic token refresh** — exchanges refresh tokens per-resource, caches per-process
- **Multi-profile support** — switch between dev/staging/prod tenants seamlessly
- **Pure curl+jq** — no `m365`, `az`, or Node.js required (optional fallback if available)

### Copilot Management
- `pistudio copilot list` — list all copilots in your environment
- `pistudio copilot get` — get copilot details by name or ID
- `pistudio copilot create` — create a new copilot (auto-provisions and publishes)
- `pistudio copilot remove` — delete with mandatory backup, confirmation, and audit log
- `pistudio copilot restore` — one-command restore from backup directory

### Sub-Agent Management
- `pistudio agents` — list all sub-agents for a bot
- `pistudio agents get` — export agent config to YAML (accepts display names or schema names)
- `pistudio agents create` — create from YAML config
- `pistudio agents update` — update description, data, or name
- `pistudio agents delete` — delete with auto-backup and confirmation
- `pistudio agents clone` — duplicate an agent with a new name
- `pistudio agents diff` — compare two agent configurations side-by-side
- `pistudio agents backup` — back up all agents to a timestamped directory
- `pistudio agents restore` — restore agents from a backup

### Conversation Export & Analytics
- `pistudio convs` — list conversations
- `pistudio convs export` — export single or batch conversations with full activity data
- `pistudio convs search` — search conversation transcripts by keyword
- `pistudio convs watch` — real-time monitoring with configurable polling interval
- `pistudio transcripts` — list/export via Dataverse (fallback when PVA API DNS fails)
- `pistudio analytics` — regenerate reports from existing export data

### Environment Discovery
- `pistudio envs` — list Power Platform environments
- `pistudio envs details` — environment details, permissions, capacity
- `pistudio envs flags` — Copilot Studio feature flags
- `pistudio bots` — list all bots in an environment
- `pistudio open` — launch Copilot Studio UI in your browser

### Phase-Based Analytics Engine

The export pipeline automatically detects multi-agent orchestration phases from "Starting phase X of Y:" messages in bot output and generates per-phase analytics:

- Phase boundary detection with time-window segmentation
- Per-phase metrics: activity counts, tool usage breakdown, search counts, duration
- Web search extraction from `GenerativeAnswersSupportData` events with full citations
- Research findings and AI observations grouped by phase

### Interactive Dashboard

Each export generates a Chart.js dashboard (`dashboard.html`) with:

- **All Searches tab** — sortable/filterable table with expandable citations, phase color-coding
- **Messages tab** — conversation timeline with expandable content
- **Phase Findings tab** — research findings organized by phase
- Tool usage distribution chart, phase duration comparison, search activity by phase

### Generated Report Files

Exports go to `./reports/copilot_export_TIMESTAMP/`:

| File | Description |
|------|-------------|
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

### Safety & Audit

- **Tenant safety** — active tenant must match profile tenant for any write operation
- **Protected profiles** — profiles marked `"protected": true` (or named `*prod*`) require `--i-know-this-is-prod` for writes
- **Mandatory confirmation** — destructive operations require both `--yes-really-delete` and `--confirm <exact-name>`
- **Auto-backup before delete** — copilot and agent deletes automatically back up first; delete fails closed if backup fails
- **JSONL audit log** — every mutating operation logged to `logs/audit/operations.jsonl` with timestamp, actor, tenant, command, exit code, and backup path
- **Dry-run mode** — `--dry-run` prints the translated command without executing

### Developer Experience
- **Fuzzy command matching** — typo `pistudio agentss` suggests `agents`
- **Tiered help** — `pistudio` shows brief help; `pistudio agents --help` shows full reference
- **Shell completions** — bash and zsh with context-aware command/flag/profile completion
- **Color-coded output** — clear visual hierarchy in terminal
- **Passthrough mode** — any `--flag` syntax passes directly to the underlying script

## Prerequisites

- **`jq`** — JSON processing
- **`curl`** — HTTP requests
- **Bash 4+** — shell runtime
- **`base64`** — JWT decoding (pre-installed on macOS/Linux)

Optional (used as fallback if the built-in auth module is unavailable):
- [Microsoft 365 CLI](https://pnp.github.io/cli-microsoft365/) or Azure CLI (`az`)

## Installation

```bash
git clone https://github.com/anthonyrhopkins/PiStudio-CLI.git
cd PiStudio-CLI
chmod +x bin/pistudio scripts/*.sh
```

### Shell Completions (Optional)

```bash
# Bash
source completions/pistudio.bash

# Zsh
source completions/pistudio.zsh
```

Add to your shell profile for persistence.

## Configuration

Copy the example config and fill in your environment values:

```bash
cp config/copilot-export.example.json config/copilot-export.json
```

```json
{
  "defaultProfile": "dev",
  "profiles": {
    "dev": {
      "name": "My DEV",
      "user": "you@company.com",
      "tenantId": "YOUR_TENANT_ID",
      "environmentId": "YOUR_ENVIRONMENT_ID",
      "environmentUrl": "https://YOUR_ENV_ID.environment.api.powerplatform.com",
      "dataverseUrl": "https://YOUR_ORG.api.crm.dynamics.com",
      "botId": "your_bot_schema_name",
      "botName": "Your Copilot Name",
      "protected": false
    },
    "prod": {
      "name": "My PROD",
      "user": "you@company.com",
      "tenantId": "YOUR_TENANT_ID",
      "environmentId": "YOUR_PROD_ENV_ID",
      "environmentUrl": "https://YOUR_PROD_ENV_ID.environment.api.powerplatform.com",
      "dataverseUrl": "https://YOUR_PROD_ORG.api.crm.dynamics.com",
      "botId": "your_prod_bot_schema",
      "botName": "Your PROD Copilot",
      "protected": true
    }
  }
}
```

### Environment Variable Overrides

Useful in CI or when vendoring the wrapper:

| Variable | Purpose |
|----------|---------|
| `PISTUDIO_CONFIG_FILE` | Path to config JSON |
| `PISTUDIO_EXPORT_SCRIPT` | Path to `export-activities.sh` |
| `COPILOT_ENV_URL` | Power Platform environment API URL |
| `COPILOT_BOT_ID` | Bot schema name |
| `COPILOT_TENANT_ID` | Azure AD tenant ID |

## Quick Start

```bash
# 1. Authenticate (opens browser for SSO)
pistudio login -p dev

# 2. Run preflight checks
pistudio doctor -p dev

# 3. Explore your environment
pistudio envs
pistudio bots -p dev

# 4. List and export conversations
pistudio convs -p dev
pistudio convs export <conversation-id> -p dev -b <bot-schema>

# 5. Manage sub-agents
pistudio agents -p dev -b <bot-schema>
pistudio agents get 'My Agent Name' -p dev
pistudio agents clone bot.agent.Agent_X --name 'Agent Copy' -p dev
pistudio agents diff bot.agent.Agent_A bot.agent.Agent_B -p dev

# 6. Regenerate analytics from an existing export
pistudio analytics ./reports/copilot_export_20260121_011216

# 7. Watch a conversation in real-time
pistudio convs watch <conversation-id> -p dev --interval 3
```

### Dataverse Transcripts (Fallback)

When the PVA API URL doesn't resolve (DNS issues with some environments), use Dataverse mode:

```bash
# List transcripts
pistudio transcripts -p prod

# Export by transcript ID
pistudio transcripts export <transcript-id> -p prod

# Export by bot GUID
pistudio transcripts export --bot-guid <bot-guid> -p prod
```

## Safety Defaults

All write operations enforce these guardrails:

| Guard | What It Does |
|-------|-------------|
| `--profile` required | Writes require a profile so tenant safety can be enforced |
| Tenant check | Active Azure AD tenant must match the profile's `tenantId` |
| Protected profiles | Profiles named `*prod*` or with `"protected": true` block writes unless `--i-know-this-is-prod` is passed |
| `--yes-really-delete` | Required for any delete operation |
| `--confirm <name>` | Must repeat the exact copilot/agent name or ID |
| Auto-backup | Backups run before every delete; delete fails closed if backup fails |
| Audit log | All mutations logged to `logs/audit/operations.jsonl` |
| Dry-run | `--dry-run` on any command prints the translated flags without executing |

### Disaster Recovery

One-command restore from backup:

```bash
# Restore a deleted copilot (creates shell bot if needed, imports agents, provisions + publishes)
pistudio copilot restore --from-backup ./backups/copilot_schema_20260123 --name "My Copilot" -p dev

# Restore sub-agents into an existing copilot
pistudio agents restore --dir ./backups/agents_20260123 -b bot_schema -p dev
```

Full runbook: `docs/DISASTER_RECOVERY.md` (included locally)

## Architecture

```
bin/pistudio              CLI wrapper — translates subcommands to --flag syntax
  |
  +-- scripts/auth.sh     Shared auth module (PKCE, device code, token refresh)
  |
  +-- scripts/export-activities.sh   Core engine (~5700 lines)
        |
        +-- Power Platform BAP API   Environment discovery
        +-- Dataverse API            Bot/agent CRUD, transcripts
        +-- DirectLine API           Conversation history
        +-- jq                       Analytics pipeline + report generation
```

**No external SDKs.** Authentication uses the Azure CLI public client app ID (`04b07795-8ddb-461a-bbee-02f9e1bf7b46`) with standard OAuth2 flows. Tokens are stored in `~/.config/pistudio/tokens/` (chmod 0600) with per-process session caching.

## Templates

The `templates/` directory contains reusable agent configurations:

- Agent YAML configs (Leadership Discovery, Phase Router, Start Topic)
- Content limits block for token management
- Power Automate flow templates

## Testing

```bash
# Syntax validation
bash -n bin/pistudio
bash -n scripts/export-activities.sh

# Safety test suite (tenant checks, backup enforcement, confirmation gates)
./scripts/test-safety.sh
```

CI runs syntax checks and safety tests on every push to `main` and on pull requests.

## Reference

```
pistudio <command> [subcommand] [options]

Commands:
  login          Authenticate (browser SSO or --device-code)
  logout         Sign out
  status         Auth status + active profile
  doctor         Preflight checks (tools, identity, tenant, config)
  envs           Environments (list, details, flags)
  copilot        Copilot CRUD (list, get, create, remove, restore)
  bots           List bots
  agents         Sub-agents (list, get, create, update, delete, clone, diff, backup, restore)
  convs          Conversations (list, export, search, watch)
  transcripts    Dataverse transcripts (list, export)
  open           Open in Copilot Studio browser
  analytics      Regenerate analytics from existing export

Shortcuts:
  export <id>    Alias for convs export
  search <term>  Alias for convs search
  watch <id>     Alias for convs watch

Global flags:
  -p, --profile <name>           Config profile
  -b, --bot-id <name>            Bot schema name
  -v, --verbose                  Debug output
  -d, --days <N>                 Filter to last N days
  -o, --output <dir|format>      Output directory or format
  --dry-run                      Print command without executing
  --i-know-this-is-prod          Allow writes for protected profiles
  --help                         Full reference
```

## Author

Built by **Anthony Hopkins** — [GitHub](https://github.com/anthonyrhopkins) | [LinkedIn](https://linkedin.com/in/anthonyrhopkins) | [pideas.studio](https://pideas.studio) | [pispace.dev](https://pispace.dev) | [optimisticagents.com](https://optimisticagents.com)

## License

[MIT](LICENSE)
