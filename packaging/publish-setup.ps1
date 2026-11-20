param(
  [Parameter(Mandatory = $true)][string]$Version
)
# Signs and uploads ScreenReplay-Setup-<Version>.exe + signed latest.json to Cloudflare R2 bucket `screenreplay`.
# Requires $env:SCREENREPLAY_SIGN_KEY (from still.fail vault 「ScreenReplay 更新签名私钥（ECDSA P-256）」).
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path "$PSScriptRoot\..").Path
$setup = Join-Path $repo "out\setup\ScreenReplay-Setup-$Version.exe"
if (-not (Test-Path $setup)) {
  throw "Setup installer not found: $setup (run packaging\pack-setup.ps1 -Version $Version first)"
}
$size = (Get-Item $setup).Length
$sha = (Get-FileHash -Algorithm SHA256 $setup).Hash.ToLowerInvariant()
$sig = (& "$PSScriptRoot\sign-release.ps1" -Version $Version -SetupSha $sha).Trim()
if ($sig.Length -ne 128) { throw "Invalid signature output length: $($sig.Length)" }

$latestPath = Join-Path $repo "out\setup\latest.json"
$json = "{`"version`":`"$Version`",`"setup`":$size,`"setup_sha256`":`"$sha`",`"signature`":`"$sig`"}"
[IO.File]::WriteAllText($latestPath, $json, (New-Object Text.UTF8Encoding $false))

function Put-R2Object([string]$Key, [string]$File, [string]$ContentType) {
  for ($i = 1; $i -le 4; $i++) {
    npx --yes wrangler r2 object put "screenreplay/$Key" --file "$File" --content-type "$ContentType" --remote
    if ($LASTEXITCODE -eq 0) { return }
    Start-Sleep -Seconds 2
  }
  throw "Failed uploading $Key to R2 after 4 attempts"
}

Push-Location $repo
try {
  Put-R2Object "v$Version/ScreenReplay-Setup-$Version.exe" "$setup" "application/vnd.microsoft.portable-executable"
  Put-R2Object "ScreenReplay-Setup.exe" "$setup" "application/vnd.microsoft.portable-executable"
  Put-R2Object "latest.json" "$latestPath" "application/json; charset=utf-8"
} finally {
  Pop-Location
}
Write-Host "Published signed release v$Version ($size bytes, sha256=$sha)"
