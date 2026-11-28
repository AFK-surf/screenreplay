param(
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release",
    [string]$Pionc = $env:PIONC,
    [string]$PionQbe = $env:PION_QBE,
    [string]$PionRtLib = $env:PION_RT_LIB,
    [string]$ClangBin = $env:CLANG_BIN,
    [string]$StageDir = "",
    [switch]$Test
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$out = Join-Path $root "out"
New-Item -ItemType Directory -Force $out | Out-Null

$dotnet = if ($env:DOTNET_EXE) { $env:DOTNET_EXE } else { "dotnet" }
$csproj = Join-Path $root "recorder\ReplayRecorder.csproj"
$dotnetLog = Join-Path $out "dotnet-publish.log"

function Quote-WinArg([string]$a) {
    if ($a -eq '') { return '""' }
    if ($a -notmatch '[\s"]') { return $a }
    $escaped = [regex]::Replace($a, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

$stageAbs = ""
if ($StageDir) {
    $stageAbs = if ([IO.Path]::IsPathRooted($StageDir)) { $StageDir } else { Join-Path (Get-Location).Path $StageDir }
    if (Test-Path -LiteralPath $stageAbs -PathType Leaf) {
        throw "StageDir points to an existing file: $stageAbs"
    }
    if ((Test-Path -LiteralPath $stageAbs -PathType Container) -and @(Get-ChildItem -LiteralPath $stageAbs -Force).Count -gt 0) {
        throw "StageDir already exists and is not empty: $stageAbs"
    }
    [void][IO.Directory]::CreateDirectory($stageAbs)
    $dotnetArgs = @(
        "publish", $csproj,
        "-c", $Configuration,
        "-p:Platform=x64",
        "-r", "win-x64",
        "--self-contained", "true",
        "-p:PublishTrimmed=true",
        "-m:1",
        "-o", $stageAbs,
        "--nologo",
        "-v", "quiet"
    )
} else {
    $dotnetArgs = @(
        "publish", $csproj,
        "-c", $Configuration,
        "-p:Platform=x64",
        "-o", $out,
        "--nologo",
        "-v", "quiet"
    )
}

# Run dotnet publish in parallel with build-viewer.ps1 via ProcessStartInfo
# (ArgumentList on PowerShell 7+, CommandLineToArgvW-escaped Arguments on Windows PowerShell 5.1)
# so paths with spaces, brackets, or Unicode characters are passed as exact argv entries.
$psi = [System.Diagnostics.ProcessStartInfo]::new($dotnet)
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
if ($null -ne $psi.PSObject.Properties['ArgumentList']) {
    foreach ($a in $dotnetArgs) { [void]$psi.ArgumentList.Add($a) }
} else {
    $psi.Arguments = ($dotnetArgs | ForEach-Object { Quote-WinArg $_ }) -join ' '
}
$dotnetProc = [System.Diagnostics.Process]::Start($psi)
$stdoutTask = $dotnetProc.StandardOutput.ReadToEndAsync()
$stderrTask = $dotnetProc.StandardError.ReadToEndAsync()

$viewerArgs = @{ Configuration = $Configuration }
if ($Pionc) { $viewerArgs.Pionc = $Pionc }
if ($PionQbe) { $viewerArgs.PionQbe = $PionQbe }
if ($PionRtLib) { $viewerArgs.PionRtLib = $PionRtLib }
if ($ClangBin) { $viewerArgs.ClangBin = $ClangBin }
if ($Test) { $viewerArgs.Test = $true }

$viewerExit = 0
$dotnetExit = 0
try {
    $global:LASTEXITCODE = 0
    & (Join-Path $PSScriptRoot "build-viewer.ps1") @viewerArgs
    $viewerExit = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 0 }
} finally {
    $dotnetProc.WaitForExit()
    $dotnetExit = $dotnetProc.ExitCode
    $stdoutText = $stdoutTask.GetAwaiter().GetResult()
    $stderrText = $stderrTask.GetAwaiter().GetResult()
    $combinedLog = ($stdoutText + "`n" + $stderrText).Trim()
    [IO.File]::WriteAllText($dotnetLog, $combinedLog, [Text.UTF8Encoding]::new($false))
    if ($dotnetExit -ne 0 -and $combinedLog) {
        ($combinedLog -split "`r?`n") | Select-Object -Last 80 | ForEach-Object { Write-Host $_ }
    }
    $dotnetProc.Dispose()
}

if ($dotnetExit -ne 0) {
    throw "dotnet publish failed (exit $dotnetExit); full log in $dotnetLog"
}
if ($stageAbs) {
    Get-ChildItem -LiteralPath $stageAbs -Filter *.pdb | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
    Get-ChildItem -LiteralPath $stageAbs -File | Where-Object { $_.Name -match '^(createdump\.exe|mscordaccore.*\.dll|mscordbi\.dll|Microsoft\.DiaSymReader\.Native\..*\.dll)$' } | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
}
if ($viewerExit -ne 0) { exit $viewerExit }

$appOut = if ($stageAbs) { Join-Path $stageAbs "ScreenReplay.exe" } else { Join-Path $out "ScreenReplay.exe" }
Write-Host "ScreenReplay: $appOut"
