# Power Automate Flows for Copilot Studio Report Writing

These flows need to be created in Power Automate to support the incremental report writing and transcript export features.

## 1. Create_Report_File

**Purpose:** Initialize a new markdown report file at the start of research

**Trigger:** Called as action from Copilot Studio

**Inputs:**
| Name | Type | Description |
|------|------|-------------|
| file_name | String | Name of file (e.g., "Anthropic_Research_Report.md") |
| folder_path | String | SharePoint folder path (e.g., "/Research Reports") |
| initial_content | String | Markdown header content |
| company_name | String | Company being researched |

**Actions:**
1. **SharePoint - Create file**
   - Site: Your SharePoint site
   - Folder Path: `folder_path` input
   - File Name: `file_name` input
   - File Content: `initial_content` input

**Outputs:**
| Name | Type | Description |
|------|------|-------------|
| file_url | String | URL to the created file |
| file_id | String | SharePoint file ID |

---

## 2. Append_To_Report_File

**Purpose:** Append findings to an existing report file after each research phase

**Trigger:** Called as action from Copilot Studio

**Inputs:**
| Name | Type | Description |
|------|------|-------------|
| file_name | String | Name of file to append to |
| folder_path | String | SharePoint folder path |
| content_to_append | String | Markdown content to add |
| company_name | String | Company being researched |

**Actions:**
1. **SharePoint - Get file content**
   - Site: Your SharePoint site
   - File Identifier: `folder_path`/`file_name`

2. **Compose** (Concatenate content)
   - Expression: `concat(body('Get_file_content'), outputs('content_to_append'))`

3. **SharePoint - Update file**
   - Site: Your SharePoint site
   - File Identifier: Same as step 1
   - File Content: Output from Compose step

**Outputs:**
| Name | Type | Description |
|------|------|-------------|
| success | Boolean | Whether append succeeded |
| updated_size | Number | New file size in bytes |

---

## 3. Export_Conversation_Transcript

**Purpose:** Export the current bot conversation using DirectLine API

**Trigger:** Called as action from Copilot Studio

**Inputs:**
| Name | Type | Description |
|------|------|-------------|
| conversation_id | String | Current conversation ID from System.Conversation.Id |
| company_name | String | Company name for file naming |
| environment_url | String | Bot environment URL |
| include_tool_calls | Boolean | Whether to include tool/agent calls |
| include_knowledge_queries | Boolean | Whether to include knowledge searches |

**Actions:**

1. **HTTP - Get Auth Token**
   ```
   Method: POST
   URI: https://login.microsoftonline.com/{tenant_id}/oauth2/v2.0/token
   Headers:
     Content-Type: application/x-www-form-urlencoded
   Body:
     client_id={app_id}
     &scope=https://api.powerplatform.com/.default
     &client_secret={client_secret}
     &grant_type=client_credentials
   ```

2. **HTTP - Get Conversation Activities**
   ```
   Method: GET
   URI: {environment_url}/powervirtualagents/botsbyschema/{bot_schema}/directline/conversations/{conversation_id}/activities
   Headers:
     Authorization: Bearer {access_token}
   ```

3. **Parse JSON** - Parse the activities response

4. **Select** - Transform activities into readable format
   ```json
   {
     "timestamp": "@{item()?['timestamp']}",
     "from": "@{item()?['from']?['name']}",
     "type": "@{item()?['type']}",
     "text": "@{item()?['text']}",
     "tool_calls": "@{item()?['entities']}"
   }
   ```

5. **Filter array** (Optional) - Filter by include_tool_calls and include_knowledge_queries

6. **Compose** - Format as markdown transcript
   ```
   # Conversation Transcript
   **Company:** {company_name}
   **Conversation ID:** {conversation_id}
   **Exported:** {utcNow()}

   ---

   {formatted_messages}
   ```

7. **SharePoint - Create file**
   - File Name: `{company_name}_Transcript_{utcNow()}.md`
   - Folder: `/Research Reports/Transcripts`
   - Content: Composed markdown

**Outputs:**
| Name | Type | Description |
|------|------|-------------|
| transcript_url | String | URL to saved transcript file |
| message_count | Number | Total messages in transcript |
| duration_seconds | Number | Conversation duration |

---

## Environment Variables Needed

Create these environment variables in your Power Platform environment:

| Variable | Description |
|----------|-------------|
| `TenantId` | Azure AD tenant ID |
| `AppId` | App registration client ID |
| `AppSecret` | App registration client secret (as secret) |
| `SharePointSite` | SharePoint site URL for reports |
| `BotSchema` | Bot schema name (from --list-bots) |

---

## API Endpoints Reference

### DirectLine Activities API
```
GET {environment_url}/powervirtualagents/botsbyschema/{bot_schema}/directline/conversations/{conversation_id}/activities
Authorization: Bearer {access_token}
```

### Power Platform Token Scope
```
https://api.powerplatform.com/.default
```

### SharePoint Sites Reference
- Your site: `https://YOUR-TENANT.sharepoint.com/sites/YOUR-SITE`

---

## Security Notes

1. Store client secrets in Azure Key Vault or Power Platform secrets
2. Use managed identity where possible instead of app registrations
3. Grant minimum required permissions:
   - `Sites.ReadWrite.All` for SharePoint file operations
   - Power Platform API access for DirectLine

---

## Testing

Test each flow individually before connecting to Copilot Studio:

1. **Create_Report_File**: Run manually with test company name
2. **Append_To_Report_File**: Append test content to existing file
3. **Export_Conversation_Transcript**: Use a known conversation ID from the test panel
