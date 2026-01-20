---
name: copilot-studio-cli
description: |
  CLI for managing Microsoft Copilot Studio agents via Power Platform and Dataverse APIs.
  Use this skill when:
  - Exporting Copilot Studio conversation activities and generating analytics
  - Listing, creating, updating, or deleting Copilot Studio sub-agents
  - Discovering Power Platform environments and bots
  - Querying Copilot Studio feature flags
  Trigger keywords: copilot studio, power platform, dataverse, bot activities, sub-agent, conversation export
---

# Copilot Studio CLI

Bash CLI for managing Microsoft Copilot Studio agents. Script location: `scripts/export-activities.sh`

## Dependencies

```bash
npm install -g @pnp/cli-microsoft365  # M365 CLI for auth
brew install jq                        # macOS (or apt install jq)
# curl is pre-installed
```

## Configuration Discovery Workflow

### 1. Authenticate
```bash
m365 login  # Opens browser
```

### 2. Get Tenant ID
```bash
m365 tenant id get
# Returns: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

### 3. List Environments
```bash
m365 pp environment list --output json | jq '.[] | {name: .properties.displayName, id: .name, dataverse: .properties.linkedEnvironmentMetadata.instanceApiUrl}'
```

The `id` is your **Environment ID**. Environment URL pattern: `https://{ENV_ID}.environment.api.powerplatform.com`

### 4. List Bots
```bash
./scripts/export-activities.sh --list-bots \
  -t 'TENANT_ID' \
  -e 'https://ENV_ID.environment.api.powerplatform.com' \
  --env-id 'ENV_ID'
```

The `Schema Name` is your `COPILOT_BOT_ID`.

## Configuration

Environment variables or `config/copilot-export.json`:
```bash
export COPILOT_ENV_URL="https://ENV_ID.environment.api.powerplatform.com"
export COPILOT_BOT_ID="bot_schema_name"
export COPILOT_TENANT_ID="tenant-id"
```

## Commands Reference

### Discovery
```bash
# List environments
./scripts/export-activities.sh --list-envs -t 'TENANT_ID'

# List bots
./scripts/export-activities.sh --list-bots -t 'TENANT_ID' -e 'ENV_URL' --env-id 'ENV_ID'

# List sub-agents
./scripts/export-activities.sh --list-subagents -b 'BOT_SCHEMA' --env-id 'ENV_ID'

# Feature flags
./scripts/export-activities.sh --feature-flags --env-id 'ENV_ID' -t 'TENANT_ID'
```

### Export Conversations
```bash
# Single conversation
./scripts/export-activities.sh -c 'CONVERSATION_UUID' -b 'BOT_SCHEMA' -t 'TENANT_ID' -e 'ENV_URL'

# Multiple conversations with date filter
./scripts/export-activities.sh -c 'CONV1,CONV2' --days 7 -b 'BOT_SCHEMA' -t 'TENANT_ID' -e 'ENV_URL'

# Re-generate analytics
./scripts/export-activities.sh --analytics-only -o ./reports/existing_export
```

### Sub-Agent Management
```bash
# Export config to YAML
./scripts/export-activities.sh --export-agent --agent-schema 'bot.agent.Agent_Xyz' --env-id 'ENV_ID'

# Create agent
./scripts/export-activities.sh --create-agent -b 'PARENT_BOT' --agent-name 'My Agent' --yaml-file './config.yaml' --env-id 'ENV_ID'

# Update agent
./scripts/export-activities.sh --update-agent --agent-schema 'bot.agent.Agent_X' --field data --value './config.yaml' --env-id 'ENV_ID'

# Delete agent
./scripts/export-activities.sh --delete-agent --agent-schema 'bot.agent.Agent_X' --env-id 'ENV_ID'
```

## Output Structure

Exports to `./reports/copilot_export_TIMESTAMP/`:

| File | Contents |
|------|----------|
| `raw_activities.json` | Full DirectLine activities |
| `messages.json/csv` | Extracted messages |
| `tool_usage.json/csv` | Sub-agent invocation stats |
| `ai_observations.json` | AI research observations |
| `execution_metrics.json` | Timing data |
| `plan_timeline.json` | Dynamic plan events |
| `dashboard.html` | Visual HTML report |
| `REPORT.md` | Markdown summary |

## Troubleshooting

| Error | Solution |
|-------|----------|
| "Could not determine Dataverse URL" | Pass `--env-id` with valid environment ID |
| Authentication errors | Run `m365 login` |
| Missing permissions | Need Dataverse API access, Flow.Read.All |
