; Per-user installer for the Rust Sequence Studio on Windows (Inno Setup 6). Built by packaging/windows/build-installer.ps1
; (`cargo xtask package` on Windows), which stages the release build and passes /DAppVersion=<x.y> /DStageDir=<folder> /DOutDir=<folder>.
; No administrator rights: the app goes to %LOCALAPPDATA%\Programs\Sequence Studio, the file association and the
; uninstall entry to HKCU. Nothing is installed as a service and no firewall rule is added.
#ifndef AppName
  #define AppName "Sequence Studio"
#endif
#ifndef FilePrefix
  #define FilePrefix "SequenceStudio"
#endif
#ifndef Aumid
  #define Aumid "SequenceStudio.App"
#endif
#ifndef AppGuid
  #define AppGuid "6C1E2A57-3B0D-4F52-9A0E-5E51A7C0D2B4"
#endif
#ifndef AppVersion
  #define AppVersion "0.1"
#endif
#ifndef Stamp
  #define Stamp "dev"
#endif
#ifndef StageDir
  #define StageDir "stage"
#endif
#ifndef OutDir
  #define OutDir "out"
#endif

[Setup]
AppId={{{#AppGuid}}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=Paul Herter
AppPublisherURL=https://getsequencestudio.com
AppSupportURL=https://github.com/paulherter/sequence-studio/issues
AppUpdatesURL=https://github.com/paulherter/sequence-studio/releases
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
LicenseFile={#StageDir}\LICENSE
OutputDir={#OutDir}
OutputBaseFilename={#FilePrefix}-Setup-{#AppVersion}-{#Stamp}
Compression=lzma2/normal
SolidCompression=yes
WizardStyle=modern
UninstallDisplayName={#AppName}
SetupIconFile={#StageDir}\SequenceStudio.ico
UninstallDisplayIcon={app}\SequenceStudio.exe
CloseApplications=yes
ChangesAssociations=yes

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked
Name: "assoc"; Description: "Open .sqproj projects with Sequence Studio"

[Files]
Source: "{#StageDir}\SequenceStudio.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#StageDir}\SequenceStudio.ico"; DestDir: "{app}"; Flags: ignoreversion
; FFmpeg, ONNX Runtime and the VC++ runtime (app-local) beside the exe; the fonts in Fonts (the app looks in <exe folder>\Fonts).
Source: "{#StageDir}\*.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#StageDir}\Fonts\*"; DestDir: "{app}\Fonts"; Flags: ignoreversion recursesubdirs
; EdgeTAM ONNX parts (Apache-2.0: Licenses\APACHE-2.0.txt + THIRD_PARTY.md), where sq-analysis looks: <exe folder>\SubjectMask.
Source: "{#StageDir}\SubjectMask\*"; DestDir: "{app}\SubjectMask"; Flags: ignoreversion skipifsourcedoesntexist
Source: "{#StageDir}\SUPPORTERS.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#StageDir}\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#StageDir}\LICENSE-ADDITIONAL-TERMS.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#StageDir}\ORT-LICENSE-MIT.txt"; DestDir: "{app}\Licenses"; Flags: ignoreversion
Source: "{#StageDir}\Licenses\*"; DestDir: "{app}\Licenses"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\SequenceStudio.exe"; WorkingDir: "{app}"; IconFilename: "{app}\SequenceStudio.ico"; AppUserModelID: "{#Aumid}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\SequenceStudio.exe"; WorkingDir: "{app}"; IconFilename: "{app}\SequenceStudio.ico"; Tasks: desktopicon

[Registry]
Root: HKCU; Subkey: "Software\Classes\AppUserModelId\{#Aumid}"; ValueType: string; ValueName: "DisplayName"; ValueData: "{#AppName}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\.sqproj"; ValueType: string; ValueData: "SequenceStudio.Project"; Flags: uninsdeletevalue uninsdeletekeyifempty; Tasks: assoc
Root: HKCU; Subkey: "Software\Classes\SequenceStudio.Project"; ValueType: string; ValueData: "Sequence Studio project"; Flags: uninsdeletekey; Tasks: assoc
Root: HKCU; Subkey: "Software\Classes\SequenceStudio.Project\DefaultIcon"; ValueType: string; ValueData: "{app}\SequenceStudio.ico"; Tasks: assoc
Root: HKCU; Subkey: "Software\Classes\SequenceStudio.Project\shell\open\command"; ValueType: string; ValueData: """{app}\SequenceStudio.exe"" ""%1"""; Tasks: assoc

[Run]
Filename: "{app}\SequenceStudio.exe"; Description: "Start Sequence Studio"; Flags: nowait postinstall skipifsilent
