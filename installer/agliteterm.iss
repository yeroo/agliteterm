; agliteterm installer (Inno Setup 6) — per-user, no admin. Self-contained: the client, its
; pinned copy of the agwinterm pty-host + core dll, and the bundled fonts.
; Built via installer\build.ps1 (stages to stage\ then runs ISCC on this file).

#define AppName    "agliteterm"
#define AppVersion "0.17.6"
#define AppExe     "agliteterm.exe"
#define AppPublisher "Boris Kudriashov"

[Setup]
AppId={{E0ACBA4E-AAD3-4689-9234-66D3CD207A6A}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
VersionInfoVersion={#AppVersion}
DefaultDirName={localappdata}\Programs\agliteterm
DisableProgramGroupPage=yes
DisableDirPage=auto
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
SetupIconFile=..\assets\agliteterm.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
WizardStyle=modern
Compression=lzma2
SolidCompression=yes
OutputDir=Output
OutputBaseFilename=agliteterm-setup-{#AppVersion}

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Shortcuts:"

[Files]
Source: "stage\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[InstallDelete]
; ≤0.16.2 shipped the main app's icon file for the shortcuts; the icon is embedded in the exe now.
Type: files; Name: "{app}\agwinterm.ico"

[Icons]
; No IconFilename: the exe embeds the lite icon (VGA black + cyan), shortcuts pick it up.
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}";  Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "Launch {#AppName}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: filesandordirs; Name: "{app}"
