param(
  [Parameter(Mandatory = $true)][string]$Version,
  [switch]$NoMac
)
# Signs and uploads ScreenReplay-Setup-<Version>.exe + signed latest.json to Cloudflare R2 bucket `screenreplay`.
# Requires $env:SCREENREPLAY_SIGN_KEY (from still.fail vault 「ScreenReplay 更新签名私钥（ECDSA P-256）」).
# The macOS build is this commit's: ScreenReplay-mac.zip, signed with AFK AI's Developer ID and notarized by the macOS
# package workflow (.github/workflows/macos.yml; started here on the current branch when this commit has no run, gh
# logged in), put as ScreenReplay-mac.zip and signed in latest.json as mac_sha256 / mac_signature for
# mac/Sources/ScreenReplayKit/Updater.swift (-NoMac: Windows alone).
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path "$PSScriptRoot\..").Path
$setup = Join-Path $repo "out\setup\ScreenReplay-Setup-$Version.exe"
if (-not (Test-Path $setup)) {
  throw "Setup installer not found: $setup (run packaging\pack-setup.ps1 -Version $Version first)"
}
$mac = $null
if (-not $NoMac) {
  $gh = "AFK-surf/screenreplay"
  $commit = (git -C $repo rev-parse HEAD).Trim()
  $branch = (git -C $repo rev-parse --abbrev-ref HEAD).Trim()
  git -C $repo fetch -q origin $branch
  if ((git -C $repo rev-parse "origin/$branch").Trim() -ne $commit) { throw "push $branch first: the macOS build is made from GitHub's copy of $commit" }
  $run = $null
  for ($i = 0; $i -lt 120; $i++) {
    $runs = gh run list -R $gh -w macos.yml --commit $commit --json databaseId,status,conclusion | ConvertFrom-Json
    $done = @($runs | Where-Object { $_.conclusion -eq "success" })
    if ($done.Count) { $run = $done[0].databaseId; break }
    if (-not @($runs | Where-Object { $_.status -ne "completed" }).Count) {
      if ($i -gt 0 -and $runs.Count) { throw "the macOS package workflow failed on $commit: see gh run list -R $gh -w macos.yml" }
      gh workflow run macos.yml -R $gh --ref $branch
      Write-Host "started the macOS package workflow on $branch ($commit), waiting..."
    }
    Start-Sleep 30
  }
  if (-not $run) { throw "no macOS build of $commit: see gh run list -R $gh -w macos.yml, or -NoMac" }
  $dir = Join-Path $env:TEMP "screenreplay-mac-$Version"
  Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $dir
  gh run download $run -R $gh -n ScreenReplay-mac -D $dir
  if ($LASTEXITCODE) { throw "could not download run $run's ScreenReplay-mac" }
  $mac = Join-Path $dir "ScreenReplay-mac.zip"
  if (-not (Test-Path $mac)) { throw "run $run has no ScreenReplay-mac.zip" }
}

$size = (Get-Item $setup).Length
$sha = (Get-FileHash -Algorithm SHA256 $setup).Hash.ToLowerInvariant()
$sig = (& "$PSScriptRoot\sign-release.ps1" -Version $Version -SetupSha $sha).Trim()
if ($sig.Length -ne 128) { throw "Invalid signature output length: $($sig.Length)" }

$latestPath = Join-Path $repo "out\setup\latest.json"
$macFields = ""
if ($mac) {
  # (the zip signed as the setup is: what Updater.swift checks the signature of)
  $macSize = (Get-Item $mac).Length
  $macSha = (Get-FileHash -Algorithm SHA256 $mac).Hash.ToLowerInvariant()
  $macSig = (& "$PSScriptRoot\sign-release.ps1" -Version $Version -SetupSha $macSha).Trim()
  if ($macSig.Length -ne 128) { throw "Invalid signature output length: $($macSig.Length)" }
  $macFields = ",`"mac`":$macSize,`"mac_sha256`":`"$macSha`",`"mac_signature`":`"$macSig`""
}
$json = "{`"version`":`"$Version`",`"setup`":$size,`"setup_sha256`":`"$sha`",`"signature`":`"$sig`"$macFields}"
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
  if ($mac) {
    Put-R2Object "v$Version/ScreenReplay-mac.zip" "$mac" "application/zip"
    Put-R2Object "ScreenReplay-mac.zip" "$mac" "application/zip"
  }
  Put-R2Object "latest.json" "$latestPath" "application/json; charset=utf-8"
} finally {
  Pop-Location
}
Write-Host "Published signed release v$Version ($size bytes, sha256=$sha)"
