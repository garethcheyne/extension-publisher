#Requires -Version 7.2
<#
.SYNOPSIS
  Adds a store/ folder to an extension project: store.json, listing text,
  privacy answers, reviewer notes and image slots, ready to fill in.

.DESCRIPTION
  Never overwrites a file that already exists, so it is safe to run again -
  e.g. after adding a permission, to get a section for it in permissions.md.

.EXAMPLE
  ./New-StoreListing.ps1 -ProjectPath ../BusinessCentral
#>
[CmdletBinding()]
param(
    [string]$ProjectPath = '.',
    # Defaults to the first manifest.json found in the build output, public/, src/ or the root.
    [string]$ManifestPath,
    [string]$BuildCommand,
    [string]$BuildOutput
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/StoreKit.psm1') -Force

$Project = (Resolve-Path $ProjectPath).Path
$store = Join-Path $Project 'store'
$templates = Join-Path $PSScriptRoot 'templates/store'
$created = [System.Collections.Generic.List[string]]::new()

function Write-New([string]$Path, [string]$Content) {
    if (Test-Path $Path) { return }
    New-Item -ItemType Directory -Force -Path (Split-Path $Path) | Out-Null
    Set-Content -Path $Path -Value $Content -NoNewline
    $created.Add($Path.Substring($Project.Length + 1).Replace('\', '/'))
}

# ── Work out the project ──

$package = if (Test-Path (Join-Path $Project 'package.json')) { Get-Content (Join-Path $Project 'package.json') -Raw | ConvertFrom-Json -AsHashtable } else { @{} }
$name = if ($package['name']) { $package['name'] -replace '^@[^/]+/', '' } else { (Split-Path $Project -Leaf).ToLowerInvariant() }
if (-not $BuildCommand) { $BuildCommand = if ($package['scripts'] -and $package['scripts']['build']) { 'npm run build' } else { '' } }
if (-not $BuildOutput) {
    # No build step and the manifest at the root: the repo itself is the extension
    $BuildOutput = if (-not $BuildCommand -and (Test-Path (Join-Path $Project 'manifest.json'))) { '.' } else { 'dist' }
}

if (-not $ManifestPath) {
    $ManifestPath = @("$BuildOutput/manifest.json", 'public/manifest.json', 'src/manifest.json', 'manifest.json') |
        ForEach-Object { Join-Path $Project $_ } | Where-Object { Test-Path $_ } | Select-Object -First 1
}
$manifest = if ($ManifestPath) { Get-Content $ManifestPath -Raw | ConvertFrom-Json -AsHashtable } else { $null }
if (-not $manifest) { Write-Warning 'No manifest.json found - permissions.md will be empty. Build first, or pass -ManifestPath.' }

# ── store.json ──

$config = [ordered]@{
    name    = $name
    build   = [ordered]@{ command = $BuildCommand; output = $BuildOutput }
    package = [ordered]@{
        outDir            = 'releases'
        exclude           = $BuildOutput -eq '.' ? @('*.map', 'store/*', 'releases/*', '*.md', 'package*.json') : @('*.map')
        stripManifestKeys = @('key', 'update_url')
    }
    listing = [ordered]@{ defaultLocale = 'en'; privacyPolicyUrl = ''; homepageUrl = ''; supportUrl = ''; category = '' }
    stores  = [ordered]@{
        chrome = [ordered]@{ enabled = $true; extensionId = ''; publisherId = ''; publishType = 'DEFAULT_PUBLISH' }
        edge   = [ordered]@{ enabled = $true; productId = '' }
    }
}
Write-New (Join-Path $store 'store.json') (($config | ConvertTo-Json -Depth 10) + "`n")

# ── Templates ──

foreach ($file in [System.IO.Directory]::EnumerateFiles($templates, '*', 'AllDirectories')) {
    $relative = $file.Substring($templates.Length + 1)
    Write-New (Join-Path $store $relative) (Get-Content $file -Raw)
}

# ── permissions.md, from the manifest ──
# Hints only - each section still says TODO, because the justification has to
# describe what this extension does with the permission, not what it is.

$hints = @{
    'activeTab'        = 'Which user action (click, shortcut, menu) grants access to the current tab, and what is done with it.'
    'alarms'           = 'What runs on a schedule, and how often.'
    'bookmarks'        = 'Which bookmarks are read or changed, and why.'
    'clipboardWrite'   = 'What is copied, and on which user action.'
    'contextMenus'     = 'Which menu items are added, and where they appear.'
    'cookies'          = 'Which sites'' cookies are read, and why an API call alone is not enough.'
    'downloads'        = 'What is downloaded, and on which user action.'
    'history'          = 'What history is read, and why.'
    'identity'         = 'Which account is signed in to, and what the token is used for.'
    'notifications'    = 'What the user is notified about.'
    'offscreen'        = 'What the offscreen document does that the service worker cannot.'
    'scripting'        = 'What is injected, into which pages, and on what trigger.'
    'sidePanel'        = 'What the side panel shows.'
    'storage'          = 'What is stored (settings, cache), and that it stays in the browser.'
    'tabs'             = 'Which tab fields (URL, title) are read, and why activeTab is not enough.'
    'webRequest'       = 'Which requests are observed, and why.'
    'host permissions' = 'Each site the extension runs on or calls, and what it does there. Broad patterns (<all_urls>, *://*/*) get the closest review.'
}

$permFile = Join-Path $store 'privacy/permissions.md'
$permissions = @(if ($manifest) { Get-ManifestPermissions $manifest })
$existing = Get-MarkdownSections $permFile
$missing = @($permissions | Where-Object { -not $existing.ContainsKey($_) })

$section = {
    param($permission)
    $hint = $hints[$permission] ?? 'What the extension does with it, and why it cannot work without it.'
    $detail = ''
    if ($permission -eq 'host permissions' -and $manifest) {
        $hosts = @($manifest['host_permissions']) + @($manifest['content_scripts'] | Where-Object { $_ } | ForEach-Object { $_['matches'] }) |
            Where-Object { $_ } | Sort-Object -Unique
        if ($hosts) { $detail = "`n" + (($hosts | ForEach-Object { "- ``$_``" }) -join "`n") + "`n" }
    }
    "## $permission`n$detail`nTODO: $hint`n"
}

if (-not (Test-Path $permFile)) {
    $body = @(
        '# Permission justifications', '',
        'Chrome Web Store → Privacy → **Permission justification**: one box per permission.',
        'Every `## heading` must match a permission in the manifest; the publish script checks both ways.', ''
    ) -join "`n"
    $body += "`n" + (($permissions | ForEach-Object { & $section $_ }) -join "`n")
    Write-New $permFile $body
} elseif ($missing) {
    Add-Content -Path $permFile -Value ("`n" + (($missing | ForEach-Object { & $section $_ }) -join "`n"))
    $created.Add("store/privacy/permissions.md (added: $($missing -join ', '))")
}

# ── Store icon, from the manifest's own ──

$icon = if ($manifest -and $manifest['icons']) { $manifest['icons']['128'] } else { $null }
$iconTarget = Join-Path $store 'images/icon-128.png'
if ($icon -and -not (Test-Path $iconTarget)) {
    $source = @((Join-Path (Split-Path $ManifestPath) $icon), (Join-Path $Project "public/$icon")) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($source -and (Format-Size (Get-ImageSize $source)) -eq '128x128') {
        Copy-Item $source $iconTarget
        $created.Add('store/images/icon-128.png (copied from the manifest icon)')
    }
}

# ── Keep local secrets out of git ──

$gitignore = Join-Path $Project '.gitignore'
$ignored = (Test-Path $gitignore) -and (Select-String -Path $gitignore -Pattern '^\s*/?\.env\.store\s*$' -Quiet)
if (-not $ignored) {
    Add-Content -Path $gitignore -Value "`n# Store publishing secrets (extension-publisher)`n.env.store`n*.service-account.json"
    $created.Add('.gitignore (added .env.store)')
}

# ── Report ──

Write-Host "`nstore/ for $name" -ForegroundColor White
if ($created) { $created | ForEach-Object { Write-Host "  + $_" -ForegroundColor Green } }
else { Write-Host '  nothing to add - everything is already there' }
Write-Host @"

Next:
  1. Check build.command and build.output in store/store.json.
  2. Fill in everything marked TODO, and add the images listed in store/README.md.
  3. See what's left:  ./Publish-Extension.ps1 -ProjectPath '$ProjectPath'

"@
