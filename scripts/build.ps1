param(
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release",
    [string]$Pionc = $env:PIONC,
    [string]$PionQbe = $env:PION_QBE,
    [string]$PionRtLib = $env:PION_RT_LIB,
    [string]$ClangBin = $env:CLANG_BIN,
    [switch]$Test
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$out = Join-Path $root "out"
New-Item -ItemType Directory -Force $out | Out-Null

$dotnet = if ($env:DOTNET_EXE) { $env:DOTNET_EXE } else { "dotnet" }
& $dotnet publish (Join-Path $root "recorder\ReplayRecorder.csproj") -c $Configuration -p:Platform=x64 -o $out --nologo -v quiet
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$viewerArgs = @{ Configuration = $Configuration }
if ($Pionc) { $viewerArgs.Pionc = $Pionc }
if ($PionQbe) { $viewerArgs.PionQbe = $PionQbe }
if ($PionRtLib) { $viewerArgs.PionRtLib = $PionRtLib }
if ($ClangBin) { $viewerArgs.ClangBin = $ClangBin }
if ($Test) { $viewerArgs.Test = $true }
& (Join-Path $PSScriptRoot "build-viewer.ps1") @viewerArgs
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "ScreenReplay: $out\ScreenReplay.exe"
