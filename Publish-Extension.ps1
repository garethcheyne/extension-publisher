#Requires -Version 7.2
<#
.SYNOPSIS
  Builds, checks, packages and publishes a browser extension to the Chrome Web
  Store and Microsoft Edge Add-ons. The same script runs locally, in Azure DevOps
  and in GitHub Actions.

.DESCRIPTION
  Mode (default Package):
    Validate  Check the built manifest and store/ listing against both stores' rules.
    Package   Build, zip, and validate. Doesn't touch the stores. Validation errors are reported but don't fail.
    Publish   Package, then upload and submit for review. Any validation error stops it before the upload.
    Status    Show the Chrome Web Store's published and in-review versions.

  The upload itself is done by publish-browser-extension
  (https://github.com/aklinker1/publish-browser-extension), pinned below.

  Settings: non-secret IDs live in store/store.json. Secrets come from the
  environment, or locally from .env.store (git-ignored) in the project, then in
  this toolkit's folder (shared by every extension; see .env.store.example):
    Chrome  CHROME_SERVICE_ACCOUNT_JSON (the key file's contents)
            or CHROME_SERVICE_ACCOUNT_KEY_FILE (its path)
            or CHROME_SERVICE_ACCOUNT_CLIENT_EMAIL + CHROME_SERVICE_ACCOUNT_PRIVATE_KEY
    Edge    EDGE_CLIENT_ID + EDGE_API_KEY

.EXAMPLE
  ./Publish-Extension.ps1 -ProjectPath ../BusinessCentral
  Build and zip, and report anything either store would reject.

.EXAMPLE
  ./Publish-Extension.ps1 -ProjectPath ../BusinessCentral -Mode Publish -Stores edge -NoSubmit
  Upload a draft to Edge only; submit it by hand from Partner Center.

.EXAMPLE
  ./Publish-Extension.ps1 -Mode Publish -ZipPath releases/app-1.2.0.zip
  Publish a zip built earlier (a pipeline's build stage), without rebuilding.
#>
[CmdletBinding()]
param(
    [ValidateSet('Validate', 'Package', 'Publish', 'Status')]
    [string]$Mode = 'Package',

    # The extension's repository root - the folder holding store/store.json.
    [string]$ProjectPath = '.',

    # Defaults to the stores enabled in store.json.
    [ValidateSet('chrome', 'edge')]
    [string[]]$Stores,

    # Publish this zip instead of building one.
    [string]$ZipPath,

    # Zip the existing build output without running the build command.
    [switch]$SkipBuild,

    # Upload the new version as a draft; submit it for review from the dashboard.
    [switch]$NoSubmit,

    # Chrome: hold the approved version until you press Publish in the dashboard.
    [switch]$Staged,

    # Check credentials and settings, but upload nothing.
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/StoreKit.psm1') -Force

$EngineVersion = '6.1.1'
$Project = (Resolve-Path $ProjectPath).Path

function Stop-WithError([string]$Message) {
    switch (Get-CiSystem) {
        'azure' { Write-Host "##vso[task.logissue type=error]$Message" }
        'github' { Write-Host "::error::$Message" }
        default { Write-Host "`n  $Message`n" -ForegroundColor Red }
    }
    exit 1
}

function Write-Step([string]$Text) { Write-Host "`n> $Text" -ForegroundColor Cyan }

try { $config = Get-StoreConfig -ProjectPath $Project } catch { Stop-WithError $_.Exception.Message }
foreach ($source in Import-StoreSecrets -ProjectPath $Project -ToolkitPath $PSScriptRoot) { Write-Host "  loaded $source" -ForegroundColor DarkGray }
# Environment IDs load after .env.store, so re-read them
$config = Get-StoreConfig -ProjectPath $Project

if (-not $Stores) { $Stores = @('chrome', 'edge' | Where-Object { $config.stores[$_].enabled }) }
if (-not $Stores) { Stop-WithError 'No stores selected: pass -Stores, or enable one in store/store.json.' }

Write-Host "`n$($config.name)  |  $Mode  |  $($Stores -join ', ')$(if ($DryRun) { '  |  dry run' })" -ForegroundColor White

# ── Credentials ──
# Resolved into the variable names publish-browser-extension reads, so it is
# only ever handed secrets through the environment - never the command line,
# where any process on the machine (and some CI logs) could see them.

function Resolve-Credentials {
    $engineEnv = @{}
    $missing = @()

    if ('chrome' -in $Stores) {
        $chrome = $config.stores.chrome
        try { $account = Get-ChromeServiceAccount -ProjectPath $Project } catch { Stop-WithError $_.Exception.Message }
        $email = if ($account) { $account.Email }
        $key = if ($account) { $account.PrivateKey }

        if (-not $chrome.extensionId) { $missing += 'Chrome: stores.chrome.extensionId in store.json (or CHROME_EXTENSION_ID)' }
        if (-not $chrome.publisherId) { $missing += 'Chrome: stores.chrome.publisherId in store.json (or CHROME_PUBLISHER_ID)' }
        if (-not ($email -and $key)) { $missing += 'Chrome: a service account - CHROME_SERVICE_ACCOUNT_JSON, CHROME_SERVICE_ACCOUNT_KEY_FILE, or CHROME_SERVICE_ACCOUNT_CLIENT_EMAIL + _PRIVATE_KEY' }

        $engineEnv.CHROME_API_VERSION = 'v2'
        $engineEnv.CHROME_EXTENSION_ID = $chrome.extensionId
        $engineEnv.CHROME_PUBLISHER_ID = $chrome.publisherId
        $engineEnv.CHROME_SERVICE_ACCOUNT_CLIENT_EMAIL = $email
        $engineEnv.CHROME_SERVICE_ACCOUNT_PRIVATE_KEY = $key
        $engineEnv.CHROME_PUBLISH_TYPE = if ($Staged) { 'STAGED_PUBLISH' } else { $chrome.publishType }
        if ($null -ne $chrome.deployPercentage) { $engineEnv.CHROME_DEPLOY_PERCENTAGE = "$($chrome.deployPercentage)" }
        $engineEnv.CHROME_SKIP_SUBMIT_REVIEW = "$([bool]$NoSubmit)".ToLowerInvariant()
    }

    if ('edge' -in $Stores) {
        $edge = $config.stores.edge
        if (-not $edge.productId) { $missing += 'Edge: stores.edge.productId in store.json (or EDGE_PRODUCT_ID)' }
        if (-not $env:EDGE_CLIENT_ID) { $missing += 'Edge: EDGE_CLIENT_ID' }
        if (-not $env:EDGE_API_KEY) { $missing += 'Edge: EDGE_API_KEY' }
        $engineEnv.EDGE_PRODUCT_ID = $edge.productId
        $engineEnv.EDGE_CLIENT_ID = $env:EDGE_CLIENT_ID
        $engineEnv.EDGE_API_KEY = $env:EDGE_API_KEY
        $engineEnv.EDGE_SKIP_SUBMIT_REVIEW = "$([bool]$NoSubmit)".ToLowerInvariant()
    }

    if ($missing) {
        Stop-WithError ("Missing settings:`n    " + ($missing -join "`n    ") + "`n  See the toolkit README, 'One-time store setup'.")
    }
    $engineEnv
}

function Invoke-Engine([hashtable]$EngineEnv, [string[]]$Arguments) {
    $saved = @{}
    foreach ($name in $EngineEnv.Keys) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name, $EngineEnv[$name])
    }
    try {
        # The package is publish-browser-extension; its command is publish-extension
        & npx --yes --package "publish-browser-extension@$EngineVersion" -- publish-extension @Arguments | Out-Host
        $LASTEXITCODE
    } finally {
        foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    }
}

if ($Mode -eq 'Status') {
    if ('chrome' -notin $Stores) { Stop-WithError 'Status is only available for the Chrome Web Store.' }
    $Stores = @('chrome')
    $code = Invoke-Engine (Resolve-Credentials) @('status')
    exit $code
}

# ── Build and package ──

$distDir = Join-Path $Project $config.build.output
$outDir = Join-Path $Project $config.package.outDir

if ($ZipPath) {
    $ZipPath = (Resolve-Path $ZipPath).Path
    Write-Step "Using $ZipPath"
    $manifest = Read-ZipManifest $ZipPath
    $manifestDir = $null
} else {
    # An empty build command means the extension is plain files, zipped as they are
    if ($Mode -ne 'Validate' -and -not $SkipBuild -and $config.build.command) {
        Write-Step "Building: $($config.build.command)"
        Push-Location $Project
        try {
            if ($IsWindows) { & cmd.exe /d /s /c $config.build.command } else { & /bin/sh -c $config.build.command }
            if ($LASTEXITCODE) { Stop-WithError "Build failed (exit $LASTEXITCODE)." }
        } finally { Pop-Location }
    }
    if (-not (Test-Path (Join-Path $distDir 'manifest.json'))) {
        Stop-WithError "No manifest.json in $distDir. Check build.output in store.json, or run without -SkipBuild."
    }
    $manifest = Read-Manifest $distDir
    $manifestDir = $distDir
}

$version = $manifest['version']
Set-CiOutput -Name 'extensionVersion' -Value "$version"

if (-not $ZipPath -and $Mode -ne 'Validate') {
    Write-Step 'Packaging'
    $zip = New-ExtensionZip -SourceDirectory $distDir `
        -Destination (Join-Path $outDir "$($config.name)-$version.zip") `
        -Exclude @($config.package.exclude) `
        -StripManifestKeys @($config.package.stripManifestKeys)
    $ZipPath = $zip.Path
    Write-Host "  $ZipPath  ($($zip.Files) files, $($zip.SizeKB) KB)"
    if ($zip.Stripped) { Write-Host "  removed from the zipped manifest: $($zip.Stripped -join ', ')" -ForegroundColor DarkGray }
}
if ($ZipPath) { Set-CiOutput -Name 'extensionZip' -Value $ZipPath }

# ── Validate ──

Write-Step 'Checking the manifest and store listing'
$findings = @(Test-StoreListing -ProjectPath $Project -Config $config -Manifest $manifest -ManifestDirectory $manifestDir -Stores $Stores `
        -PackagedFiles @(
        if ($ZipPath) { Get-ZipEntryNames $ZipPath }
        else { [IO.Directory]::EnumerateFiles($distDir, '*', 'AllDirectories') | ForEach-Object { $_.Substring($distDir.Length + 1).Replace('\', '/') } }
    ))
$errors = @($findings | Where-Object Level -eq 'Error')
$warnings = @($findings | Where-Object Level -eq 'Warning')
foreach ($finding in $findings) { Write-Finding $finding }
if (-not $findings) { Write-Host '  nothing to fix' -ForegroundColor Green }
else { Write-Host "  $($errors.Count) error(s), $($warnings.Count) warning(s)" }

$summary = @("### $($config.name) $version", '', "Mode: **$Mode** · Stores: $($Stores -join ', ')", '')
if ($ZipPath) { $summary += "Package: ``$(Split-Path $ZipPath -Leaf)``"; $summary += '' }
if ($findings) {
    $summary += '| Level | Store | Finding |', '| --- | --- | --- |'
    $summary += $findings | ForEach-Object { "| $($_.Level) | $($_.Store) | $($_.Message -replace '\|', '\|') |" }
}
Add-CiSummary ($summary -join "`n")

switch ($Mode) {
    'Validate' { exit ([int]($errors.Count -gt 0)) }
    'Package' {
        if ($errors) { Write-Host "`n  Packaged. Fix the errors above before publishing." -ForegroundColor Yellow }
        exit 0
    }
}

# ── Publish ──

if ($errors) { Stop-WithError "Not publishing: $($errors.Count) error(s) above would get the submission rejected." }

$engineEnv = Resolve-Credentials
$arguments = @()
foreach ($store in $Stores) { $arguments += "--$store-zip", $ZipPath }
if ($DryRun) { $arguments += '--dry-run' }

Write-Step ($DryRun ? 'Checking store credentials (dry run)' : ($NoSubmit ? 'Uploading drafts' : 'Uploading and submitting for review'))
$code = Invoke-Engine $engineEnv $arguments
if ($code) { Stop-WithError "Publishing failed (exit $code). The messages above come from the store." }

Write-Host ''
if ($DryRun) { Write-Host '  Credentials work. Nothing was uploaded.' -ForegroundColor Green }
elseif ($NoSubmit) { Write-Host "  $version is uploaded as a draft. Submit it from the dashboard." -ForegroundColor Green }
else { Write-Host "  $version is submitted. It goes live when each store's review passes." -ForegroundColor Green }
Write-Host ''
