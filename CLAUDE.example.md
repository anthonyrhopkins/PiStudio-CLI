# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Bash CLI for managing Microsoft Copilot Studio agents via Power Platform and Dataverse APIs. Uses Microsoft 365 CLI (`m365`) for authentication and token management.

## Commands

```bash
# Make script executable (first time only)
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
```

## Architecture

Single Bash script (`scripts/export-activities.sh`) that:
1. Authenticates via M365 CLI to get OAuth tokens for different resources
2. Calls Power Platform BAP API for environment discovery
3. Calls Dataverse API for bot/agent CRUD operations
4. Calls DirectLine API for conversation history
5. Uses `jq` for JSON processing and analytics generation
6. Generates HTML dashboard, CSV, JSON, and Markdown reports

## Configuration

Environment variables or `config/copilot-export.json`:
- `COPILOT_ENV_URL` - Power Platform environment API URL
- `COPILOT_BOT_ID` - Bot schema name
- `COPILOT_TENANT_ID` - Azure AD tenant ID
- `COPILOT_APP_ID` - Optional custom app registration (defaults to Azure CLI app)

### Step-by-Step: Finding Your Configuration Values

**1. Install prerequisites and authenticate:**
```bash
# Install M365 CLI
npm install -g @pnp/cli-microsoft365

# Login (opens browser)
m365 login
```

**2. Get your Tenant ID:**
```bash
m365 tenant id get
# Output: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

**3. List your environments and find the Environment ID:**
```bash
m365 pp environment list --output json | jq '.[] | {name: .properties.displayName, id: .name, dataverse: .properties.linkedEnvironmentMetadata.instanceApiUrl}'
```
The `id` field is your Environment ID. The Environment URL follows this pattern:
```
https://{ENV_ID}.environment.api.powerplatform.com
```

**4. List bots to find your Bot Schema Name:**
```bash
./scripts/export-activities.sh --list-bots \
  -t 'YOUR_TENANT_ID' \
  -e 'https://YOUR_ENV_ID.environment.api.powerplatform.com' \
  --env-id 'YOUR_ENV_ID'
```
Use the `Schema Name` value as your `COPILOT_BOT_ID`.

### Your Configuration (fill in after discovery)

```bash
export COPILOT_ENV_URL="https://YOUR_ENV_ID.environment.api.powerplatform.com"
export COPILOT_BOT_ID="your_bot_schema_name"
export COPILOT_TENANT_ID="your-tenant-id"
```

| Resource | Value |
|----------|-------|
| Tenant ID | `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` |
| Environment ID | `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` |
| Environment Name | Your Environment Name |
| Dataverse URL | `https://orgXXXXXXXX.api.crm.dynamics.com` |
| Bot Schema | `your_bot_schema` |
| Bot Name | Your Bot Name |

**Tip:** Copy this file to `CLAUDE.md` and fill in your values. The `CLAUDE.md` file is gitignored.

## Dependencies

- `m365` - Microsoft 365 CLI for authentication
- `jq` - JSON processing
- `curl` - HTTP requests

## Output Structure

Exports go to `./reports/copilot_export_TIMESTAMP/`:
- `raw_activities.json` - Full DirectLine activities
- `messages.json/csv` - Extracted conversation messages
- `tool_usage.json/csv` - Sub-agent and tool invocation stats
- `ai_observations.json/csv` - AI research observations
- `execution_metrics.json` - Timing data
- `plan_timeline.json` - Dynamic plan events
- `dashboard.html` - Visual report with Chart.js
- `REPORT.md` - Markdown summary
