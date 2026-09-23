#Requires -Version 7.2
<#
  Shared functions for Publish-Extension.ps1, New-StoreListing.ps1 and Test-StoreConnection.ps1.

  Everything here is store knowledge (sizes, limits, which store needs what) or
  plumbing (config, zip, CI logging). Uploading is not done here - that is
  publish-browser-extension's job, called from Publish-Extension.ps1.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Store rules ──
# Sources, checked 2026-09:
#   https://developer.chrome.com/docs/webstore/images
#   https://learn.microsoft.com/microsoft-edge/extensions/publish/publish-extension
$script:Rules = @{
    ManifestNameMax        = 75
    ManifestDescriptionMax = 132
    ChromeScreenshotSizes  = @('1280x800', '640x400')
    ChromeScreenshotMax    = 5
    EdgeScreenshotSizes    = @('1280x800', '640x480')
    EdgeScreenshotMax      = 6
    EdgeDescriptionMin     = 250
    EdgeDescriptionMax     = 10000
}

function Get-StoreRules { $script:Rules }

# ── Config ──

<#
  Reads store/store.json and fills in defaults, so callers never have to test
  whether a key exists. Non-secret IDs can be overridden from the environment,
  which lets one pipeline template serve a test and a production listing.
#>
function Get-StoreConfig {
    param([Parameter(Mandatory)][string]$ProjectPath)

    $path = Join-Path $ProjectPath 'store/store.json'
    if (-not (Test-Path $path)) {
        throw "No store/store.json in $ProjectPath. Run New-StoreListing.ps1 -ProjectPath '$ProjectPath' first."
    }
    $raw = Get-Content $path -Raw | ConvertFrom-Json -AsHashtable

    $defaults = [ordered]@{
        name    = (Split-Path $ProjectPath -Leaf).ToLowerInvariant()
        build   = @{ command = 'npm run build'; output = 'dist' }
        package = @{ outDir = 'releases'; exclude = @(); stripManifestKeys = @('key', 'update_url') }
        listing = @{ defaultLocale = 'en'; privacyPolicyUrl = ''; homepageUrl = ''; supportUrl = '' }
        stores  = @{
            chrome = @{ enabled = $true; extensionId = ''; publisherId = ''; publishType = 'DEFAULT_PUBLISH'; deployPercentage = $null }
            edge   = @{ enabled = $true; productId = '' }
        }
    }
    $config = Merge-Hashtable $defaults $raw

    foreach ($pair in @(
            @('chrome', 'extensionId', 'CHROME_EXTENSION_ID'),
            @('chrome', 'publisherId', 'CHROME_PUBLISHER_ID'),
            @('edge', 'productId', 'EDGE_PRODUCT_ID'))) {
        $value = [Environment]::GetEnvironmentVariable($pair[2])
        if ($value) { $config.stores[$pair[0]][$pair[1]] = $value }
    }
    $config
}

function Merge-Hashtable {
    param($Base, $Override)
    $result = [ordered]@{}
    foreach ($key in $Base.Keys) { $result[$key] = $Base[$key] }
    foreach ($key in $Override.Keys) {
        if ($key -eq '$schema') { continue }
        $b = $result[$key]
        $o = $Override[$key]
        $result[$key] = if ($b -is [System.Collections.IDictionary] -and $o -is [System.Collections.IDictionary]) { Merge-Hashtable $b $o } else { $o }
    }
    $result
}

<#
  KEY=value lines, for local runs only (CI passes real environment variables).
  Values already in the environment win, so a pipeline can never be overridden
  by a stray file in the repo.
#>
function Import-DotEnv {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { return $false }
    foreach ($line in Get-Content $Path) {
        if ($line -match '^\s*(#|$)') { continue }
        if ($line -notmatch '^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') { continue }
        $name = $Matches[1]
        $value = $Matches[2].Trim()
        if ($value -match '^"(.*)"$' -or $value -match "^'(.*)'$") { $value = $Matches[1] }
        if (-not [Environment]::GetEnvironmentVariable($name)) {
            [Environment]::SetEnvironmentVariable($name, $value)
        }
    }
    $true
}

