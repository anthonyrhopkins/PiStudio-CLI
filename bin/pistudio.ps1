<#
.SYNOPSIS
    PowerShell shim for pistudio — delegates to Git Bash's bash.exe.

.DESCRIPTION
    Allows running pistudio from PowerShell or Windows Terminal without
    WSL. Requires Git for Windows (provides bash.exe).

.EXAMPLE
    pistudio doctor
    pistudio envs -p dev
    pistudio login -p dev --device-code
#>

param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Arguments
)

$ErrorActionPreference = 'Stop'

# ─── Locate bash.exe from Git for Windows ─────────────────────
function Find-GitBash {
    # 1. Check PATH first
    $inPath = Get-Command bash.exe -ErrorAction SilentlyContinue
    if ($inPath -and $inPath.Source -match 'Git') {
        return $inPath.Source
    }

    # 2. Common install locations
    $candidates = @(
        "$env:ProgramFiles\Git\bin\bash.exe",
        "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
        "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe",
        "C:\Git\bin\bash.exe"
    )

    foreach ($path in $candidates) {
        if (Test-Path $path) {
            return $path
        }
    }

    # 3. Check registry (user + machine installs)
    $regPaths = @(
        'HKLM:\SOFTWARE\GitForWindows',
        'HKCU:\SOFTWARE\GitForWindows'
    )
    foreach ($reg in $regPaths) {
        try {
            $installPath = (Get-ItemProperty $reg -ErrorAction SilentlyContinue).InstallPath
            if ($installPath) {
                $bash = Join-Path $installPath 'bin\bash.exe'
                if (Test-Path $bash) { return $bash }
            }
        } catch {}
    }

    return $null
}

# ─── Resolve script paths ─────────────────────────────────────
$shimDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$repoRoot = Split-Path -Parent $shimDir

# ─── Find bash ─────────────────────────────────────────────────
$bash = Find-GitBash

if (-not $bash) {
    Write-Host ""
    Write-Host "ERROR: Git Bash not found." -ForegroundColor Red
    Write-Host ""
    Write-Host "pistudio requires Git for Windows (provides bash.exe)." -ForegroundColor Yellow
    Write-Host "Install from: https://git-scm.com/download/win" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Alternatively, use WSL:" -ForegroundColor Yellow
    Write-Host "  wsl ~/copilot-studio-cli/bin/pistudio $Arguments" -ForegroundColor Gray
    Write-Host ""
    exit 1
}

# ─── Convert Windows path to Git Bash path ─────────────────────
function ConvertTo-BashPath {
    param([string]$WinPath)
    $resolved = (Resolve-Path $WinPath).Path
    # C:\Users\foo\bar -> /c/Users/foo/bar
    if ($resolved -match '^([A-Za-z]):\\(.*)$') {
        $drive = $Matches[1].ToLower()
        $rest = $Matches[2] -replace '\\', '/'
        return "/$drive/$rest"
    }
    return $resolved -replace '\\', '/'
}

$bashScript = ConvertTo-BashPath (Join-Path $repoRoot 'bin' 'pistudio')

# ─── Execute ───────────────────────────────────────────────────
# Pass all arguments through. Use --login so bash reads profiles.
$escapedArgs = $Arguments | ForEach-Object {
    # Escape single quotes for bash
    $_ -replace "'", "'\\''"
}
$argString = ($escapedArgs | ForEach-Object { "'$_'" }) -join ' '

# Run the script directly (not sourced) so BASH_SOURCE resolves correctly
& $bash --login -c "'$bashScript' $argString"
exit $LASTEXITCODE
