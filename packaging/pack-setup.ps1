param(
  [string]$Stage = "",
  [string]$Version = "0.1.26",
  [string]$AppIdOverride = ""
)
# Builds out\setup\ScreenReplay-Setup-<Version>.exe from a staged self-contained build (ScreenReplay.exe + ScreenReplayViewer.exe).
# When -Stage is omitted, builds a fresh trimmed self-contained stage from current source into out-setup-stage\stage.
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path "$PSScriptRoot\..").Path
if (-not $Stage) {
  $Stage = Join-Path $repo "out-setup-stage\stage"
  if (Test-Path $Stage) { Remove-Item $Stage -Recurse -Force }
  New-Item -ItemType Directory -Force $Stage | Out-Null
  dotnet publish "$repo\recorder\ReplayRecorder.csproj" -c Release -p:Platform=x64 -r win-x64 --self-contained true -p:PublishTrimmed=true -o $Stage
  if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed" }
  Get-ChildItem $Stage -Filter *.pdb | Remove-Item
  Get-ChildItem $Stage -File | Where-Object { $_.Name -match '^(createdump\.exe|mscordaccore.*\.dll|mscordbi\.dll|Microsoft\.DiaSymReader\.Native\..*\.dll)$' } | Remove-Item
  $viewerExe = Join-Path $repo "out\ScreenReplayViewer.exe"
  if (-not (Test-Path $viewerExe)) {
    throw "ScreenReplayViewer.exe not found at $viewerExe (run scripts\build.ps1 first)"
  }
  Copy-Item $viewerExe $Stage
  $git = (git -C $repo rev-parse --short HEAD).Trim()
  Set-Content -Path "$Stage\build.txt" -Value "$Version $git" -Encoding ascii
}
$Stage = [IO.Path]::GetFullPath($Stage)
if (-not (Test-Path "$Stage\ScreenReplay.exe") -or -not (Test-Path "$Stage\ScreenReplayViewer.exe")) {
  throw "Stage folder missing ScreenReplay.exe or ScreenReplayViewer.exe: $Stage"
}
$iscc = @("$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe", "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe") |
  Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) { throw "Inno Setup 6 not found: winget install JRSoftware.InnoSetup --scope user" }
$argsList = @("/Q", "/DAppVer=$Version", "/DStageDir=$Stage", "/DRepo=$repo")
if ($AppIdOverride) { $argsList += "/DAppIdOverride=$AppIdOverride" }
$argsList += "$repo\packaging\ScreenReplay.iss"
& $iscc @argsList
if ($LASTEXITCODE) { throw "ISCC failed: $LASTEXITCODE" }
Get-Item "$repo\out\setup\ScreenReplay-Setup-$Version.exe"
