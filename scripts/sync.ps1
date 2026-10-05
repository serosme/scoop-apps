#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$App,
    [string]$ConfigPath,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
if (-not $ConfigPath) { $ConfigPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'apps.json' }

$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$cfg = @($config.apps | Where-Object name -eq $App)
if ($cfg.Count -ne 1) { throw "no unique app named '$App' in apps.json" }
$cfg = $cfg[0]

$endpoint = "repos/$($cfg.repo)/releases/latest"
$release = gh api $endpoint | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw "failed to get upstream release: $endpoint" }

$version = $release.tag_name -replace '^v', ''
if ($version -notmatch '^[A-Za-z0-9_.\-+]+$') { throw "version '$version' has characters Scoop does not accept" }

$wanted = $cfg.asset.Replace('$version', $version)
$asset = @($release.assets | Where-Object name -eq $wanted)
if ($asset.Count -ne 1) { throw "upstream has no asset '$wanted'; available: $(@($release.assets.name) -join ', ')" }
$asset = $asset[0]

$hash = $asset.digest -replace '^sha256:', ''
if ($hash -notmatch '^[0-9a-f]{64}$') { throw "upstream asset has no usable sha256 digest" }

if ($asset.browser_download_url -match '/releases/latest/download/') { throw "refusing a latest link that changes over time" }

$arch64 = [ordered]@{ url = $asset.browser_download_url; hash = $hash }
if ($cfg.extractDir) { $arch64['extract_dir'] = $cfg.extractDir }
if ($cfg.bin) { $arch64['bin'] = $cfg.bin }
$manifest = [ordered]@{ version = $version; architecture = [ordered]@{ '64bit' = $arch64 } }
if ($cfg.shortcuts) { $manifest['shortcuts'] = $cfg.shortcuts }
if ($cfg.persist) { $manifest['persist'] = $cfg.persist }

$json = $manifest | ConvertTo-Json -Depth 10
$url = "https://github.com/$($config.channel)/releases/download/$App/$App.json"
if ($DryRun) { Write-Host $json; return }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "$App.json"
[System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
$null = gh release view $App --json tagName
if ($LASTEXITCODE -ne 0) { gh release create $App --latest=false }
gh release upload $App $tmp --clobber
if ($LASTEXITCODE -ne 0) { throw "failed to upload manifest: $url" }
