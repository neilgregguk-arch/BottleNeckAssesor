#if VER < EncodeVer(6,3,0)
  #error WPBD requires Inno Setup 6.3 or newer.
#endif
#ifndef AppVersion
  #error AppVersion is required. Run Build-Installer.ps1.
#endif
#ifndef PublishDir
  #error PublishDir is required. Run Build-Installer.ps1.
#endif

#define ProductName "Windows Performance Bottleneck Detector"
#define Publisher "WPBD Project"
#define DesktopExe "WPBD.Desktop.exe"

[Setup]
; Stable identity across releases. Inno uses this for the Installed Apps entry.
AppId={{A22221A0-DA2E-4D5F-9288-B11195F22847}
AppName={#ProductName}
AppVersion={#AppVersion}
AppPublisher={#Publisher}
AppComments=Local Windows workstation performance diagnostics
VersionInfoVersion={#AppVersion}
VersionInfoCompany={#Publisher}
VersionInfoDescription=Windows Performance Bottleneck Detector Setup
VersionInfoProductName={#ProductName}
VersionInfoProductVersion={#AppVersion}
DefaultDirName={localappdata}\Programs\WPBD
DisableDirPage=yes
UsePreviousAppDir=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64os
ArchitecturesInstallIn64BitMode=x64os
MinVersion=10.0.14393
DisableProgramGroupPage=yes
OutputBaseFilename=WPBD-Setup-{#AppVersion}-x64
SetupIconFile=..\desktop\WPBD.Desktop\Assets\WPBD.ico
UninstallDisplayIcon={app}\{#DesktopExe}
AppMutex=WPBD.Desktop.InstallationGuard
CloseApplications=no
RestartApplications=no
SetupLogging=yes
WizardStyle=modern
Compression=lzma2/max
SolidCompression=yes

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked

[Files]
Source: "{#PublishDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{userprograms}\{#ProductName}"; Filename: "{app}\{#DesktopExe}"; WorkingDir: "{app}"
Name: "{userdesktop}\{#ProductName}"; Filename: "{app}\{#DesktopExe}"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#DesktopExe}"; Description: "Launch {#ProductName}"; WorkingDir: "{app}"; Flags: nowait postinstall skipifsilent runasoriginaluser
