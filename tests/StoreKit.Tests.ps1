#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Invoke-Pester ./tests

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../lib/StoreKit.psm1') -Force

    function New-Png([string]$Path, [int]$Width, [int]$Height) {
        # Only the header matters to Get-ImageSize: signature, IHDR length and type, then width and height
        $bytes = [byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52) +
            [BitConverter]::GetBytes([uint32]$Width)[3..0] + [BitConverter]::GetBytes([uint32]$Height)[3..0] + [byte[]](8, 2, 0, 0, 0)
        New-Item -ItemType Directory -Force (Split-Path $Path) | Out-Null
        [IO.File]::WriteAllBytes($Path, $bytes)
    }

    function New-Project {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Force "$root/dist", "$root/store/listing/en", "$root/store/privacy", "$root/store/images/screenshots" | Out-Null
        @{
            manifest_version = 3; name = 'Test'; version = '1.2.3'; description = 'A test extension.'
            icons = @{ '128' = 'icon.png' }; permissions = @('storage'); host_permissions = @('https://example.com/*')
        } | ConvertTo-Json | Set-Content "$root/dist/manifest.json"
        '{ "name": "test" }' | Set-Content "$root/store/store.json"
        ('A complete description. ' * 20) | Set-Content "$root/store/listing/en/description.txt"
        "# Single purpose`n`nDoes one thing." | Set-Content "$root/store/privacy/single-purpose.md"
        "# Data usage`n`nNothing leaves the browser." | Set-Content "$root/store/privacy/data-usage.md"
        "# Permissions`n`n## storage`n`nKeeps settings.`n`n## host permissions`n`nReads example.com pages." | Set-Content "$root/store/privacy/permissions.md"
        New-Png "$root/store/images/icon-128.png" 128 128
        New-Png "$root/store/images/logo-300.png" 300 300
        New-Png "$root/store/images/promo-small-440x280.png" 440 280
        New-Png "$root/store/images/screenshots/01.png" 1280 800
        $root
    }

    function Get-Findings([string]$Root, [string[]]$Stores = @('chrome', 'edge')) {
        $config = Get-StoreConfig -ProjectPath $Root
        $config.listing.privacyPolicyUrl = 'https://example.com/privacy'
        @(Test-StoreListing -ProjectPath $Root -Config $config -Manifest (Read-Manifest "$Root/dist") -ManifestDirectory "$Root/dist" -Stores $Stores)
    }
}

Describe 'Get-ImageSize' {
    It 'reads sizes above 255 (bytes must not truncate under -shl)' {
        New-Png "$TestDrive/big.png" 1400 560
        $size = Get-ImageSize "$TestDrive/big.png"
        "$($size.Width)x$($size.Height)" | Should -Be '1400x560'
    }
}

Describe 'Test-ExtensionVersion' {
    It 'accepts <v>' -ForEach @(@{ v = '1' }, @{ v = '1.2.3.4' }, @{ v = '2025.7.21.1' }) { Test-ExtensionVersion $v | Should -BeTrue }
    It 'rejects <v>' -ForEach @(@{ v = '1.2.3.4.5' }, @{ v = '1.02' }, @{ v = '70000' }, @{ v = '1.0-beta' }) { Test-ExtensionVersion $v | Should -BeFalse }
}

Describe 'Get-ManifestPermissions' {
    It 'returns one entry per permission, plus host access' {
        $perms = @(Get-ManifestPermissions @{ permissions = @('storage', 'tabs'); content_scripts = @(@{ matches = @('https://a/*') }) })
        $perms | Should -Be @('storage', 'tabs', 'host permissions')
    }
}

Describe 'Test-StoreListing' {
    It 'passes a complete listing' {
        Get-Findings (New-Project) | Should -BeNullOrEmpty
    }
    It 'treats TODO as missing' {
        $root = New-Project
        "# Permissions`n`n## storage`n`nTODO: why`n`n## host permissions`n`nok" | Set-Content "$root/store/privacy/permissions.md"
        (Get-Findings $root).Message | Should -Contain "store/privacy/permissions.md: '## storage' still has TODOs."
    }
    It 'flags a permission with no justification' {
        $root = New-Project
        "# Permissions`n`n## host permissions`n`nok" | Set-Content "$root/store/privacy/permissions.md"
        (Get-Findings $root | Where-Object Level -eq Error).Message | Should -Match "no '## storage' section"
    }
    It 'checks screenshot sizes per store' {
        $root = New-Project
        New-Png "$root/store/images/screenshots/02.png" 640 480
        (Get-Findings $root -Stores chrome).Store | Should -Contain 'chrome'
        Get-Findings $root -Stores edge | Should -BeNullOrEmpty
    }
    It 'enforces the Edge description minimum only for Edge' {
        $root = New-Project
        'Short.' | Set-Content "$root/store/listing/en/description.txt"
        Get-Findings $root -Stores chrome | Should -BeNullOrEmpty
        (Get-Findings $root -Stores edge).Message | Should -Match 'at least 250'
    }
}

Describe 'Manifest file references' {
    It 'flags files the manifest names but the package lacks' {
        $root = New-Project
        $config = Get-StoreConfig -ProjectPath $root
        $config.listing.privacyPolicyUrl = 'https://example.com/privacy'
        $manifest = Read-Manifest "$root/dist"
        $manifest['background'] = @{ service_worker = 'bg.js' }
        $findings = Test-StoreListing -ProjectPath $root -Config $config -Manifest $manifest -PackagedFiles @('manifest.json', 'bg.js')
        @($findings).Message | Should -Be @("The manifest references icon.png, which isn't in the package.")
    }
}

Describe 'New-ExtensionZip' {
    It 'writes forward-slash paths with no leading slash, and strips key and update_url' {
        $src = Join-Path $TestDrive 'zipsrc'
        New-Item -ItemType Directory -Force "$src/icons" | Out-Null
        '{ "name": "x", "version": "1", "key": "abc", "update_url": "https://u" }' | Set-Content "$src/manifest.json"
        'x' | Set-Content "$src/icons/a.png"
        'x' | Set-Content "$src/app.js.map"
        $zip = New-ExtensionZip -SourceDirectory $src -Destination "$TestDrive/out.zip" -Exclude '*.map'

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [IO.Compression.ZipFile]::OpenRead($zip.Path)
        try { $names = $archive.Entries.FullName } finally { $archive.Dispose() }
        $names | Should -Be @('icons/a.png', 'manifest.json')

        $manifest = Read-ZipManifest $zip.Path
        $manifest.Contains('key') | Should -BeFalse
        $manifest.Contains('update_url') | Should -BeFalse
        $zip.Stripped | Should -Be @('key', 'update_url')
    }
}
