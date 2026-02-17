# πStudio Installation Guide

Cross-platform installation instructions for Windows (PowerShell 5/7), Linux, and macOS.

## Prerequisites

### All Platforms

- **Git** — for cloning the repository
- **jq** — JSON processor for parsing API responses
- **curl** — HTTP client (usually pre-installed)

### Platform-Specific

#### Windows (PowerShell 5.1 or 7+)

```powershell
# Check PowerShell version
$PSVersionTable.PSVersion

# Install jq via Chocolatey (recommended)
choco install jq

# OR download manually from https://jqlang.github.io/jq/download/
# Place jq.exe in C:\Windows\System32 or add to PATH
```

**Git Bash on Windows:**
- jq and curl are included with [Git for Windows](https://git-scm.com/download/win)
- Recommended for best compatibility

#### macOS

```bash
# jq and curl are pre-installed on recent macOS versions
# If jq is missing, install via Homebrew:
brew install jq
```

#### Linux

```bash
# Debian/Ubuntu
sudo apt-get update && sudo apt-get install -y jq curl

# RHEL/CentOS/Fedora
sudo yum install -y jq curl

# Arch
sudo pacman -S jq curl
```

---

## Installation

### 1. Clone the Repository

```bash
# All platforms (use Git Bash on Windows)
git clone https://github.com/anthonyrhopkins/copilot-studio-cli.git
cd copilot-studio-cli
```

### 2. Make Scripts Executable (macOS/Linux only)

```bash
chmod +x bin/pistudio scripts/*.sh
```

**Windows:** Skip this step — permissions don't apply the same way.

### 3. Verify Installation

Run the doctor command to check prerequisites:

```bash
# macOS/Linux/Git Bash
./bin/pistudio doctor

# Windows PowerShell (run from Git Bash instead)
# See "Running on Windows" section below
```

Expected output:
```
[✓] Tool checks passed
[✓] jq found: jq-1.7.1
[✓] curl found: curl 8.x
```

---

## Configuration

### Create Config File

```bash
cp config/copilot-export.example.json config/copilot-export.json
```

### Edit Configuration

Open `config/copilot-export.json` and fill in your environment details:

```json
{
  "defaultProfile": "dev",
  "profiles": {
    "dev": {
      "name": "Development",
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
      "name": "Production",
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

### Finding Configuration Values

#### Using pistudio (after authentication)

```bash
# Authenticate first
./bin/pistudio login -p dev

# Get tenant ID and user info
./bin/pistudio status -p dev

# List environments (shows environment IDs and URLs)
./bin/pistudio envs

# List bots in an environment
./bin/pistudio bots -p dev
```

#### Using Azure Portal

1. **Tenant ID**: Azure Portal → Azure Active Directory → Overview → Tenant ID
2. **Environment ID**: Power Platform admin center → Environments → Select environment → Settings → Details
3. **Dataverse URL**: Power Platform admin center → Environments → Select environment → Environment URL
4. **Bot Schema Name**: Copilot Studio → Settings → Advanced → Bot ID (schema name like `cr0ab_copilotname`)

---

## Authentication

### First-Time Setup

```bash
# Browser-based SSO (recommended)
./bin/pistudio login -p dev

# Device code flow (for SSH/headless environments)
./bin/pistudio login -p dev --device-code
```

This will:
1. Open your browser for Azure AD authentication
2. Store refresh tokens in `~/.config/pistudio/tokens/dev.json`
3. Cache access tokens per-process for API calls

### Verify Authentication

```bash
./bin/pistudio status -p dev
```

Expected output:
```
[✓] Authenticated as: you@company.com
[✓] Tenant: YOUR_TENANT_ID
[✓] Active profile: dev
```

---

## Running on Windows

### Quick Install (Recommended)

Run the automated installer from PowerShell:

```powershell
# Clone the repo first
git clone https://github.com/anthonyrhopkins/PiStudio-CLI.git
cd PiStudio-CLI

# Run installer (may need -ExecutionPolicy Bypass)
powershell -ExecutionPolicy Bypass -File scripts/install-windows.ps1
```

The installer will:
1. Verify Git for Windows is installed
2. Download jq.exe to the bin/ directory
3. Add pistudio alias to your PowerShell profile
4. Create config file from template
5. Run doctor to verify setup

**Then restart PowerShell** and the `pistudio` command will be available globally.

### Manual Installation

If you prefer manual setup or the installer fails:

#### Option 1: Git Bash (Easiest)

**Easiest approach** — Git Bash provides a full Unix-like environment on Windows:

1. Install [Git for Windows](https://git-scm.com/download/win)
2. Open **Git Bash** (not PowerShell)
3. Run pistudio commands as normal:

```bash
cd /c/Users/YourName/copilot-studio-cli
./bin/pistudio doctor
./bin/pistudio login -p dev
```

#### Option 3: Windows Subsystem for Linux (WSL)

For a full Linux environment on Windows:

```bash
# In PowerShell (as Administrator)
wsl --install

# Open Ubuntu/WSL and follow Linux installation steps
cd /mnt/c/Users/YourName/copilot-studio-cli
./bin/pistudio doctor
```

#### Option 2: PowerShell with Git Bash Backend

**Uses the PowerShell shim (`pistudio.ps1`)** which automatically delegates to Git Bash. You run commands in PowerShell but bash executes under the hood.

**Prerequisites:**
1. Install [Git for Windows](https://git-scm.com/download/win)
2. Install jq (the installer downloads it automatically, or manually via Chocolatey: `choco install jq`)

**Setup:**

```powershell
# Add pistudio function to your PowerShell profile
$repoPath = "$env:USERPROFILE\PiStudio-CLI"  # Adjust if you cloned elsewhere
Add-Content $PROFILE "`nfunction pistudio { & `"$repoPath\bin\pistudio.ps1`" @args }"

# Restart PowerShell, then run:
pistudio doctor
pistudio login -p dev
```

**Known Issues Fixed:**
- ✅ "Bad file descriptor" error - Fixed by using Process.Start instead of `&` operator
- ✅ Wrong bash.exe - Now prioritizes `Git\bin\bash.exe` over `Git\usr\bin\bash.exe`
- ✅ jq not found - Installer downloads jq.exe to bin/ directory
- ✅ Empty arguments error - Fixed argument handling in shim

**Alternatively, run commands directly:**

```powershell
# Without the alias, invoke the shim explicitly:
.\bin\pistudio.ps1 doctor
.\bin\pistudio.ps1 login -p dev
```

### Troubleshooting Windows Issues

| Issue | Solution |
|-------|----------|
| **"Bad file descriptor" error** | Updated pistudio.ps1 uses Process.Start - pull latest changes |
| **jq: command not found** | Run `scripts/install-windows.ps1` to auto-download jq.exe |
| **Git Bash not found** | Install [Git for Windows](https://git-scm.com/download/win) |
| **Wrong bash.exe (usr/bin vs bin)** | Shim now prioritizes `Git\bin\bash.exe` - update pistudio.ps1 |
| **Empty arguments cause errors** | Fixed in latest pistudio.ps1 - update from repo |
| **Execution policy blocks scripts** | Run: `powershell -ExecutionPolicy Bypass -File script.ps1` |
| **pistudio not found after setup** | Restart PowerShell to reload $PROFILE |

### Why Git Bash?

The CLI uses Bash-specific features (associative arrays, process substitution, `source`/`.` command) that don't exist in PowerShell. Git Bash provides these features on Windows without needing WSL.

---

## Shell Completions (Optional)

Enables tab completion for commands, flags, and profiles.

### Bash

```bash
# One-time use
source completions/pistudio.bash

# Permanent (add to ~/.bashrc or ~/.bash_profile)
echo 'source /path/to/copilot-studio-cli/completions/pistudio.bash' >> ~/.bashrc
```

### Zsh

```bash
# One-time use
source completions/pistudio.zsh

# Permanent (add to ~/.zshrc)
echo 'source /path/to/copilot-studio-cli/completions/pistudio.zsh' >> ~/.zshrc
```

### Windows (Git Bash)

Same as Bash instructions above, but edit `~/.bash_profile`:

```bash
# In Git Bash
echo 'source /c/Users/YourName/copilot-studio-cli/completions/pistudio.bash' >> ~/.bash_profile
```

---

## Adding to PATH (Optional)

To run `pistudio` from anywhere without `./bin/`:

### macOS/Linux

```bash
# Option 1: Symlink to /usr/local/bin (requires sudo)
sudo ln -s "$(pwd)/bin/pistudio" /usr/local/bin/pistudio

# Option 2: Add to PATH in shell profile
echo 'export PATH="$PATH:/path/to/copilot-studio-cli/bin"' >> ~/.bashrc
source ~/.bashrc

# Verify
which pistudio
pistudio --version
```

### Windows (Git Bash)

```bash
# Add to PATH in ~/.bash_profile
echo 'export PATH="$PATH:/c/Users/YourName/copilot-studio-cli/bin"' >> ~/.bash_profile
source ~/.bash_profile

# Verify
which pistudio
```

---

## Quick Start

After installation and configuration:

```bash
# 1. Authenticate
pistudio login -p dev

# 2. Verify setup
pistudio doctor -p dev

# 3. Explore your environment
pistudio envs
pistudio bots -p dev

# 4. List and export conversations
pistudio convs -p dev
pistudio convs export <conversation-id> -p dev

# 5. Manage sub-agents
pistudio agents -p dev
pistudio agents get 'My Agent Name' -p dev
```

---

## Troubleshooting

### "command not found: pistudio"

**On macOS/Linux:**
```bash
# Make sure script is executable
chmod +x bin/pistudio

# Run with explicit path
./bin/pistudio --help

# Or add to PATH (see "Adding to PATH" section)
```

**On Windows PowerShell:**
- Use Git Bash instead (see "Running on Windows" section)

### "jq: command not found"

**Windows:**
```powershell
# Option 1: Run the installer (auto-downloads to bin/)
powershell -ExecutionPolicy Bypass -File scripts/install-windows.ps1

# Option 2: Chocolatey (requires admin)
choco install jq

# Option 3: Manual download
# Download from https://jqlang.github.io/jq/download/
# Save as C:\Windows\System32\jq.exe or add to PATH
```

**macOS:**
```bash
brew install jq
```

**Windows:**
```powershell
choco install jq
# OR download from https://jqlang.github.io/jq/download/
```

**Linux:**
```bash
sudo apt-get install jq  # Debian/Ubuntu
sudo yum install jq      # RHEL/CentOS
```

### "Permission denied" errors

**macOS/Linux:**
```bash
chmod +x bin/pistudio scripts/*.sh
```

**Windows:** Not applicable — use Git Bash.

### Authentication failures

```bash
# Clear tokens and re-authenticate
rm ~/.config/pistudio/tokens/dev.json

# Windows (PowerShell):
# Remove-Item "$env:USERPROFILE\.config\pistudio\tokens\dev.json"

pistudio login -p dev

# Check tenant ID matches your Azure AD tenant
pistudio status -p dev
```

### "Bad file descriptor" (Windows PowerShell)

This error occurs when PowerShell's `&` operator pipes to bash.exe incorrectly.

**Solution:** Update pistudio.ps1 to the latest version from the repo (uses Process.Start instead):

```powershell
cd PiStudio-CLI
git pull origin main
```

### Wrong bash.exe found (Git\usr\bin vs Git\bin)

Git for Windows includes two bash binaries. `usr\bin\bash.exe` causes pipe issues from PowerShell.

**Solution:** Updated pistudio.ps1 prioritizes `Git\bin\bash.exe` - pull latest changes:

```powershell
git pull origin main
```

### "Unable to resolve environment URL"

Check that your `config/copilot-export.json` has correct values:

```bash
# List available environments
pistudio envs

# Verify environment ID matches config
cat config/copilot-export.json | jq '.profiles.dev.environmentId'
```

---

## Uninstallation

```bash
# Remove installation directory
rm -rf /path/to/copilot-studio-cli

# Remove tokens
rm -rf ~/.config/pistudio

# Remove PATH entry (if added)
# Edit ~/.bashrc or ~/.zshrc and remove the export PATH line

# Remove completions (if added)
# Edit shell profile and remove the source line

# Remove symlink (if created)
sudo rm /usr/local/bin/pistudio
```

---

## Next Steps

- Read [README.md](README.md) for full feature documentation
- See [CLAUDE.md](CLAUDE.md) for command reference and workflows
- Check [docs/DISASTER_RECOVERY.md](docs/DISASTER_RECOVERY.md) for backup/restore runbooks
- Review `templates/` directory for reusable agent configurations

---

## Support

- **Issues**: [GitHub Issues](https://github.com/anthonyrhopkins/copilot-studio-cli/issues)
- **Author**: [Anthony Hopkins](https://linkedin.com/in/anthonyrhopkins)
- **Website**: [pideas.studio](https://pideas.studio) | [pispace.dev](https://pispace.dev)
