; Per-user installer for Sequence Studio on Windows (Inno Setup 6). Built on the PC by scripts/win-installer.sh, which
; stages the release build and passes /DAppVersion=<x.y> /DStageDir=<folder> /DOutDir=<folder>.
; No administrator rights: the app goes to %LOCALAPPDATA%\Programs\Sequence Studio, the file association and the
; uninstall entry to HKCU. Nothing is installed as a service and no firewall rule is added.
#ifndef AppVersion
  #define AppVersion "0.1"
#endif
#ifndef StageDir
  #define StageDir "stage"
#endif
#ifndef OutDir
  #define OutDir "out"
#endif

[Setup]
AppId={{6C1E2A57-3B0D-4F52-9A0E-5E51A7C0D2B4}
AppName=Sequence Studio
AppVersion={#AppVersion}
AppPublisher=Paul Herter
AppPublisherURL=https://getsequencestudio.com
AppSupportURL=https://github.com/paulherter/sequence-studio/issues
AppUpdatesURL=https://github.com/paulherter/sequence-studio/releases
DefaultDirName={autopf}\Sequence Studio
DefaultGroupName=Sequence Studio
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
LicenseFile={#StageDir}\LICENSE
OutputDir={#OutDir}
OutputBaseFilename=SequenceStudio-Setup-{#AppVersion}
Compression=lzma2/normal
SolidCompression=yes
WizardStyle=modern
UninstallDisplayName=Sequence Studio
UninstallDisplayIcon={app}\SQWinApp.exe
CloseApplications=yes
ChangesAssociations=yes

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked
Name: "assoc"; Description: "Open .sqproj projects with Sequence Studio"

[Files]
Source: "{#StageDir}\SQWinApp.exe"; DestDir: "{app}"; Flags: ignoreversion
; FFmpeg, ONNX Runtime, whisper.cpp, the Swift runtime and the VC++ runtime (app-local) beside the exe.
Source: "{#StageDir}\*.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#StageDir}\SubjectMask\*"; DestDir: "{app}\SubjectMask"; Flags: ignoreversion skipifsourcedoesntexist
Source: "{#StageDir}\SUPPORTERS.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#StageDir}\LICENSE"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\Sequence Studio"; Filename: "{app}\SQWinApp.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\Sequence Studio"; Filename: "{app}\SQWinApp.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Registry]
Root: HKCU; Subkey: "Software\Classes\.sqproj"; ValueType: string; ValueData: "SequenceStudio.Project"; Flags: uninsdeletevalue uninsdeletekeyifempty; Tasks: assoc
Root: HKCU; Subkey: "Software\Classes\SequenceStudio.Project"; ValueType: string; ValueData: "Sequence Studio project"; Flags: uninsdeletekey; Tasks: assoc
Root: HKCU; Subkey: "Software\Classes\SequenceStudio.Project\DefaultIcon"; ValueType: string; ValueData: "{app}\SQWinApp.exe,0"; Tasks: assoc
Root: HKCU; Subkey: "Software\Classes\SequenceStudio.Project\shell\open\command"; ValueType: string; ValueData: """{app}\SQWinApp.exe"" ""%1"""; Tasks: assoc

[Run]
Filename: "{app}\SQWinApp.exe"; Description: "Start Sequence Studio"; Flags: nowait postinstall skipifsilent
