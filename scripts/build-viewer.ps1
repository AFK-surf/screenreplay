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

$vcvars = "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
if (-not (Test-Path $vcvars)) {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere) {
        $vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        if ($vs) { $vcvars = Join-Path $vs "VC\Auxiliary\Build\vcvars64.bat" }
    }
}
if (-not (Test-Path $vcvars)) { throw "Visual Studio C++ tools (vcvars64.bat) not found" }

if (-not $Pionc) {
    $found = Get-Command pionc, pionc2 -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { $Pionc = $found.Source }
}
if (-not $Pionc -or -not (Test-Path $Pionc)) { throw "pionc not found (set PIONC or add pionc to PATH)" }
if (-not $PionQbe) {
    $siblingQbe = Join-Path (Split-Path -Parent $Pionc) "qbe.exe"
    if (Test-Path $siblingQbe) { $PionQbe = $siblingQbe }
}

if (-not $ClangBin) {
    foreach ($cand in @("C:\Users\$env:USERNAME\llvm-mingw\bin\clang.exe", "C:\Program Files\LLVM\bin\clang.exe")) {
        if (Test-Path $cand) { $ClangBin = $cand; break }
    }
    if (-not $ClangBin) {
        $foundClang = Get-Command clang -ErrorAction SilentlyContinue
        if ($foundClang) { $ClangBin = $foundClang.Source }
    }
}
if (-not $ClangBin -or -not (Test-Path $ClangBin)) { throw "clang.exe not found (set CLANG_BIN or install LLVM / llvm-mingw)" }
$clangDir = Split-Path -Parent $ClangBin
$clangxxBin = Join-Path $clangDir "clang++.exe"

$outDir = Join-Path $root "out"
$shimDir = Join-Path $outDir "shim"
New-Item -ItemType Directory -Force $outDir, $shimDir | Out-Null

$wv2Ver = "1.0.4258.31"
$wv2Dir = Join-Path (Split-Path -Parent $root) "invar\packages\host\native\webview2\$wv2Ver"
if (-not (Test-Path (Join-Path $wv2Dir "build\native\include\WebView2.h"))) {
    New-Item -ItemType Directory -Force $wv2Dir | Out-Null
    $nupkg = Join-Path $outDir "webview2-$wv2Ver.zip"
    Invoke-WebRequest -Uri "https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2/$wv2Ver" -OutFile $nupkg
    Expand-Archive -Path $nupkg -DestinationPath $wv2Dir -Force
    Remove-Item -Force $nupkg
}

# Thin MSVC-target wrapper so clang compiles Windows SDK/WinRT/WRL headers and links with MSVC link.exe
# when lld-link is not bundled (e.g. llvm-mingw).
$ccWrap = Join-Path $shimDir "clang_msvc.exe"
$cxxWrap = Join-Path $shimDir "clangxx_msvc.exe"
$wrapSrc = Join-Path $shimDir "clang_msvc.c"
$clangEsc = $ClangBin -replace '\\', '\\'
$clangxxEsc = $clangxxBin -replace '\\', '\\'
@"
#include <process.h>
#include <stdlib.h>
#include <string.h>
int main(int argc, char **argv) {
  const char **args = (const char **)malloc((size_t)(argc + 4) * sizeof(char *));
  if (!args) return 1;
#ifdef IS_CXX
  const char *exe = "$clangxxEsc";
#else
  const char *exe = "$clangEsc";
#endif
  int k = 0;
  args[k++] = exe;
  args[k++] = "--target=x86_64-pc-windows-msvc";
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "-fuse-ld=lld") == 0) continue;
    args[k++] = argv[i];
  }
  args[k] = NULL;
  return (int)_spawnv(_P_WAIT, exe, args);
}
"@ | Set-Content -Encoding ASCII $wrapSrc

$exeOut = Join-Path $outDir "ScreenReplayViewer.exe"
$cmdFile = Join-Path $outDir "build-viewer-$Configuration.cmd"
$buildLog = Join-Path $outDir "build-app.log"
$relFlag = if ($Configuration -eq "Release") { "--release" } else { "" }
$qbeLine = if ($PionQbe) { "@set `"PION_QBE=$PionQbe`"" } else { "" }
$rtLine = if ($PionRtLib) { "@set `"PION_RT_LIB=$PionRtLib`"" } else { "" }
$testLine = if ($Test) { "@`"$Pionc`" test . >> `"$buildLog`" 2>&1`r`n@if errorlevel 1 exit /b %ERRORLEVEL%" } else { "" }
@"
@call "$vcvars" >nul
@"$ClangBin" -O2 "$wrapSrc" -o "$ccWrap" > "$buildLog" 2>&1
@if errorlevel 1 exit /b %ERRORLEVEL%
@"$ClangBin" -O2 -DIS_CXX "$wrapSrc" -o "$cxxWrap" >> "$buildLog" 2>&1
@if errorlevel 1 exit /b %ERRORLEVEL%
@set "CC=$ccWrap"
@set "CXX=$cxxWrap"
@set "PION_WIN_ABI=msvc"
$qbeLine
$rtLine
@cd /d "$root"
@"$Pionc" build $relFlag . -o "$exeOut" >> "$buildLog" 2>&1
@if errorlevel 1 exit /b %ERRORLEVEL%
$testLine
@exit /b 0
"@ | Set-Content -Encoding ASCII $cmdFile

$p = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", "`"$cmdFile`"" -NoNewWindow -PassThru
$null = $p.Handle
$p.WaitForExit()
if ($p.ExitCode -ne 0) {
    if (Test-Path $buildLog) { Get-Content $buildLog | Select-Object -Last 80 }
    throw "ScreenReplayViewer build failed (exit $($p.ExitCode)); full log in $buildLog"
}
git -C $root rev-parse --short HEAD 2>$null | Set-Content -Encoding ASCII (Join-Path $outDir "build.txt")
$size = (Get-Item $exeOut).Length
Write-Host "build-viewer.ps1: $exeOut ($size bytes)"
