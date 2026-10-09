; Inno Setup script for 3D Forest Height Studio.
; Build:  ISCC.exe packaging\installer.iss          (after packaging\build.ps1 has produced dist\)
;         ISCC.exe /DAppVersion=1.2.3 packaging\installer.iss
#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#define AppName "3D Forest Height Studio"
#define RepoUrl "https://github.com/pratyush-dh/3d-forest-height-studio"

[Setup]
; AppId must never change between versions: it is how upgrades and uninstall find the app.
AppId={{C47779F2-3E5C-4FC6-8988-624E311543D7}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=Pratyush Dhungana
AppPublisherURL={#RepoUrl}
AppSupportURL={#RepoUrl}/issues
AppUpdatesURL={#RepoUrl}/releases
VersionInfoVersion={#AppVersion}
; Per-user install: no administrator prompt. {autopf} becomes %LOCALAPPDATA%\Programs for non-admin installs.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
DefaultDirName={autopf}\{#AppName}
DisableProgramGroupPage=yes
DisableDirPage=auto
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#SourcePath}..\release
OutputBaseFilename=3D-Forest-Height-Studio-Setup-{#AppVersion}
SetupIconFile={#SourcePath}studio.ico
UninstallDisplayIcon={app}\studio.ico
LicenseFile={#SourcePath}..\LICENSE
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
CloseApplicationsFilter=*.exe,*.dll
RestartApplications=no

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Shortcuts:"; Flags: unchecked

[Files]
Source: "{#SourcePath}..\dist\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\Studio.vbs"""; WorkingDir: "{app}"; IconFilename: "{app}\studio.ico"; Comment: "Interactive 3D forest canopy height maps"
Name: "{autodesktop}\{#AppName}"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\Studio.vbs"""; WorkingDir: "{app}"; IconFilename: "{app}\studio.ico"; Tasks: desktopicon

[UninstallDelete]
; Safety net: remove anything created inside the program folders after installation.
Type: filesandordirs; Name: "{app}\studio"
Type: filesandordirs; Name: "{app}\lib"
Type: filesandordirs; Name: "{app}\R"

[Run]
Filename: "{sys}\wscript.exe"; Parameters: """{app}\Studio.vbs"""; WorkingDir: "{app}"; Description: "Launch {#AppName}"; Flags: postinstall nowait skipifsilent

[Code]
// The program folder is removed automatically. Downloaded tiles and caches can be several GB and live in the
// user's data folder, so ask before deleting them (silent uninstalls keep them).
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  DataDir: String;
begin
  if CurUninstallStep = usPostUninstall then
  begin
    DataDir := ExpandConstant('{localappdata}\3D Forest Height Studio');
    if (not UninstallSilent) and DirExists(DataDir) then
      if MsgBox('Also delete the data the app downloaded (tiles, boundaries, cache, settings)?' + #13#10#13#10 + DataDir,
                mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES then
        DelTree(DataDir, True, True, True);
  end;
end;
