# Common Windows Gotchas & Solutions

Based on real-world Windows installation testing, here are issues users (and AI agents) commonly encounter:

## Installation Issues

### 1. **Git Bash vs Git\usr\bin\bash.exe**

**Problem:** Git for Windows ships two bash binaries:
- `C:\Program Files\Git\bin\bash.exe` ✅ Works correctly from PowerShell
- `C:\Program Files\Git\usr\bin\bash.exe` ❌ Causes "Bad file descriptor" errors

**Why:** The usr\bin version has pipe/stream handling issues when invoked via PowerShell's `&` operator.

**Solution:** pistudio.ps1 now prioritizes Git\bin\bash.exe. If you still get errors, update to latest:
```powershell
git pull origin main
```

### 2. **"Bad file descriptor" Errors**

**Symptom:**
```
/usr/bin/bash: line 1: echo: write error: Bad file descriptor
```

**Root Cause:** PowerShell's `&` operator doesn't properly redirect streams when calling bash.exe.

**Solution:** Updated pistudio.ps1 uses `Process.Start` with explicit stream redirection. Update your copy:
```powershell
cd PiStudio-CLI
git pull origin main
```

### 3. **Empty Arguments Passing as ''**

**Symptom:**
```
pistudio: '' is not a command.
Did you mean?
    login
```

**Root Cause:** When no arguments are passed, PowerShell was creating an empty string `''` and passing it to bash.

**Solution:** Fixed in pistudio.ps1 - only builds argument string if $Arguments has content. Update to latest.

### 4. **jq Not Found**

**Symptom:**
```
Tools:
  - jq: MISSING
```

**Solutions (in order of ease):**

1. **Automated (recommended):** Run `scripts/install-windows.ps1` — auto-downloads jq.exe v1.7.1 to bin/
2. **Chocolatey (requires admin):** `choco install jq`
3. **Manual download:**
   - Download from https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-windows-amd64.exe
   - Save as `C:\Windows\System32\jq.exe` (requires admin)
   - OR save to PiStudio-CLI\bin\jq.exe (no admin needed)

### 5. **Execution Policy Blocks Scripts**

**Symptom:**
```
.\bin\pistudio.ps1 : File cannot be loaded because running scripts is disabled
```

**Solutions:**

```powershell
# Option 1: Bypass for single execution
powershell -ExecutionPolicy Bypass -File scripts/install-windows.ps1

# Option 2: Change policy permanently (requires admin)
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser

# Option 3: Unblock downloaded scripts
Unblock-File .\bin\pistudio.ps1
```

### 6. **Profile Doesn't Load Alias**

**Symptom:** After installation, `pistudio` still shows "command not found"

**Solution:** You must restart PowerShell to reload $PROFILE:

```powershell
# Check if alias is in profile
Get-Content $PROFILE | Select-String pistudio

# Restart PowerShell, then verify
Get-Command pistudio
```

### 7. **Spaces in Usernames**

**Problem:** If your Windows username has spaces (e.g., "Anthony Hopkins"), paths like `C:\Users\Anthony Hopkins\...` can cause issues.

**Solution:** All scripts now properly quote paths, but if you encounter errors:
```powershell
# Clone to a path without spaces
cd C:\
git clone https://github.com/anthonyrhopkins/PiStudio-CLI.git pistudio
cd pistudio
```

### 8. **OneDrive Sync Conflicts**

**Problem:** If your Documents folder syncs to OneDrive, PowerShell $PROFILE gets synced and can cause conflicts across machines.

**Solution:** Store the repo outside OneDrive:
```powershell
# Clone to C:\ or another non-synced location
cd C:\
git clone https://github.com/anthonyrhopkins/PiStudio-CLI.git
```

Then adjust the alias path in $PROFILE accordingly.

### 9. **Multiple PowerShell Versions**

Windows has multiple PowerShell profiles:
- **PowerShell 5.1:** `Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1`
- **PowerShell 7+:** `Documents\PowerShell\Microsoft.PowerShell_profile.ps1`

**Solution:** Check which PowerShell you're using:
```powershell
$PSVersionTable.PSVersion
Write-Output $PROFILE
```

Add the alias to the correct profile for your version.

## Runtime Issues

### 10. **Authentication Failures**

**Symptom:**
```
Auth:
  - Token status: expired or missing
```

**Solution:**
```powershell
# Login creates tokens at: $env:USERPROFILE\.config\pistudio\tokens\{profile}.json
pistudio login -p dev

# For headless/SSH environments:
pistudio login -p dev --device-code
```

### 11. **Tenant Mismatch on Write Operations**

**Symptom:**
```
ERROR: Tenant mismatch - active tenant does not match profile tenant
```

**Root Cause:** Safety feature — prevents accidentally modifying the wrong tenant.

**Solution:** Ensure your profile's `tenantId` matches your current Azure AD session:
```powershell
pistudio status -p dev
# Should show matching tenant IDs
```

### 12. **Protected Profile Write Errors**

**Symptom:**
```
ERROR: Profile 'prod' is protected. Use --i-know-this-is-prod to proceed.
```

**Root Cause:** Safety feature — profiles named `*prod*` or with `"protected": true` block writes.

**Solution:** Add the safety flag:
```powershell
pistudio agents update bot.agent.Agent_X --field data --value ./config.yaml -p prod --i-know-this-is-prod
```

## AI Agent Installation Issues

When Claude or other AI coding assistants try to install pistudio on Windows:

### 13. **Bash Tool Failures (Exit Code 1/127)**

**Problem:** AI agents using `Bash` tool get repeated failures:
```
Bash(echo test)
⎿ Error: Exit code 1
```

**Root Cause:** The Bash tool in Claude Code is designed for Unix shells, not Windows CMD/PowerShell.

**Solution for AI:** Use PowerShell commands via Bash tool:
```bash
# Instead of: cd ~/path && ls
# Use: pwsh.exe -Command "Get-ChildItem"

# For pistudio commands:
pwsh.exe -ExecutionPolicy Bypass -File "C:\Users\Name\PiStudio-CLI\bin\pistudio.ps1" doctor 2>&1
```

### 14. **Path Conversion Issues**

**Problem:** Windows paths with spaces or backslashes break bash commands.

**Solution:** The ConvertTo-BashPath function handles this:
- `C:\Users\Anthony Hopkins\foo` → `/c/Users/Anthony Hopkins/foo`
- Properly escapes spaces in PATH variable

### 15. **curl SSL Certificate Errors (Corporate Networks)**

**Symptom:**
```
curl: (60) SSL certificate problem: self signed certificate in certificate chain
```

**Root Cause:** Corporate proxies inject SSL inspection certificates.

**Solution:** Add to auth.sh or config:
```bash
# In scripts/auth.sh, add to curl calls:
curl --cacert /path/to/corporate-ca.crt ...

# OR disable verification (not recommended for production):
export CURL_CA_BUNDLE=""
```

## Prevention Checklist for Future Updates

When adding new features, test on Windows:

- [ ] Run automated installer on fresh Windows machine
- [ ] Test with username containing spaces
- [ ] Verify both PowerShell 5.1 and 7+ work
- [ ] Test with OneDrive-synced Documents folder
- [ ] Verify corporate proxy scenarios
- [ ] Test with both admin and non-admin users
- [ ] Confirm Git\bin\bash.exe is used (not Git\usr\bin)
- [ ] Check jq.exe is bundled or installation instructions are clear
