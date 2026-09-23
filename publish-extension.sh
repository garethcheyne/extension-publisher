#!/usr/bin/env sh
# Bash/sh entry point - the work is done by Publish-Extension.ps1 (PowerShell 7,
# which runs on Linux and macOS too: https://aka.ms/powershell).
#   ./publish-extension.sh -ProjectPath ../my-extension -Mode Publish
set -e
exec pwsh -NoProfile -File "$(dirname "$0")/Publish-Extension.ps1" "$@"
