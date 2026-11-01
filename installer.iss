; Simple Player installer (build with Inno Setup: ISCC.exe installer.iss)
[Setup]
AppId={{133CE53F-8BF4-4E97-870B-D947356F5BA3}
AppName=Simple Player
AppVersion=1.0
DefaultDirName={autopf}\Simple Player
DefaultGroupName=Simple Player
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=dist
OutputBaseFilename=SimplePlayer-Setup
SetupIconFile=icon.ico
UninstallDisplayIcon={app}\SimplePlayer.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked

[Files]
Source: "mpv\SimplePlayer.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "config\mpv.conf"; DestDir: "{app}\config"; Flags: ignoreversion
Source: "config\input.conf"; DestDir: "{app}\config"; Flags: ignoreversion
Source: "config\scripts\simple-player.lua"; DestDir: "{app}\config\scripts"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\Simple Player"; Filename: "{app}\SimplePlayer.exe"; Parameters: "--config-dir=""{app}\config"""; IconFilename: "{app}\SimplePlayer.exe"
Name: "{autodesktop}\Simple Player"; Filename: "{app}\SimplePlayer.exe"; Parameters: "--config-dir=""{app}\config"""; IconFilename: "{app}\SimplePlayer.exe"; Tasks: desktopicon

; makes "Simple Player" show up in the "Open with" list for video files
[Registry]
Root: HKCU; Subkey: "Software\Classes\Applications\SimplePlayer.exe"; ValueType: string; ValueName: "FriendlyAppName"; ValueData: "Simple Player"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Applications\SimplePlayer.exe\shell\open\command"; ValueType: string; ValueData: """{app}\SimplePlayer.exe"" --config-dir=""{app}\config"" ""%1"""

[Run]
Filename: "{app}\SimplePlayer.exe"; Parameters: "--config-dir=""{app}\config"""; Description: "Launch Simple Player"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: filesandordirs; Name: "{app}\config"
