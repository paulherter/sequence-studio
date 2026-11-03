# Embeds an .ico into an exe as its icon resource (RT_GROUP_ICON id 1 plus one RT_ICON per picture), so Explorer, the
# taskbar and the shortcuts show it. Uses the Win32 UpdateResource API: no extra tools. Run by scripts/win-installer.sh on
# the staged SQWinApp.exe; Window.swift loads resource 1 for the window icon.
param([Parameter(Mandatory)][string]$Exe, [Parameter(Mandatory)][string]$Ico)
$ErrorActionPreference = 'Stop'
Add-Type -Namespace SQ -Name Res -MemberDefinition @'
[DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern IntPtr BeginUpdateResourceW(string f, bool del);
[DllImport("kernel32.dll", SetLastError=true)] public static extern bool UpdateResourceW(IntPtr h, IntPtr type, IntPtr name, ushort lang, byte[] data, uint cb);
[DllImport("kernel32.dll", SetLastError=true)] public static extern bool EndUpdateResourceW(IntPtr h, bool discard);
'@
$b = [IO.File]::ReadAllBytes($Ico)
$n = [BitConverter]::ToUInt16($b, 4)
$h = [SQ.Res]::BeginUpdateResourceW($Exe, $false)
if ($h -eq [IntPtr]::Zero) { throw "BeginUpdateResource failed: $Exe" }
$grp = New-Object System.Collections.Generic.List[byte]
$grp.AddRange([byte[]](0, 0, 1, 0)); $grp.AddRange([BitConverter]::GetBytes([uint16]$n))
for ($i = 0; $i -lt $n; $i++) {
    $e = 6 + 16 * $i
    $size = [BitConverter]::ToUInt32($b, $e + 8); $off = [BitConverter]::ToUInt32($b, $e + 12)
    $data = New-Object byte[] $size; [Array]::Copy($b, $off, $data, 0, $size)
    $id = $i + 1
    if (-not [SQ.Res]::UpdateResourceW($h, [IntPtr]3, [IntPtr]$id, 0, $data, $size)) { throw "UpdateResource RT_ICON $id failed" }
    $grp.AddRange([byte[]]$b[$e..($e + 11)]); $grp.AddRange([BitConverter]::GetBytes([uint16]$id))
}
$g = $grp.ToArray()
if (-not [SQ.Res]::UpdateResourceW($h, [IntPtr]14, [IntPtr]1, 0, $g, $g.Length)) { throw 'UpdateResource RT_GROUP_ICON failed' }
if (-not [SQ.Res]::EndUpdateResourceW($h, $false)) { throw 'EndUpdateResource failed' }
'icon embedded: ' + $n + ' pictures'
