# Copilot Studio Tools (Connector Actions)

These YAML files define connector actions that can be added to the Copilot Studio bot in Copilot Studio.

## Tools Overview

| Tool | Purpose | Connector |
|------|---------|-----------|
| `Create_Report_File` | Initialize new report at research start | SharePoint |
| `Append_To_Report` | Update report after each phase | SharePoint |
| `Get_Conversation_Transcript` | Retrieve conversation activities | HTTP (DirectLine API) |
| `Save_Transcript_File` | Save transcript to SharePoint | SharePoint |

## Setup in Copilot Studio

### 1. Add SharePoint Connection

1. Go to **Tools** tab in your agent
2. Click **+ Add a tool**
3. Select **SharePoint** connector
4. Authenticate with your SharePoint account
5. Note the connection reference name

### 2. Create Each Tool

For each tool YAML file:

1. Go to **Tools** tab → **+ Add a tool** → **Create custom action**
2. Configure based on the YAML specification:
   - **Name**: Use the `displayName` value
   - **Description**: Use the `description` value
   - **Inputs**: Add each input parameter with type
   - **Outputs**: Add each output parameter

### 3. Configure SharePoint Paths

Update these paths in each tool to match your environment:

```yaml
# In Create_Report_File and Append_To_Report:
dataset: https://YOUR-TENANT.sharepoint.com/sites/YOUR-SITE
folderPath: /Shared Documents/Research Reports

# In Save_Transcript_File:
folderPath: /Shared Documents/Research Reports/Transcripts
```

### 4. Configure DirectLine API

Update the environment URL in `Get_Conversation_Transcript`:

```yaml
uri: "https://YOUR-ENVIRONMENT-ID.environment.api.powerplatform.com/powervirtualagents/botsbyschema/YOUR-BOT-SCHEMA/directline/conversations/{conversation_id}/activities"
```

Replace with your values (from `pistudio envs` and `pistudio bots`):
- Environment ID: `YOUR_ENVIRONMENT_ID`
- Bot Schema: `YOUR_BOT_SCHEMA`

## How the Tools Work Together

```
┌─────────────────────────────────────────────────────────────────┐
│                    RESEARCH START                                │
│  Initialize_Research topic calls Create_Report_File             │
│  → Creates: {Company}_Research_Report.md with header            │
│  → Sets: Global.ReportFilePath                                   │
└────────────────────────┬────────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│                    EACH PHASE COMPLETES                          │
│  1. Sub-agent returns findings                                   │
│  2. Bot formats findings as markdown section                     │
│  3. Bot appends to Global.ResearchFindings                       │
│  4. Bot calls Append_To_Report with full content                 │
│  → Updates SharePoint file with all findings so far             │
└────────────────────────┬────────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│                    RESEARCH END (Optional)                       │
│  User says "export transcript"                                   │
│  1. Bot calls Get_Conversation_Transcript                        │
│  2. Bot formats activities as markdown                           │
│  3. Bot calls Save_Transcript_File                               │
│  → Creates: {Company}_Transcript_{timestamp}.md                  │
└─────────────────────────────────────────────────────────────────┘
```

## Global Variables Used

| Variable | Type | Purpose |
|----------|------|---------|
| `Global.ReportFilePath` | String | Path to current report file |
| `Global.ResearchFindings` | String | Accumulated markdown content |
| `Global.CompanyName` | String | Company being researched |

## Alternative: Use Existing Write_Research_Findings

If you prefer to keep using list items instead of a single file, you can continue using the existing `Write_Research_Findings` tool. The single-file approach has these benefits:

**Single File (New Tools)**
- ✅ One consolidated document
- ✅ Easy to share/export
- ✅ Maintains order/structure
- ⚠️ Requires full content on each update

**List Items (Existing Tool)**
- ✅ Simple append operation
- ✅ Each finding is separate record
- ⚠️ Need to compile for final report
- ⚠️ Harder to read as single document

## Testing

Test each tool individually in Copilot Studio's test panel:

1. **Create_Report_File**:
   - Input: company_name="TestCompany", initial_content="# Test Report\n\nHeader content"
   - Verify file appears in SharePoint

2. **Append_To_Report**:
   - Input: file_path from step 1, full_content="# Test Report\n\nHeader content\n\n## New Section\n\nAdded content"
   - Verify file updated in SharePoint

3. **Get_Conversation_Transcript**:
   - Input: conversation_id from current test session
   - Verify activities array returned

4. **Save_Transcript_File**:
   - Input: company_name="TestCompany", timestamp="20260120_123456", transcript_content="# Transcript\n\nMessages..."
   - Verify file created in Transcripts folder