$script:SecretNames = @('CHROME_SERVICE_ACCOUNT_JSON', 'CHROME_SERVICE_ACCOUNT_KEY_FILE', 'CHROME_SERVICE_ACCOUNT_CLIENT_EMAIL',
    'CHROME_SERVICE_ACCOUNT_PRIVATE_KEY', 'CHROME_EXTENSION_ID', 'CHROME_PUBLISHER_ID', 'EDGE_CLIENT_ID', 'EDGE_API_KEY', 'EDGE_PRODUCT_ID')

<#
  Loads store secrets for a project into the environment: the project's
  .env.store, then the toolkit's (shared by every extension). Earlier sources
  win, and real environment variables win over both. Returns what was loaded.
#>
function Import-StoreSecrets {
    param([Parameter(Mandatory)][string]$ProjectPath, [Parameter(Mandatory)][string]$ToolkitPath)
    # Azure DevOps passes an undefined variable through as the literal "$(NAME)"
    foreach ($name in $script:SecretNames) {
        if ([Environment]::GetEnvironmentVariable($name) -match '^\$\(.+\)$') { [Environment]::SetEnvironmentVariable($name, $null) }
    }
    $loaded = @()
    if (Import-DotEnv (Join-Path $ProjectPath '.env.store')) { $loaded += '.env.store' }
    $hadKeyFile = [bool]$env:CHROME_SERVICE_ACCOUNT_KEY_FILE
    if ($ToolkitPath -ne $ProjectPath -and (Import-DotEnv (Join-Path $ToolkitPath '.env.store'))) {
        $loaded += 'the toolkit''s .env.store'
        # A relative key file path in it means relative to the toolkit, not the project
        $file = $env:CHROME_SERVICE_ACCOUNT_KEY_FILE
        if (-not $hadKeyFile -and $file -and -not [IO.Path]::IsPathRooted($file)) { $env:CHROME_SERVICE_ACCOUNT_KEY_FILE = Join-Path $ToolkitPath $file }
    }
    $loaded
}

<# The store secret variables' current values, to put back with Restore-StoreSecrets. #>
function Save-StoreSecrets {
    $saved = @{}
    foreach ($name in $script:SecretNames) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
    $saved
}

function Restore-StoreSecrets {
    param([Parameter(Mandatory)][hashtable]$Saved)
    foreach ($name in $Saved.Keys) { [Environment]::SetEnvironmentVariable($name, $Saved[$name]) }
}

<#
  The Chrome service account from the environment, as @{ Email; PrivateKey }, or
  $null when none is set. Accepts the key file's contents, its path (relative to
  the project), or the two fields separately.
#>
function Get-ChromeServiceAccount {
    param([Parameter(Mandatory)][string]$ProjectPath)
    $email = $env:CHROME_SERVICE_ACCOUNT_CLIENT_EMAIL
    $key = $env:CHROME_SERVICE_ACCOUNT_PRIVATE_KEY
    $json = $env:CHROME_SERVICE_ACCOUNT_JSON
    if (-not $json -and $env:CHROME_SERVICE_ACCOUNT_KEY_FILE) {
        $file = $env:CHROME_SERVICE_ACCOUNT_KEY_FILE
        if (-not [IO.Path]::IsPathRooted($file)) { $file = Join-Path $ProjectPath $file }
        if (-not (Test-Path $file)) { throw "CHROME_SERVICE_ACCOUNT_KEY_FILE points at $file, which doesn't exist." }
        $json = Get-Content $file -Raw
    }
    if ($json) {
        $account = $json | ConvertFrom-Json
        $email = $account.client_email
        $key = $account.private_key
    }
    if (-not ($email -and $key)) { return $null }
    # A key pasted into a single-line secret arrives with literal \n
    @{ Email = $email; PrivateKey = ($key -replace '\\n', "`n") }
}

# ── Store APIs (read-only checks) ──

<# Parsed JSON, or $null for an empty or non-JSON body. #>
function ConvertFrom-JsonOrNull {
    param([string]$Text)
    if (-not $Text) { return $null }
    try { $Text | ConvertFrom-Json } catch { $null }
}

<# A dotted path ("error.message") into parsed JSON; $null where anything is missing, even under strict mode. #>
function Get-Property {
    param($Object, [Parameter(Mandatory)][string]$Path)
    foreach ($name in $Path.Split('.')) {
        if ($null -eq $Object) { return $null }
        $property = $Object.PSObject.Properties[$name]
        $Object = if ($property) { $property.Value } else { $null }
    }
    $Object
}
# Uploading is publish-browser-extension's job. These only prove the credentials
# work and read what the stores will say, for Test-StoreConnection.ps1.

