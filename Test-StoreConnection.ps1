#Requires -Version 7.2
<#
.SYNOPSIS
  Checks that the store credentials work, and shows what the Chrome Web Store
  has for each extension. Read-only: never uploads or changes anything.

.DESCRIPTION
  Chrome Web Store  Signs in with the service account (read-only scope), then shows
                    each extension's published and in-review versions.
  Edge Add-ons      Checks the API key and client ID are accepted. Edge's API has no
                    read call for a product, so its ID and versions can't be shown;
                    the first upload (-Mode Publish -NoSubmit) is what proves those.

  Neither API can list a publisher's items, so the items checked are the ones in
  each extension's store/store.json. With no extension given, only the credentials
  are checked. Credentials load as for Publish-Extension.ps1: the environment, the
  extension's .env.store, then the toolkit's.

.EXAMPLE
  ./Test-StoreConnection.ps1
  Check the credentials in the toolkit's .env.store.

.EXAMPLE
  ./Test-StoreConnection.ps1 -ProjectPath ../*
  Every extension next to the toolkit that has a store/ folder.
#>
[CmdletBinding()]
param(
    # Extension repos; wildcards allowed. Folders without store/store.json are skipped.
    [string[]]$ProjectPath,

    [ValidateSet('chrome', 'edge')]
    [string[]]$Stores = @('chrome', 'edge')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/StoreKit.psm1') -Force

$projects = @(if ($ProjectPath) {
        Resolve-Path $ProjectPath -ErrorAction SilentlyContinue | ForEach-Object Path |
            Where-Object { Test-Path (Join-Path $_ 'store/store.json') } | Sort-Object -Unique
    })
if ($ProjectPath -and -not $projects) {
    Write-Host "`n  No store/store.json in $($ProjectPath -join ', '); checking the shared credentials only." -ForegroundColor Yellow
}
# No extensions: the toolkit itself stands in, so only its .env.store is read
$targets = if ($projects) { $projects } else { @($PSScriptRoot) }

$script:failures = 0
function Write-Result([string]$Store, [ValidateSet('ok', 'fail', 'note')][string]$Result, [string]$Text) {
    $label, $color = switch ($Result) { 'ok' { 'OK  ', 'Green' } 'fail' { 'FAIL', 'Red' } 'note' { '--  ', 'DarkGray' } }
    Write-Host "  $($Store.PadRight(7)) " -NoNewline
    Write-Host $label -ForegroundColor $color -NoNewline
    Write-Host " $Text"
    if ($Result -eq 'fail') { $script:failures++ }
}

# "1.2.0 (PUBLISHED)", "1.3.0 at 10% (PUBLISHED)", or "none"
function Format-Revision($Revision) {
    if (-not $Revision) { return 'none' }
    $versions = @(Get-Property $Revision 'distributionChannels' | Where-Object { $_ } | ForEach-Object {
            $percent = Get-Property $_ 'deployPercentage'
            "$(Get-Property $_ 'crxVersion')$(if ($null -ne $percent -and $percent -lt 100) { " at $percent%" })"
        })
    "$(if ($versions) { $versions -join ', ' } else { '?' }) ($(Get-Property $Revision 'state'))"
}

foreach ($target in $targets) {
    $saved = Save-StoreSecrets
    try {
        $loaded = @(Import-StoreSecrets -ProjectPath $target -ToolkitPath $PSScriptRoot)
        $config = if ($target -ne $PSScriptRoot) { Get-StoreConfig -ProjectPath $target } else { $null }
        if (-not $config) { $loaded = @($loaded | ForEach-Object { 'the toolkit''s .env.store' }) }
        $source = if ($loaded) { $loaded -join ' + ' } else { 'environment only' }
        Write-Host "`n$(if ($config) { $config.name } else { 'Shared credentials' })  ($source)" -ForegroundColor White

        if ('chrome' -in $Stores) {
            if ($config -and -not $config.stores.chrome.enabled) { Write-Result chrome note 'disabled in store.json' }
            else {
                try {
                    $account = Get-ChromeServiceAccount -ProjectPath $target
                    if (-not $account) { throw 'No service account: set CHROME_SERVICE_ACCOUNT_KEY_FILE or CHROME_SERVICE_ACCOUNT_JSON.' }
                    $token = Get-ChromeAccessToken -Email $account.Email -PrivateKey $account.PrivateKey
                    Write-Result chrome ok "signed in as $($account.Email)"

                    $chrome = if ($config) { $config.stores.chrome } else { $null }
                    if (-not $chrome) { Write-Result chrome note 'give -ProjectPath to see an extension''s status' }
                    elseif (-not ($chrome.extensionId -and $chrome.publisherId)) {
                        Write-Result chrome note 'set stores.chrome.extensionId and publisherId in store.json to see its status'
                    } else {
                        $status = Get-ChromeItemStatus -AccessToken $token -PublisherId $chrome.publisherId -ExtensionId $chrome.extensionId
                        Write-Result chrome ok "$($chrome.extensionId): published $(Format-Revision (Get-Property $status 'publishedItemRevisionStatus'))"
                        $submitted = Get-Property $status 'submittedItemRevisionStatus'
                        if ($submitted) { Write-Result chrome note "submitted $(Format-Revision $submitted)" }
                        $upload = Get-Property $status 'lastAsyncUploadState'
                        if ($upload -and $upload -ne 'SUCCEEDED') { Write-Result chrome note "last upload: $upload" }
                        if (Get-Property $status 'takenDown') { Write-Result chrome fail 'the item has been taken down' }
                        elseif (Get-Property $status 'warned') { Write-Result chrome note 'the item has a policy warning; see the Developer Dashboard' }
                    }
                } catch { Write-Result chrome fail $_.Exception.Message }
            }
        }

        if ('edge' -in $Stores) {
            if ($config -and -not $config.stores.edge.enabled) { Write-Result edge note 'disabled in store.json' }
            elseif (-not ($env:EDGE_CLIENT_ID -and $env:EDGE_API_KEY)) { Write-Result edge fail 'No API credentials: set EDGE_CLIENT_ID and EDGE_API_KEY.' }
            else {
                try {
                    $productId = if ($config) { $config.stores.edge.productId } else { '' }
                    $result = Test-EdgeCredentials -ClientId $env:EDGE_CLIENT_ID -ApiKey $env:EDGE_API_KEY -ProductId $productId
                    if ($result.Accepted) {
                        Write-Result edge ok "API key accepted for client $($env:EDGE_CLIENT_ID.Substring(0, [Math]::Min(8, $env:EDGE_CLIENT_ID.Length)))…"
                        if ($config -and -not $productId) { Write-Result edge note 'set stores.edge.productId in store.json before publishing' }
                    } else {
                        Write-Result edge fail "API key rejected ($($result.StatusCode)). Check EDGE_CLIENT_ID and EDGE_API_KEY; keys expire, so create a new one in Partner Center → Publish API if it has."
                    }
                } catch { Write-Result edge fail $_.Exception.Message }
            }
        }
    } finally { Restore-StoreSecrets $saved }
}

Write-Host ''
if ($script:failures) { Write-Host "  $($script:failures) check(s) failed.`n" -ForegroundColor Red; exit 1 }
Write-Host "  Everything connects.`n" -ForegroundColor Green
