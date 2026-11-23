; Per-user installer (no administrator rights). Build: ISCC installer\gpu_lend.iss  (after `flutter build windows --release`)
#ifndef AppVersion
#define AppVersion "2.0.0"
#endif
[Setup]
AppId={{6B0F2E8A-4C61-4C0E-9A55-3D7A1B9E2F10}
AppName=GPU Lend
AppVersion={#AppVersion}
AppPublisher=GPU Lend contributors
DefaultDirName={localappdata}\Programs\GpuLend
DefaultGroupName=GPU Lend
PrivilegesRequired=lowest
OutputDir=..\build\installer
OutputBaseFilename=GpuLend-Setup
Compression=lzma2
SolidCompression=yes
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\gpu_lend.exe
CloseApplications=force
RestartApplications=no
DisableProgramGroupPage=yes
WizardStyle=modern
[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion
[Icons]
Name: "{autoprograms}\GPU Lend"; Filename: "{app}\gpu_lend.exe"
Name: "{autodesktop}\GPU Lend"; Filename: "{app}\gpu_lend.exe"
[Run]
Filename: "{app}\gpu_lend.exe"; Description: "Start GPU Lend"; Flags: nowait postinstall runasoriginaluser