<# Signs a service account JWT and exchanges it for an OAuth access token. #>
function Get-ChromeAccessToken {
    param(
        [Parameter(Mandatory)][string]$Email,
        [Parameter(Mandatory)][string]$PrivateKey,
        [string]$Scope = 'https://www.googleapis.com/auth/chromewebstore.readonly'
    )
    $base64Url = { param([byte[]]$Bytes) [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_') }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $header = & $base64Url ([Text.Encoding]::UTF8.GetBytes('{"alg":"RS256","typ":"JWT"}'))
    $claims = & $base64Url ([Text.Encoding]::UTF8.GetBytes((
                [ordered]@{ iss = $Email; scope = $Scope; aud = 'https://oauth2.googleapis.com/token'; iat = $now; exp = $now + 300 } | ConvertTo-Json -Compress)))
    $rsa = [Security.Cryptography.RSA]::Create()
    try {
        $rsa.ImportFromPem($PrivateKey)
        $signature = & $base64Url ($rsa.SignData([Text.Encoding]::ASCII.GetBytes("$header.$claims"),
                [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1))
    } finally { $rsa.Dispose() }

    $response = Invoke-WebRequest -Method Post -Uri 'https://oauth2.googleapis.com/token' -SkipHttpErrorCheck -Body @{
        grant_type = 'urn:ietf:params:oauth:grant-type:jwt-bearer'
        assertion  = "$header.$claims.$signature"
    }
    $body = ConvertFrom-JsonOrNull $response.Content
    $token = Get-Property $body 'access_token'
    if ($response.StatusCode -ne 200 -or -not $token) {
        throw "Google refused the service account ($($response.StatusCode)): $((Get-Property $body 'error_description') ?? (Get-Property $body 'error') ?? $response.Content)"
    }
    $token
}

<# Chrome Web Store API v2 fetchStatus: the published and in-review revisions of one item. #>
function Get-ChromeItemStatus {
    param([Parameter(Mandatory)][string]$AccessToken, [Parameter(Mandatory)][string]$PublisherId, [Parameter(Mandatory)][string]$ExtensionId)
    $response = Invoke-WebRequest -Uri "https://chromewebstore.googleapis.com/v2/publishers/$PublisherId/items/${ExtensionId}:fetchStatus" `
        -Headers @{ Authorization = "Bearer $AccessToken" } -SkipHttpErrorCheck
    $body = ConvertFrom-JsonOrNull $response.Content
    if ($response.StatusCode -ne 200) {
        $hint = switch ($response.StatusCode) {
            { $_ -in 403, 404 } { ' Check stores.chrome.extensionId and publisherId in store.json, and that the service account is added under Developer Dashboard → Account.' }
        }
        throw "Chrome Web Store: $($response.StatusCode) $((Get-Property $body 'error.message') ?? $response.Content)$hint"
    }
    $body
}

<#
  The Edge Add-ons API has no read-only call for a product, only for upload and
  publish operations. Asking for an operation that doesn't exist shows whether
  the credentials are accepted (404) or not (401/403). It can't confirm the
  product ID: an unknown product is also a 404.
#>
function Test-EdgeCredentials {
    param([Parameter(Mandatory)][string]$ClientId, [Parameter(Mandatory)][string]$ApiKey, [string]$ProductId)
    if (-not $ProductId) { $ProductId = [guid]::Empty }
    $response = Invoke-WebRequest -Uri "https://api.addons.microsoftedge.microsoft.com/v1/products/$ProductId/submissions/draft/package/operations/$([guid]::Empty)" `
        -Headers @{ Authorization = "ApiKey $ApiKey"; 'X-ClientID' = $ClientId } -SkipHttpErrorCheck
    [pscustomobject]@{
        StatusCode = [int]$response.StatusCode
        Accepted   = [int]$response.StatusCode -notin 401, 403
        Message    = $response.Content
    }
}

# ── Manifest ──

function Read-Manifest {
    param([Parameter(Mandatory)][string]$Directory)
    $path = Join-Path $Directory 'manifest.json'
    if (-not (Test-Path $path)) { throw "No manifest.json in $Directory - did the build run?" }
    Get-Content $path -Raw | ConvertFrom-Json -AsHashtable
}

<# Resolves "__MSG_appName__" against _locales/<default_locale>/messages.json. #>
function Resolve-ManifestString {
    param([string]$Value, [System.Collections.IDictionary]$Manifest, [string]$Directory)
    if ($Value -notmatch '^__MSG_(.+)__$') { return $Value }
    $key = $Matches[1]
    $locale = $Manifest['default_locale']
    # A zip published from an earlier stage has no unpacked folder to look in
    if (-not $locale -or -not $Directory) { return $Value }
    $messages = Join-Path $Directory "_locales/$locale/messages.json"
    if (-not (Test-Path $messages)) { return $Value }
    $table = Get-Content $messages -Raw | ConvertFrom-Json -AsHashtable
    $entry = $table.Keys | Where-Object { $_ -ieq $key } | Select-Object -First 1
    if ($entry) { $table[$entry].message } else { $Value }
}

<#
  Everything a reviewer will ask you to justify: API permissions, optional ones,
  and host access (host_permissions and content script matches are both host access).
#>
function Get-ManifestPermissions {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Manifest)
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($key in 'permissions', 'optional_permissions') {
        foreach ($p in @($Manifest[$key] | Where-Object { $_ })) {
            # MV3 moved hosts out of permissions, but older manifests still mix them in
            if ($p -match '://|^<all_urls>$') { continue }
            if (-not $names.Contains($p)) { $names.Add($p) }
        }
    }
    $hasHosts = @($Manifest['host_permissions'] | Where-Object { $_ }).Count -gt 0 `
        -or @($Manifest['optional_host_permissions'] | Where-Object { $_ }).Count -gt 0 `
        -or @($Manifest['content_scripts'] | Where-Object { $_ } | ForEach-Object { $_['matches'] }).Count -gt 0 `
        -or @($Manifest['permissions'] | Where-Object { $_ -match '://|^<all_urls>$' }).Count -gt 0
    if ($hasHosts) { $names.Add('host permissions') }
    $names.ToArray()
}

<#
  Every file the manifest points at. A package missing one of these is rejected
  on upload ("Could not load icon…"), or installs broken.
#>
function Get-ManifestFileReferences {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Manifest)
    $refs = [System.Collections.Generic.List[string]]::new()
    $addValues = { param($v) if ($v -is [System.Collections.IDictionary]) { $v.Values | ForEach-Object { $refs.Add($_) } } elseif ($v) { $refs.Add($v) } }

    & $addValues $Manifest['icons']
    foreach ($key in 'action', 'browser_action', 'page_action') {
        if ($Manifest[$key]) { & $addValues $Manifest[$key]['default_icon']; & $addValues $Manifest[$key]['default_popup'] }
    }
    if ($Manifest['background']) { & $addValues $Manifest['background']['service_worker'] }
    foreach ($script in @($Manifest['content_scripts'] | Where-Object { $_ })) {
        @($script['js']) + @($script['css']) | Where-Object { $_ } | ForEach-Object { $refs.Add($_) }
    }
    & $addValues $Manifest['options_page']
    if ($Manifest['options_ui']) { & $addValues $Manifest['options_ui']['page'] }
    if ($Manifest['side_panel']) { & $addValues $Manifest['side_panel']['default_path'] }
    & $addValues $Manifest['devtools_page']
    if ($Manifest['declarative_net_request']) {
        @($Manifest['declarative_net_request']['rule_resources']) | Where-Object { $_ } | ForEach-Object { $refs.Add($_['path']) }
    }
    if ($Manifest['default_locale']) { $refs.Add("_locales/$($Manifest['default_locale'])/messages.json") }

    $refs | Where-Object { $_ } | ForEach-Object { ($_ -replace '\\', '/').TrimStart('/') } | Sort-Object -Unique
}

function Get-ZipEntryNames {
    param([Parameter(Mandatory)][string]$ZipPath)
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path $ZipPath).Path)
    try { $zip.Entries | Where-Object { $_.Name } | ForEach-Object FullName } finally { $zip.Dispose() }
}

function Test-ExtensionVersion {
    param([string]$Version)
    if ($Version -notmatch '^\d+(\.\d+){0,3}$') { return $false }
    foreach ($part in $Version.Split('.')) {
        if ($part.Length -gt 1 -and $part.StartsWith('0')) { return $false }
        if ([long]$part -gt 65535) { return $false }
    }
    $true
}

# ── Images ──

<#
  Width and height from the file header, so this works on any OS without
  System.Drawing (which is Windows-only on .NET). PNG and JPEG only - the two
  formats both stores accept.
#>
function Get-ImageSize {
    param([Parameter(Mandatory)][string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    # Bytes stay bytes under -shl (0x01 -shl 8 is 0), hence the casts
    $be16 = { param($i) ([int]$bytes[$i] -shl 8) -bor $bytes[$i + 1] }
    $be32 = { param($i) ([long]$bytes[$i] -shl 24) -bor ([long]$bytes[$i + 1] -shl 16) -bor ([long]$bytes[$i + 2] -shl 8) -bor $bytes[$i + 3] }

    if ($bytes.Length -ge 24 -and $bytes[0] -eq 0x89 -and $bytes[1] -eq 0x50 -and $bytes[2] -eq 0x4E -and $bytes[3] -eq 0x47) {
        return [pscustomobject]@{ Width = [int](& $be32 16); Height = [int](& $be32 20); Format = 'png' }
    }
    if ($bytes.Length -ge 4 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xD8) {
        $i = 2
        while ($i + 9 -lt $bytes.Length) {
            if ($bytes[$i] -ne 0xFF) { $i++; continue }
            $marker = $bytes[$i + 1]
            # SOF0-SOF15 carry the frame size; C4 (DHT), C8 (JPG) and CC (DAC) share the range but don't
            if ($marker -ge 0xC0 -and $marker -le 0xCF -and $marker -notin 0xC4, 0xC8, 0xCC) {
                return [pscustomobject]@{ Width = [int](& $be16 ($i + 7)); Height = [int](& $be16 ($i + 5)); Format = 'jpeg' }
            }
            $i += 2 + (& $be16 ($i + 2))
        }
    }
    $null
}

function Format-Size { param($Size) if ($Size) { "$($Size.Width)x$($Size.Height)" } else { 'unreadable' } }

# ── Packaging ──

<#
  Zips the build output with forward-slash entry names (the Chrome Web Store
  rejects backslashes, which Windows PowerShell's Compress-Archive used to write)
  and writes a store-safe manifest: the stores assign their own ID and serve their
  own updates, so `key` and `update_url` are removed from the copy in the zip.
#>
function New-ExtensionZip {
    param(
        [Parameter(Mandatory)][string]$SourceDirectory,
        [Parameter(Mandatory)][string]$Destination,
        [string[]]$Exclude = @(),
        [string[]]$StripManifestKeys = @('key', 'update_url')
    )
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    # The folder names matter for extensions with no build step, zipped from the repo root
    $always = @('.DS_Store', 'Thumbs.db', '*.crx', '*.pem', '*.p12', '*.service-account.json', '.env', '.env.*', '.gitignore', '.gitattributes', '.git/*', '.github/*', '.vscode/*', 'node_modules/*')
    $patterns = @($always + $Exclude)

    New-Item -ItemType Directory -Force -Path (Split-Path $Destination) | Out-Null
    if (Test-Path $Destination) { Remove-Item $Destination -Force }

    $root = (Resolve-Path $SourceDirectory).Path.TrimEnd('\', '/')
    $stripped = @()
    $count = 0
    $zip = [System.IO.Compression.ZipFile]::Open($Destination, 'Create')
    try {
        # Enumerated from $root as given, so every path starts with exactly $root - Get-ChildItem
        # can return the long form of a short (8.3) path, and the cut would land mid-name
        foreach ($path in [System.IO.Directory]::EnumerateFiles($root, '*', 'AllDirectories') | Sort-Object) {
            $file = [System.IO.FileInfo]::new($path)
            $relative = $path.Substring($root.Length + 1).Replace('\', '/')
            if ($patterns | Where-Object { $relative -like $_ -or $file.Name -like $_ }) { continue }
            # A key under any other name would be published to everyone who installs the extension
            if ($file.Extension -eq '.json' -and (Select-String -Path $file.FullName -Pattern '"private_key"\s*:\s*"-----BEGIN' -Quiet)) {
                throw "$relative is a service account key; refusing to package it. Move it out of the build output."
            }

            $entry = $zip.CreateEntry($relative, 'Optimal')
            $entry.LastWriteTime = $file.LastWriteTime
            $out = $entry.Open()
            try {
                if ($relative -eq 'manifest.json') {
                    $manifest = Get-Content $file.FullName -Raw | ConvertFrom-Json -AsHashtable
                    foreach ($key in $StripManifestKeys) {
                        if ($manifest.Contains($key)) { $manifest.Remove($key); $stripped += $key }
                    }
                    $json = [System.Text.Encoding]::UTF8.GetBytes(($manifest | ConvertTo-Json -Depth 50))
                    $out.Write($json, 0, $json.Length)
                } else {
                    $in = [System.IO.File]::OpenRead($file.FullName)
                    try { $in.CopyTo($out) } finally { $in.Dispose() }
                }
            } finally { $out.Dispose() }
            $count++
        }
    } finally { $zip.Dispose() }

    [pscustomobject]@{ Path = $Destination; Files = $count; Stripped = $stripped; SizeKB = [math]::Round((Get-Item $Destination).Length / 1KB) }
}

<# Reads manifest.json out of an existing zip, for publishing a zip built in an earlier pipeline stage. #>
function Read-ZipManifest {
    param([Parameter(Mandatory)][string]$ZipPath)
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path $ZipPath).Path)
    try {
        $entry = $zip.GetEntry('manifest.json')
        if (-not $entry) { throw "$ZipPath has no manifest.json at its root." }
        $reader = [System.IO.StreamReader]::new($entry.Open())
        try { $reader.ReadToEnd() | ConvertFrom-Json -AsHashtable } finally { $reader.Dispose() }
    } finally { $zip.Dispose() }
}

# ── Validation ──

<#
  Checks the manifest and the store/ listing against what each store will
  demand, before anything is uploaded. Returns findings; Error blocks a publish,
  Warning doesn't.

  A section or file still containing "TODO" counts as missing: the templates
  are full of TODOs, so a freshly scaffolded listing can't be published by accident.
#>
function Test-StoreListing {
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Manifest,
        [string]$ManifestDirectory,
        [string[]]$Stores = @('chrome', 'edge'),
        # The package's contents, to check every file the manifest references is in it
        [string[]]$PackagedFiles
    )
    $findings = [System.Collections.Generic.List[object]]::new()
    $add = { param($Level, $Store, $Message) $findings.Add([pscustomobject]@{ Level = $Level; Store = $Store; Message = $Message }) }
    $chrome = 'chrome' -in $Stores
    $edge = 'edge' -in $Stores
    $store = Join-Path $ProjectPath 'store'
    $isTodo = { param($text) [string]::IsNullOrWhiteSpace($text) -or $text -match '\bTODO\b' }

    # Manifest
    if ($Manifest['manifest_version'] -ne 3) { & $add Error 'all' "manifest_version is $($Manifest['manifest_version']); both stores only accept Manifest V3." }
    if (-not (Test-ExtensionVersion $Manifest['version'])) { & $add Error 'all' "version '$($Manifest['version'])' must be 1-4 dot-separated integers, each 0-65535, no leading zeros." }

    $name = Resolve-ManifestString $Manifest['name'] $Manifest $ManifestDirectory
    $description = Resolve-ManifestString $Manifest['description'] $Manifest $ManifestDirectory
    if (-not $name) { & $add Error 'all' 'manifest has no name.' }
    elseif ($name.Length -gt $Rules.ManifestNameMax) { & $add Error 'all' "manifest name is $($name.Length) characters; the limit is $($Rules.ManifestNameMax)." }
    if (-not $description) { & $add Error 'all' 'manifest has no description - it is the summary line under the name in both stores.' }
    elseif ($description.Length -gt $Rules.ManifestDescriptionMax) { & $add Error 'all' "manifest description is $($description.Length) characters; the limit is $($Rules.ManifestDescriptionMax)." }
    if (-not ($Manifest['icons'] -and $Manifest['icons']['128'])) { & $add Warning 'all' 'manifest has no 128px icon.' }
    if ($PackagedFiles) {
        foreach ($ref in Get-ManifestFileReferences $Manifest) {
            if ($ref -notin $PackagedFiles) { & $add Error 'all' "The manifest references $ref, which isn't in the package." }
        }
    }
    if ('webRequestBlocking' -in @($Manifest['permissions'])) {
        & $add Error 'all' 'webRequestBlocking only works in MV3 for extensions force-installed by policy; the stores reject it. Use declarativeNetRequest.'
    }

    # Listing text
    $locale = $Config.listing.defaultLocale
    $descPath = Join-Path $store "listing/$locale/description.txt"
    $listing = if (Test-Path $descPath) { (Get-Content $descPath -Raw) } else { '' }
    if (& $isTodo $listing) {
        & $add Error 'all' "store/listing/$locale/description.txt is missing or still has TODOs."
    } elseif ($edge) {
        $length = $listing.Trim().Length
        if ($length -lt $Rules.EdgeDescriptionMin) { & $add Error 'edge' "description.txt is $length characters; Edge needs at least $($Rules.EdgeDescriptionMin)." }
        if ($length -gt $Rules.EdgeDescriptionMax) { & $add Error 'edge' "description.txt is $length characters; Edge allows at most $($Rules.EdgeDescriptionMax)." }
    }

    # Images
    $images = Join-Path $store 'images'
    $checkImage = {
        param($File, $Expected, $Level, $StoreName, $Why)
        $path = Join-Path $images $File
        if (-not (Test-Path $path)) { if ($Level) { & $add $Level $StoreName "store/images/$File is missing ($Why)." }; return }
        $size = Get-ImageSize $path
        if ((Format-Size $size) -ne $Expected) { & $add Error $StoreName "store/images/$File is $(Format-Size $size); it must be $Expected." }
    }
    if ($chrome) {
        & $checkImage 'icon-128.png' '128x128' Error 'chrome' 'Store icon'
        & $checkImage 'promo-small-440x280.png' '440x280' Error 'chrome' 'Small promo tile, required'
    } elseif ($edge) {
        & $checkImage 'promo-small-440x280.png' '440x280' $null 'edge' ''
    }
    & $checkImage 'promo-marquee-1400x560.png' '1400x560' $null 'all' ''

    if ($edge) {
        $logo = @('logo-300.png', 'icon-128.png') | ForEach-Object { Join-Path $images $_ } | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $logo) { & $add Error 'edge' 'store/images/logo-300.png is missing (Extension logo, 1:1, 300x300 recommended).' }
        else {
            $size = Get-ImageSize $logo
            if (-not $size -or $size.Width -ne $size.Height -or $size.Width -lt 128) { & $add Error 'edge' "$(Split-Path $logo -Leaf) is $(Format-Size $size); the Edge logo must be square and at least 128x128." }
            elseif ((Split-Path $logo -Leaf) -ne 'logo-300.png') { & $add Warning 'edge' 'No store/images/logo-300.png; icon-128.png will do, but Edge recommends 300x300.' }
        }
    }

    $shots = @(Get-ChildItem (Join-Path $images 'screenshots/*') -File -Include *.png, *.jpg, *.jpeg -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($chrome -and $shots.Count -eq 0) { & $add Error 'chrome' 'store/images/screenshots/ is empty; the Chrome Web Store needs at least one.' }
    if ($chrome -and $shots.Count -gt $Rules.ChromeScreenshotMax) { & $add Warning 'chrome' "$($shots.Count) screenshots; Chrome takes the first $($Rules.ChromeScreenshotMax)." }
    if ($edge -and $shots.Count -gt $Rules.EdgeScreenshotMax) { & $add Warning 'edge' "$($shots.Count) screenshots; Edge takes the first $($Rules.EdgeScreenshotMax)." }
    foreach ($shot in $shots) {
        $size = Format-Size (Get-ImageSize $shot.FullName)
        if ($chrome -and $size -notin $Rules.ChromeScreenshotSizes) { & $add Error 'chrome' "screenshots/$($shot.Name) is $size; Chrome accepts $($Rules.ChromeScreenshotSizes -join ' or ')." }
        if ($edge -and $size -notin $Rules.EdgeScreenshotSizes) { & $add Error 'edge' "screenshots/$($shot.Name) is $size; Edge accepts $($Rules.EdgeScreenshotSizes -join ' or ')." }
    }

    # Privacy
    if (-not $Config.listing.privacyPolicyUrl) { & $add Warning 'all' 'listing.privacyPolicyUrl is empty in store.json. Both stores require one if the extension handles any user data.' }
    $single = Join-Path $store 'privacy/single-purpose.md'
    if ($chrome -and (& $isTodo ((Test-Path $single) ? (Get-Content $single -Raw) : ''))) { & $add Error 'chrome' 'store/privacy/single-purpose.md is missing or still has TODOs (Privacy tab: Single purpose).' }
    $usage = Join-Path $store 'privacy/data-usage.md'
    if (& $isTodo ((Test-Path $usage) ? (Get-Content $usage -Raw) : '')) { & $add Warning 'all' 'store/privacy/data-usage.md is missing or still has TODOs.' }

    $permFile = Join-Path $store 'privacy/permissions.md'
    $sections = Get-MarkdownSections $permFile
    foreach ($permission in Get-ManifestPermissions $Manifest) {
        $body = $sections[$permission]
        if ($null -eq $body) { & $add Error 'all' "store/privacy/permissions.md has no '## $permission' section - reviewers ask for a justification of every permission." }
        elseif (& $isTodo $body) { & $add Error 'all' "store/privacy/permissions.md: '## $permission' still has TODOs." }
    }
    foreach ($extra in $sections.Keys | Where-Object { $_ -notin (Get-ManifestPermissions $Manifest) }) {
        & $add Warning 'all' "store/privacy/permissions.md justifies '$extra', which the manifest no longer requests."
    }

    $findings.ToArray()
}

<# "## heading" -> body text, keyed case-insensitively. Missing file -> empty table. #>
function Get-MarkdownSections {
    param([string]$Path)
    $sections = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
    if (-not $Path -or -not (Test-Path $Path)) { return $sections }
    $current = $null
    foreach ($line in Get-Content $Path) {
        if ($line -match '^##\s+`?([^`]+?)`?\s*$') { $current = $Matches[1]; $sections[$current] = ''; continue }
        if ($line -match '^#\s') { $current = $null; continue }
        if ($current) { $sections[$current] += "$line`n" }
    }
    $sections
}

# ── CI integration ──

function Get-CiSystem {
    if ($env:TF_BUILD) { 'azure' } elseif ($env:GITHUB_ACTIONS) { 'github' } else { 'local' }
}

<# A finding, shown the way each CI system surfaces annotations. #>
function Write-Finding {
    param([Parameter(Mandatory)]$Finding)
    $text = "[$($Finding.Store)] $($Finding.Message)"
    switch (Get-CiSystem) {
        'azure' { Write-Host "##vso[task.logissue type=$($Finding.Level.ToLowerInvariant())]$text" }
        'github' { Write-Host "::$($Finding.Level.ToLowerInvariant())::$text" }
        default {
            $color = if ($Finding.Level -eq 'Error') { 'Red' } else { 'Yellow' }
            Write-Host "  $($Finding.Level.ToUpperInvariant().PadRight(7)) $text" -ForegroundColor $color
        }
    }
}

<# Exposes a value to later pipeline steps: an output variable in Azure DevOps, a step output in GitHub. #>
function Set-CiOutput {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Value)
    switch (Get-CiSystem) {
        'azure' {
            Write-Host "##vso[task.setvariable variable=$Name]$Value"
            Write-Host "##vso[task.setvariable variable=$Name;isOutput=true]$Value"
        }
        'github' { if ($env:GITHUB_OUTPUT) { Add-Content -Path $env:GITHUB_OUTPUT -Value "$Name=$Value" } }
    }
}

function Add-CiSummary {
    param([Parameter(Mandatory)][string]$Markdown)
    switch (Get-CiSystem) {
        'github' { if ($env:GITHUB_STEP_SUMMARY) { Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value $Markdown } }
        'azure' {
            $file = Join-Path ($env:AGENT_TEMPDIRECTORY ?? [IO.Path]::GetTempPath()) "extension-publish-$([guid]::NewGuid().ToString('n')).md"
            Set-Content -Path $file -Value $Markdown
            Write-Host "##vso[task.uploadsummary]$file"
        }
    }
}

Export-ModuleMember -Function *
