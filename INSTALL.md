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

### Option 1: Git Bash (Recommended)

**Easiest approach** — Git Bash provides a full Unix-like environment on Windows:

1. Install [Git for Windows](https://git-scm.com/download/win)
2. Open **Git Bash** (not PowerShell)
3. Run pistudio commands as normal:

```bash
cd /c/Users/YourName/copilot-studio-cli
./bin/pistudio doctor
./bin/pistudio login -p dev
```

### Option 2: Windows Subsystem for Linux (WSL)

For a full Linux environment on Windows:

```bash
# In PowerShell (as Administrator)
wsl --install

# Open Ubuntu/WSL and follow Linux installation steps
cd /mnt/c/Users/YourName/copilot-studio-cli
./bin/pistudio doctor
```

### Option 3: PowerShell (Advanced)

**Not officially supported** — the scripts are designed for Bash. If you must use PowerShell:

1. Install jq (see Prerequisites above)
2. Call the underlying script directly:

```powershell
# Syntax check first
bash -c "./bin/pistudio doctor"

# Most commands require Git Bash or WSL for full compatibility
```

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
pistudio login -p dev

# Check tenant ID matches your Azure AD tenant
pistudio status -p dev
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
