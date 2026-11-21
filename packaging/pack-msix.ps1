param(
  # the replay window built (scripts/build-app.sh): the folder holding ScreenReplayViewer.exe
  [Parameter(Mandatory)][string]$Viewer,
  # Partner Center's Product identity of the reserved name (Store ID 9PCZQK5BVPC6, reserved 2026-11-14)
  [string]$Name = "pengx17.ScreenReplay",
  [string]$Publisher = "CN=0A62AE73-FF5C-4B40-9E2B-F24486072C86",
  [string]$PublisherDisplayName = "pengx17",
  [string]$Version = "0.1.18.0",
  [string]$Out = ""
)
# Makes ScreenReplay's MSIX for the Microsoft Store: the recorder published with its own .NET runtime (the Store cannot
# require the .NET Desktop Runtime), trimmed to what it uses (recorder/ReplayRecorder.csproj says what is kept whole),
# the replay window beside it, the tiles made from site/img/icon.png, the manifest filled in, and makeappx's package.
# Unsigned: the Store signs what it is given; a local test signs it with signtool and a certificate whose subject is
# $Publisher.
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path "$PSScriptRoot\..").Path
# (srn\out-msix unless asked: $PSScriptRoot is empty in a param() default under `powershell -File`, which put it at
# C:\out-msix)
if (-not $Out) { $Out = "$PSScriptRoot\..\out-msix" }
$Out = [IO.Path]::GetFullPath($Out)
$stage = Join-Path $Out 'stage'
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Force "$stage\Assets" | Out-Null

dotnet publish "$repo\recorder\ReplayRecorder.csproj" -c Release -p:Platform=x64 -r win-x64 --self-contained true -p:PublishTrimmed=true -o $stage
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed" }
Get-ChildItem $stage -Filter *.pdb | Remove-Item
# (what only a debugger attached or a dump taken uses: about 7 MB the program never loads)
Get-ChildItem $stage -File | Where-Object { $_.Name -match '^(createdump\.exe|mscordaccore.*\.dll|mscordbi\.dll|Microsoft\.DiaSymReader\.Native\..*\.dll)$' } | Remove-Item
Copy-Item (Join-Path $Viewer 'ScreenReplayViewer.exe') $stage
$git = (git -C $repo rev-parse --short HEAD).Trim()
Set-Content -Path "$stage\build.txt" -Value "$Version $git" -Encoding ascii

Add-Type -AssemblyName System.Drawing
$icon = [System.Drawing.Image]::FromFile("$repo\site\img\icon.png")
function Tile([string]$file, [int]$w, [int]$h, [double]$part) {
  $b = New-Object System.Drawing.Bitmap $w, $h
  $g = [System.Drawing.Graphics]::FromImage($b)
  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $g.Clear([System.Drawing.Color]::Transparent)
  $s = [int]([Math]::Min($w, $h) * $part)
  $g.DrawImage($icon, [int](($w - $s) / 2), [int](($h - $s) / 2), $s, $s)
  $b.Save("$stage\Assets\$file", [System.Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose(); $b.Dispose()
}
Tile 'StoreLogo.png' 50 50 1.0
Tile 'Square44x44Logo.png' 44 44 1.0
Tile 'Square44x44Logo.targetsize-44_altform-unplated.png' 44 44 1.0
Tile 'Square150x150Logo.png' 150 150 0.66
Tile 'Wide310x150Logo.png' 310 150 0.66
$icon.Dispose()

$m = Get-Content "$PSScriptRoot\AppxManifest.xml" -Raw -Encoding utf8
foreach ($k in 'Name', 'Publisher', 'PublisherDisplayName', 'Version') {
  $m = $m.Replace("`$$k`$", [Security.SecurityElement]::Escape((Get-Variable $k).Value))
}
[IO.File]::WriteAllText("$stage\AppxManifest.xml", $m, (New-Object Text.UTF8Encoding $false))

$kit = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\makeappx.exe" | Sort-Object FullName | Select-Object -Last 1
$msix = Join-Path $Out "ScreenReplay_$($Version)_x64.msix"
& $kit.FullName pack /o /d $stage /p $msix
if ($LASTEXITCODE -ne 0) { throw "makeappx failed" }
"$msix ($([Math]::Round((Get-Item $msix).Length / 1MB, 1)) MB)"
