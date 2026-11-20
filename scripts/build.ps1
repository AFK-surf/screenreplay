param(
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release"
)

# Builds ScreenReplay into out/: the background recorder (ScreenReplay.exe, with its recording library: recording/)
# and the replay window (ScreenReplayViewer.exe). Needs Visual Studio 2022 with C++, the .NET 10 SDK, Git Bash and MoonBit
# (on PATH, or MBUI_TOOLS pointing at a directory holding moon/).
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs = if (Test-Path $vswhere) {
    & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
} else {
    "C:\Program Files\Microsoft Visual Studio\2022\Community"
}
$vcvars = Join-Path $vs "VC\Auxiliary\Build\vcvars64.bat"
$bash = @("$env:ProgramFiles\Git\bin\bash.exe", "${env:ProgramFiles(x86)}\Git\bin\bash.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $bash) { throw "Git Bash not found" }
$out = Join-Path $root "out"
New-Item -ItemType Directory -Force $out | Out-Null

$dotnet = if ($env:DOTNET_EXE) { $env:DOTNET_EXE } else { "dotnet" }
& $dotnet publish (Join-Path $root "recorder\ReplayRecorder.csproj") -c $Configuration -p:Platform=x64 -o $out --nologo -v quiet
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$mode = if ($Configuration -eq "Release") { "release" } else { "debug" }
& cmd /c "`"$vcvars`" >nul && set `"MODE=$mode`" && `"$bash`" `"$root\scripts\build-app.sh`""
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Write-Host "ScreenReplay: $out\ScreenReplay.exe"
