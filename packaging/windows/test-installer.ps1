# End-to-end check of the Windows installer on a PC: silent install into a temp folder, start on a clean PATH (once with
# the start screen, once on -Project), uninstall, check nothing is left. Prints one "installer test:" line per step.
# Usage: powershell -File packaging\windows\test-installer.ps1 -Setup <SequenceStudio-Setup-x.y.z.exe> [-Project <.sqproj>] [-Hold 12]
# -Inno checks the old Inno Setup installer instead of the setup program (sq-installer).
param([Parameter(Mandatory)][string]$Setup, [string]$Project, [int]$Hold = 12, [switch]$Inno)
$ErrorActionPreference = 'Stop'
function Say($m) { Write-Host "installer test: $m" }
$dir = Join-Path $env:TEMP 'sq-installer-test'
Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
$log = Join-Path $env:TEMP 'sq-installer-test.log'
function Install($extra) {
    if ($Inno) { Start-Process $Setup -ArgumentList "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CURRENTUSER /DIR=`"$dir`" /TASKS=assoc $extra" -Wait -PassThru }
    else { Start-Process $Setup -ArgumentList "--quiet --dir `"$dir`"" -Wait -PassThru }
}
function Uninstall {
    if ($Inno) { return Start-Process (Join-Path $dir 'unins000.exe') -ArgumentList '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' -Wait -PassThru }
    # The uninstaller hands over to a copy in %TEMP% and returns at once: wait until the folder is gone.
    $u = Start-Process (Join-Path $dir 'Uninstall Sequence Studio.exe') -ArgumentList '--uninstall --quiet' -Wait -PassThru
    for ($i = 0; $i -lt 60 -and (Test-Path (Join-Path $dir 'SequenceStudio.exe')); $i++) { Start-Sleep -Seconds 1 }
    return $u
}
$p = Install "/LOG=`"$log`""
Say "install exit $($p.ExitCode)"
$exe = Join-Path $dir 'SequenceStudio.exe'
Say ("files: exe " + (Test-Path $exe) + ", Fonts " + (Test-Path (Join-Path $dir 'Fonts')) + ", ffmpeg dlls " + @(Get-ChildItem $dir -Filter 'av*.dll').Count + ", uninstaller " + @(Get-ChildItem $dir -Filter '*nins*.exe').Count)
Add-Type -AssemblyName System.Drawing
Say ("exe icon: " + [System.Drawing.Icon]::ExtractAssociatedIcon($exe).Width + " px")
Say ("AUMID key: " + (Test-Path 'HKCU:\Software\Classes\AppUserModelId\SequenceStudio.App') + ", Start Menu shortcut: " + (Test-Path (Join-Path ([Environment]::GetFolderPath('Programs')) 'Sequence Studio.lnk')))
Say ("assoc: " + (Get-ItemProperty 'HKCU:\Software\Classes\.sqproj' -ErrorAction SilentlyContinue).'(default)')
$sm = Join-Path $dir 'SubjectMask'
Say ("EdgeTAM parts: " + @(Get-ChildItem $sm -Filter 'edgetam_*.onnx' -ErrorAction SilentlyContinue).Count + " of 5 in SubjectMask, APACHE-2.0.txt " + (Test-Path (Join-Path $dir 'Licenses\APACHE-2.0.txt')))
$env:PATH = "$env:SystemRoot\System32;$env:SystemRoot"
# Dialogs: a missing DLL shows "System Error" and the process stays alive without a real window.
$shot = Join-Path $env:TEMP 'sq-installer-shot.png'
Remove-Item $shot -ErrorAction SilentlyContinue
$sp = Start-Process $exe -ArgumentList "--ui-shot `"$shot`" --size 1280x720 --scale 1" -WorkingDirectory $dir -PassThru
if (-not $sp.WaitForExit(60000)) { Stop-Process $sp -Force; Say 'ui-shot: TIMEOUT (hung, probably a dialog)' } else { Say ("ui-shot: exit $($sp.ExitCode), png " + (Test-Path $shot) + $(if (Test-Path $shot) { ", " + (Get-Item $shot).Length + " bytes" })) }
foreach ($mode in @('start screen', 'project')) {
    if ($mode -eq 'project' -and -not $Project) { continue }
    $proc = if ($mode -eq 'project') { Start-Process $exe -ArgumentList "`"$Project`"" -WorkingDirectory $dir -PassThru } else { Start-Process $exe -WorkingDirectory $dir -PassThru }
    Start-Sleep -Seconds $Hold
    $proc.Refresh()
    $sys = @(Get-Process | Where-Object { $_.MainWindowTitle -like '*System Error*' -or $_.MainWindowTitle -like '*Systemfehler*' }).Count
    Say "${mode}: System Error dialogs $sys"
    Say "${mode}: running $(-not $proc.HasExited), window '$($proc.MainWindowTitle)', memory $([int]($proc.WorkingSet64 / 1MB)) MB"
    if (-not $proc.HasExited) { Stop-Process $proc -Force }
    Start-Sleep -Seconds 1
}
# Upgrade over the existing install keeps the preferences (they live in %APPDATA%, not in the install folder).
$support = Join-Path $env:APPDATA 'Sequence Studio'
New-Item -ItemType Directory -Force $support | Out-Null
$marker = Join-Path $support 'sq-installer-test.marker'
Set-Content $marker 'keep'
Set-Content (Join-Path $dir 'stale.txt') 'old'
$p2 = Install ""
Say "upgrade exit $($p2.ExitCode), preferences kept $(Test-Path $marker), exe present $(Test-Path $exe)"
$u = Uninstall
Start-Sleep -Seconds 2
Say "uninstall exit $($u.ExitCode), SubjectMask folder left $(Test-Path $sm)"
Say ("left after: files " + @(Get-ChildItem $dir -Recurse -ErrorAction SilentlyContinue | Where-Object Name -ne 'stale.txt').Count + " (a file the installer did not write stays by design)" + ", assoc key " + (Test-Path 'HKCU:\Software\Classes\SequenceStudio.Project') + ", .sqproj key " + (Test-Path 'HKCU:\Software\Classes\.sqproj') + ", AUMID key " + (Test-Path 'HKCU:\Software\Classes\AppUserModelId\SequenceStudio.App') + ", shortcut " + (Test-Path (Join-Path ([Environment]::GetFolderPath('Programs')) 'Sequence Studio.lnk')) + ", preferences kept " + (Test-Path $marker))
Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $marker -ErrorAction SilentlyContinue
