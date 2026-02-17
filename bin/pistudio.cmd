@echo off
REM pistudio.cmd - Windows batch wrapper
REM Delegates to pistudio.ps1 which finds Git Bash and runs the real CLI.
REM Works from cmd.exe, PowerShell, and Windows Terminal.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0pistudio.ps1" %*
