#Requires -Version 7.2
<#
.SYNOPSIS
  Creates a new extension project from templates/extension: Vite, React,
  TypeScript, Tailwind CSS and shadcn/ui, with a side panel and a service worker,
  and a store/ folder ready for publishing.

.DESCRIPTION
  Copies the template, fills in the name and description, runs npm install, then
  runs New-StoreListing.ps1 so the project can go straight through
  Publish-Extension.ps1. Refuses to write into a folder that isn't empty.

.EXAMPLE
  ./New-Extension.ps1 -Path ../TabNotes -Name 'Tab Notes' -Description 'Keep notes next to any page in the side panel.'
#>
[CmdletBinding()]
param(
    # The new project's folder. Must not exist yet, or be empty.
    [Parameter(Mandatory)][string]$Path,
    # Shown in the toolbar, the side panel title and the stores. Defaults to the folder name.
    [string]$Name,
    # The manifest description: one sentence, 132 characters at most (Chrome's limit).
    [Parameter(Mandatory)][ValidateLength(1, 132)][string]$Description,
    # Skip npm install, e.g. to use pnpm or bun instead.
    [switch]$SkipInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$template = Join-Path $PSScriptRoot 'templates/extension'
$Project = [System.IO.Path]::GetFullPath($Path, (Get-Location).Path)
if ((Test-Path $Project) -and (Get-ChildItem $Project -Force | Select-Object -First 1)) {
    throw "$Project isn't empty. Choose a new folder."
}
if (-not $Name) { $Name = Split-Path $Project -Leaf }
if ($Name.Length -gt 75) { throw "Name is $($Name.Length) characters; Chrome allows 75." }

# npm package name: lowercase, dashes only
$packageName = ($Name.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
if (-not $packageName) { throw "Can't make a package name from '$Name'. Use letters or digits." }

# The package.json store scripts call this toolkit by a path relative to the project
# when the two are close (e.g. ../extension-publisher), otherwise by its full path
$toolkit = [System.IO.Path]::GetRelativePath($Project, $PSScriptRoot).Replace('\', '/')
if (([regex]::Matches($toolkit, '\.\./')).Count -gt 2) { $toolkit = $PSScriptRoot.Replace('\', '/') }
if ($toolkit -match '\s') { $toolkit = "`"$toolkit`"" }

$tokens = [ordered]@{ name = $packageName; displayName = $Name; description = $Description; toolkit = $toolkit }

function Expand-Tokens([string]$Text, [string]$Extension) {
    foreach ($key in $tokens.Keys) {
        $value = switch ($Extension) {
            '.json' { $json = ConvertTo-Json $tokens[$key]; $json.Substring(1, $json.Length - 2) }   # escaped, without the outer quotes
            '.html' { [System.Net.WebUtility]::HtmlEncode($tokens[$key]) }
            default { $tokens[$key] }
        }
        $Text = $Text.Replace("{{$key}}", $value)
    }
    $Text
}

# ── Copy the template ──

$textExtensions = '.json', '.html', '.ts', '.tsx', '.css', '.js', '.md', ''
New-Item -ItemType Directory -Force -Path $Project | Out-Null
foreach ($file in [System.IO.Directory]::EnumerateFiles($template, '*', 'AllDirectories')) {
    $relative = $file.Substring($template.Length + 1)
    if ($relative -match '^(node_modules|dist|releases)[\\/]') { continue }
    $target = Join-Path $Project $relative
    New-Item -ItemType Directory -Force -Path (Split-Path $target) | Out-Null
    $extension = [System.IO.Path]::GetExtension($file)
    if ($extension -in $textExtensions) {
        Set-Content -Path $target -Value (Expand-Tokens (Get-Content $file -Raw) $extension) -NoNewline
    }
    else {
        Copy-Item $file $target
    }
}
Write-Host "Created $Name in $Project" -ForegroundColor Green

# ── Install, then add store/ ──

if (-not $SkipInstall) {
    Push-Location $Project
    try {
        npm install
        if ($LASTEXITCODE) { throw "npm install failed (exit $LASTEXITCODE)." }
    }
    finally { Pop-Location }
}

& (Join-Path $PSScriptRoot 'New-StoreListing.ps1') -ProjectPath $Project

Write-Host @"
Develop:
  cd '$Path'$(if ($SkipInstall) { "`n  npm install" })
  npm run dev          then load dist/ in chrome://extensions or edge://extensions (Developer mode → Load unpacked)
  npx shadcn@latest add dialog tabs …   to add components

Publish:
  npm run store        build, zip and check against both stores' rules
  First release: see "First release of a new extension" in the extension-publisher README.

"@
