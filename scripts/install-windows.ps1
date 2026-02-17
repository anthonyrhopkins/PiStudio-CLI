<#
.SYNOPSIS
    Automated Windows installation for PiStudio CLI

.DESCRIPTION
    This script automates the Windows setup:
    - Verifies Git for Windows is installed
    - Downloads jq.exe if missing
    - Creates PowerShell profile with pistudio alias
    - Creates config file from template
    - Runs doctor to verify installation

.EXAMPLE
    # Run from PowerShell (may require execution policy bypass)
    powershell -ExecutionPolicy Bypass -File scripts/install-windows.ps1

.NOTES
    Requires: Git for Windows (https://git-scm.com/download/win)
#>

param(
    [switch]$SkipJq,
    [switch]$SkipProfile,
    [switch]$SkipConfig
)

$ErrorActionPreference = 'Stop'

Write-Host ""
Write-Host "======================================" -ForegroundColor Cyan
Write-Host " PiStudio CLI - Windows Installation" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan
Write-Host ""

# ─── 1. Verify Git for Windows ────────────────────────────────
Write-Host "[1/5] Checking for Git for Windows..." -ForegroundColor Yellow

$gitBash = $null
$candidates = @(
    "$env:ProgramFiles\Git\bin\bash.exe",
    "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
    "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe"
)

foreach ($path in $candidates) {
    if (Test-Path $path) {
        $gitBash = $path
        break
    }
}

if (-not $gitBash) {
    Write-Host "  [✗] Git for Windows not found" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Please install from: https://git-scm.com/download/win" -ForegroundColor Yellow
    Write-Host ""
    exit 1
}

Write-Host "  [✓] Found: $gitBash" -ForegroundColor Green

# ─── 2. Download jq.exe ───────────────────────────────────────
if (-not $SkipJq) {
    Write-Host ""
    Write-Host "[2/5] Checking for jq..." -ForegroundColor Yellow

    $repoRoot = Split-Path -Parent $PSScriptRoot
    $jqPath = Join-Path $repoRoot 'bin\jq.exe'

    if (Test-Path $jqPath) {
        Write-Host "  [✓] jq already installed: $jqPath" -ForegroundColor Green
    } else {
        Write-Host "  [→] Downloading jq v1.7.1..." -ForegroundColor Cyan

        try {
            $jqUrl = 'https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-windows-amd64.exe'
            Invoke-WebRequest -Uri $jqUrl -OutFile $jqPath -UseBasicParsing

            # Test it works
            $version = & $jqPath --version 2>&1
            Write-Host "  [✓] Downloaded: $version" -ForegroundColor Green
        } catch {
            Write-Host "  [✗] Failed to download jq: $_" -ForegroundColor Red
            Write-Host "  [→] You can install manually via Chocolatey: choco install jq" -ForegroundColor Yellow
        }
    }
} else {
    Write-Host ""
    Write-Host "[2/5] Skipping jq download (--SkipJq)" -ForegroundColor Gray
}

# ─── 3. Create PowerShell Profile ─────────────────────────────
if (-not $SkipProfile) {
    Write-Host ""
    Write-Host "[3/5] Setting up PowerShell profile..." -ForegroundColor Yellow

    $profileDir = Split-Path $PROFILE
    $repoRoot = Split-Path -Parent $PSScriptRoot

    if (-not (Test-Path $profileDir)) {
        New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
        Write-Host "  [✓] Created profile directory: $profileDir" -ForegroundColor Green
    }

    $aliasLine = "function pistudio { & `"$repoRoot\bin\pistudio.ps1`" @args }"

    if (Test-Path $PROFILE) {
        $content = Get-Content $PROFILE -Raw
        if ($content -match 'function pistudio') {
            Write-Host "  [→] pistudio alias already exists in profile" -ForegroundColor Cyan
        } else {
            Add-Content $PROFILE "`n# PiStudio CLI alias`n$aliasLine"
            Write-Host "  [✓] Added pistudio alias to: $PROFILE" -ForegroundColor Green
        }
    } else {
        "# PiStudio CLI alias`n$aliasLine" | Set-Content $PROFILE
        Write-Host "  [✓] Created profile with pistudio alias: $PROFILE" -ForegroundColor Green
    }
} else {
    Write-Host ""
    Write-Host "[3/5] Skipping profile setup (--SkipProfile)" -ForegroundColor Gray
}

# ─── 4. Create Config File ────────────────────────────────────
if (-not $SkipConfig) {
    Write-Host ""
    Write-Host "[4/5] Creating config file..." -ForegroundColor Yellow

    $repoRoot = Split-Path -Parent $PSScriptRoot
    $configPath = Join-Path $repoRoot 'config\copilot-export.json'
    $examplePath = Join-Path $repoRoot 'config\copilot-export.example.json'

    if (Test-Path $configPath) {
        Write-Host "  [→] Config already exists: $configPath" -ForegroundColor Cyan
    } else {
        Copy-Item $examplePath $configPath
        Write-Host "  [✓] Created config: $configPath" -ForegroundColor Green
        Write-Host "  [!] Remember to edit with your real values" -ForegroundColor Yellow
    }
} else {
    Write-Host ""
    Write-Host "[4/5] Skipping config creation (--SkipConfig)" -ForegroundColor Gray
}

# ─── 5. Run Doctor ────────────────────────────────────────────
Write-Host ""
Write-Host "[5/5] Running pistudio doctor..." -ForegroundColor Yellow
Write-Host ""

$repoRoot = Split-Path -Parent $PSScriptRoot
$shimPath = Join-Path $repoRoot 'bin\pistudio.ps1'

try {
    & $shimPath doctor

    Write-Host ""
    Write-Host "======================================" -ForegroundColor Green
    Write-Host " Installation Complete!" -ForegroundColor Green
    Write-Host "======================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor Cyan
    Write-Host "  1. Edit config: $repoRoot\config\copilot-export.json" -ForegroundColor White
    Write-Host "  2. Restart PowerShell to load the pistudio alias" -ForegroundColor White
    Write-Host "  3. Run: pistudio login -p dev" -ForegroundColor White
    Write-Host "  4. Run: pistudio doctor -p dev" -ForegroundColor White
    Write-Host ""
    Write-Host "Troubleshooting:" -ForegroundColor Yellow
    Write-Host "  - If 'pistudio' not found: Close and reopen PowerShell" -ForegroundColor White
    Write-Host "  - If jq errors persist: Check bin\jq.exe exists and is v1.7.1+" -ForegroundColor White
    Write-Host "  - For AI agents: See docs/WINDOWS-GOTCHAS.md" -ForegroundColor White
    Write-Host ""
} catch {
    Write-Host ""
    Write-Host "  [✗] Doctor failed: $_" -ForegroundColor Red
    Write-Host ""
    Write-Host "  This is normal if config isn't set up yet." -ForegroundColor Yellow
    Write-Host "  Edit the config file and run 'pistudio doctor' manually." -ForegroundColor Yellow
    Write-Host ""
}
