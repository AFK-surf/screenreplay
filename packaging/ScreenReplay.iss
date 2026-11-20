; ScreenReplay's standalone per-user installer (ScreenReplay-Setup-<version>.exe), no administrator required.
; Installs to %LOCALAPPDATA%\Programs\ScreenReplay, adds a Start menu shortcut, an entry in Settings > Apps,
; and optionally sets HKCU\Software\Microsoft\Windows\CurrentVersion\Run\Replay ("<app>\ScreenReplay.exe" --background).
;
; Run silently by ScreenReplay itself to update (/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /UPDATE):
; quits the running instance cleanly (ScreenReplay.exe --quit), preserves existing autostart / desktop shortcut choices,
; and restarts background recording (--background --updated).

#ifndef AppVer
  #error AppVer not given: packaging\pack-setup.ps1 gives it
#endif
#ifndef StageDir
  #define StageDir "..\out\stage"
#endif
#ifndef Repo
  #define Repo ".."
#endif
#ifndef AppIdOverride
  #define MyAppId "{{9C4A8E17-5D2B-4E91-A763-8F10B2C5D9E4}"
#else
  #define MyAppId AppIdOverride
#endif

[Setup]
AppId={#MyAppId}
AppName=ScreenReplay
AppVersion={#AppVer}
AppVerName=ScreenReplay {#AppVer}
AppPublisher=pengx17
AppPublisherURL=https://screenreplay.pages.dev
VersionInfoVersion={#AppVer}.0
DefaultDirName={localappdata}\Programs\ScreenReplay
DisableDirPage=auto
DisableProgramGroupPage=yes
DisableReadyPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.22000
OutputDir={#Repo}\out\setup
OutputBaseFilename=ScreenReplay-Setup-{#AppVer}
SetupIconFile={#StageDir}\ScreenReplay.ico
UninstallDisplayIcon={app}\ScreenReplay.exe
UninstallDisplayName=ScreenReplay
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=no
RestartApplications=no
ShowLanguageDialog=auto

[Languages]
Name: "chs"; MessagesFile: "{#Repo}\packaging\ChineseSimplified.isl"
Name: "en"; MessagesFile: "compiler:Default.isl"

[CustomMessages]
chs.AutoStart=登录 Windows 时自动在后台启动录制
en.AutoStart=Start background recording when signing in to Windows
chs.Launch=立即运行 ScreenReplay
en.Launch=Run ScreenReplay now

[Tasks]
Name: "autostart"; Description: "{cm:AutoStart}"
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; Flags: unchecked

[Files]
Source: "{#StageDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs

[Icons]
Name: "{userprograms}\ScreenReplay"; Filename: "{app}\ScreenReplay.exe"; WorkingDir: "{app}"; IconFilename: "{app}\ScreenReplay.ico"; Check: not IsTestInstall
Name: "{userdesktop}\ScreenReplay"; Filename: "{app}\ScreenReplay.exe"; WorkingDir: "{app}"; IconFilename: "{app}\ScreenReplay.ico"; Tasks: desktopicon; Check: not IsUpdate and not IsTestInstall

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "Replay"; ValueData: """{app}\ScreenReplay.exe"" --background"; Tasks: autostart; Check: not IsUpdate and not IsTestInstall
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: none; ValueName: "Replay"; Flags: uninsdeletevalue; Check: not IsTestInstall

[Run]
Filename: "{app}\ScreenReplay.exe"; Description: "{cm:Launch}"; Flags: nowait postinstall skipifsilent
Filename: "{app}\ScreenReplay.exe"; Parameters: "--background --updated"; Flags: nowait; Check: IsUpdate

[Code]
function IsUpdate(): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 1 to ParamCount do
    if CompareText(ParamStr(I), '/UPDATE') = 0 then
    begin
      Result := True;
      Exit;
    end;
end;

function IsTestInstall(): Boolean;
begin
  Result := GetEnv('REPLAY_TEST_UPDATE') <> '';
end;

var
  Installed: Boolean;

function ProbeUnlocked(const FilePath: String): Boolean;
begin
  Result := True;
  if not FileExists(FilePath) then Exit;
  Result := False;
  if FileCopy(FilePath, FilePath + '.probe', False) then
  begin
    if DeleteFile(FilePath) then
    begin
      RenameFile(FilePath + '.probe', FilePath);
      Result := True;
      Exit;
    end;
    DeleteFile(FilePath + '.probe');
  end;
end;

function QuitRunning(const Dir: String): Boolean;
var
  Exe, Viewer: String;
  Code, I: Integer;
begin
  Exe := Dir + '\ScreenReplay.exe';
  Viewer := Dir + '\ScreenReplayViewer.exe';
  Result := True;
  if not FileExists(Exe) and not FileExists(Viewer) then Exit;
  if FileExists(Exe) then
    Exec(Exe, '--quit', Dir, SW_HIDE, ewWaitUntilTerminated, Code);
  for I := 1 to 30 do
  begin
    if ProbeUnlocked(Exe) and ProbeUnlocked(Viewer) then Exit;
    Sleep(200);
  end;
  Result := False;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  if QuitRunning(ExpandConstant('{app}')) then
    Result := ''
  else
    Result := 'ScreenReplay is still running: quit it from the tray icon and run the installer again.';
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssDone then Installed := True;
end;

procedure DeinitializeSetup();
var
  Code: Integer;
begin
  if IsUpdate() and not Installed and FileExists(ExpandConstant('{app}\ScreenReplay.exe')) then
    Exec(ExpandConstant('{app}\ScreenReplay.exe'), '--background', ExpandConstant('{app}'), SW_HIDE, ewNoWait, Code);
end;

function InitializeUninstall(): Boolean;
begin
  QuitRunning(ExpandConstant('{app}'));
  Result := True;
end;
