//! What the setup program asks of Windows: HKCU registry values, `.lnk` shortcuts with an AppUserModelID, running
//! instances of a program and a polite close, delete-at-restart, the known folders and two facts for the log and the
//! theme. The engine (`sq-setup-engine`) calls these through its `Host` trait.

use std::ffi::{OsString, c_void};
use std::io;
use std::os::windows::ffi::{OsStrExt, OsStringExt};
use std::path::{Path, PathBuf};
use windows::Win32::Foundation::{CloseHandle, ERROR_FILE_NOT_FOUND, ERROR_SUCCESS, HWND, LPARAM, WIN32_ERROR, WPARAM};
use windows::Win32::Storage::EnhancedStorage::PKEY_AppUserModel_ID;
use windows::Win32::Storage::FileSystem::{MOVEFILE_DELAY_UNTIL_REBOOT, MoveFileExW};
use windows::Win32::System::Com::StructuredStorage::{PROPVARIANT, PROPVARIANT_0, PROPVARIANT_0_0, PROPVARIANT_0_0_0};
use windows::Win32::System::Com::{
    CLSCTX_INPROC_SERVER, COINIT_APARTMENTTHREADED, CoCreateInstance, CoInitializeEx, CoTaskMemFree, CoUninitialize,
    IPersistFile,
};
use windows::Win32::System::Diagnostics::ToolHelp::{
    CreateToolhelp32Snapshot, PROCESSENTRY32W, Process32FirstW, Process32NextW, TH32CS_SNAPPROCESS,
};
use windows::Win32::System::Registry::{
    HKEY, HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE, KEY_READ, REG_DWORD, REG_SZ, RRF_RT_REG_DWORD, RRF_RT_REG_SZ,
    RegCloseKey, RegDeleteKeyValueW, RegDeleteKeyW, RegDeleteTreeW, RegGetValueW, RegOpenKeyExW, RegQueryInfoKeyW,
    RegSetKeyValueW,
};
use windows::Win32::System::Threading::{
    OpenProcess, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION, QueryFullProcessImageNameW,
};
use windows::Win32::System::Variant::VT_LPWSTR;
use windows::Win32::UI::Shell::PropertiesSystem::IPropertyStore;
use windows::Win32::UI::Shell::{
    FOLDERID_Desktop, FOLDERID_Programs, IShellLinkW, KF_FLAG_DEFAULT, SHCNE_ASSOCCHANGED, SHCNF_IDLIST,
    SHChangeNotify, SHGetKnownFolderPath, SHStrDupW, ShellLink,
};
use windows::Win32::UI::WindowsAndMessaging::{EnumWindows, GetWindowThreadProcessId, PostMessageW, WM_CLOSE};
use windows::core::{BOOL, GUID, Interface, PCWSTR, PWSTR};

fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain(std::iter::once(0)).collect()
}

fn wide_path(path: &Path) -> Vec<u16> {
    path.as_os_str().encode_wide().chain(std::iter::once(0)).collect()
}

fn name_ptr(name: &Option<Vec<u16>>) -> PCWSTR {
    name.as_ref().map_or(PCWSTR::null(), |n| PCWSTR(n.as_ptr()))
}

/// A Win32 status as an I/O error carrying the OS number (5 = access denied), so the setup error codes see it.
fn win32(status: WIN32_ERROR) -> io::Result<()> {
    if status == ERROR_SUCCESS { Ok(()) } else { Err(io::Error::from_raw_os_error(status.0 as i32)) }
}

fn com(error: windows::core::Error) -> io::Error {
    let code = error.code().0 as u32;
    if code >> 16 == 0x8007 {
        io::Error::from_raw_os_error((code & 0xFFFF) as i32)
    } else {
        io::Error::other(error.message())
    }
}

/// Sets a string value under `HKCU\key`; `name: None` is the default value.
pub fn reg_set_string(key: &str, name: Option<&str>, value: &str) -> io::Result<()> {
    let (key, name, data) = (wide(key), name.map(wide), wide(value));
    // SAFETY: every buffer is NUL terminated and lives through the call; the size is the data's byte length.
    let status = unsafe {
        RegSetKeyValueW(
            HKEY_CURRENT_USER,
            PCWSTR(key.as_ptr()),
            name_ptr(&name),
            REG_SZ.0,
            Some(data.as_ptr().cast()),
            (data.len() * 2) as u32,
        )
    };
    win32(status)
}

/// Sets a DWORD value under `HKCU\key`.
pub fn reg_set_dword(key: &str, name: &str, value: u32) -> io::Result<()> {
    let (key, name) = (wide(key), wide(name));
    // SAFETY: the strings live through the call; `value` is read as 4 bytes.
    let status = unsafe {
        RegSetKeyValueW(
            HKEY_CURRENT_USER,
            PCWSTR(key.as_ptr()),
            PCWSTR(name.as_ptr()),
            REG_DWORD.0,
            Some((&raw const value).cast()),
            4,
        )
    };
    win32(status)
}

/// The raw bytes of a value, `None` when it is not there or has another type.
fn get_raw(
    root: HKEY,
    key: &str,
    name: Option<&str>,
    flags: windows::Win32::System::Registry::REG_ROUTINE_FLAGS,
) -> Option<Vec<u8>> {
    let (key, name) = (wide(key), name.map(wide));
    let mut size = 0u32;
    // SAFETY: the first call only asks for the size; all pointers are valid for the call.
    let first =
        unsafe { RegGetValueW(root, PCWSTR(key.as_ptr()), name_ptr(&name), flags, None, None, Some(&mut size)) };
    if first != ERROR_SUCCESS {
        return None;
    }
    let mut data = vec![0u8; size as usize];
    // SAFETY: `data` holds `size` bytes, which is what is passed as the capacity.
    let second = unsafe {
        RegGetValueW(
            root,
            PCWSTR(key.as_ptr()),
            name_ptr(&name),
            flags,
            None,
            Some(data.as_mut_ptr().cast()),
            Some(&mut size),
        )
    };
    if second != ERROR_SUCCESS {
        return None;
    }
    data.truncate(size as usize);
    Some(data)
}

fn get_string(root: HKEY, key: &str, name: Option<&str>) -> Option<String> {
    let bytes = get_raw(root, key, name, RRF_RT_REG_SZ)?;
    let units: Vec<u16> =
        bytes.as_chunks::<2>().0.iter().map(|c| u16::from_le_bytes(*c)).take_while(|u| *u != 0).collect();
    Some(String::from_utf16_lossy(&units))
}

/// A string value under `HKCU\key`.
pub fn reg_get_string(key: &str, name: Option<&str>) -> Option<String> {
    get_string(HKEY_CURRENT_USER, key, name)
}

/// Deletes `HKCU\key` with everything below it; a missing key is fine.
pub fn reg_delete_key(key: &str) -> io::Result<()> {
    let key = wide(key);
    // SAFETY: the key text is NUL terminated and lives through the call.
    let status = unsafe { RegDeleteTreeW(HKEY_CURRENT_USER, PCWSTR(key.as_ptr())) };
    if status == ERROR_FILE_NOT_FOUND { Ok(()) } else { win32(status) }
}

/// Deletes one value under `HKCU\key`; a missing value or key is fine.
pub fn reg_delete_value(key: &str, name: Option<&str>) -> io::Result<()> {
    let (key, name) = (wide(key), name.map(wide));
    // SAFETY: the strings live through the call.
    let status = unsafe { RegDeleteKeyValueW(HKEY_CURRENT_USER, PCWSTR(key.as_ptr()), name_ptr(&name)) };
    if status == ERROR_FILE_NOT_FOUND { Ok(()) } else { win32(status) }
}

/// Deletes `HKCU\key` only when it has no values and no sub keys; a missing key is fine.
pub fn reg_delete_key_if_empty(key: &str) -> io::Result<()> {
    let key = wide(key);
    let mut handle = HKEY::default();
    // SAFETY: the key text is NUL terminated and lives through the call; `handle` is closed again below.
    let opened = unsafe { RegOpenKeyExW(HKEY_CURRENT_USER, PCWSTR(key.as_ptr()), None, KEY_READ, &mut handle) };
    if opened == ERROR_FILE_NOT_FOUND {
        return Ok(());
    }
    win32(opened)?;
    let (mut sub_keys, mut values) = (0u32, 0u32);
    // SAFETY: `handle` is the key opened above; the counters outlive the call and the other outputs are not wanted.
    let info = unsafe {
        RegQueryInfoKeyW(
            handle,
            None,
            None,
            None,
            Some(&raw mut sub_keys),
            None,
            None,
            Some(&raw mut values),
            None,
            None,
            None,
            None,
        )
    };
    // SAFETY: closes the handle opened above, once.
    let _ = unsafe { RegCloseKey(handle) };
    win32(info)?;
    if sub_keys > 0 || values > 0 {
        return Ok(());
    }
    // SAFETY: the key text is NUL terminated and lives through the call.
    let status = unsafe { RegDeleteKeyW(HKEY_CURRENT_USER, PCWSTR(key.as_ptr())) };
    if status == ERROR_FILE_NOT_FOUND { Ok(()) } else { win32(status) }
}

/// A `VT_LPWSTR` property (the shell wants this type for the AppUserModelID, not a BSTR).
fn lpwstr_variant(text: &str) -> io::Result<PROPVARIANT> {
    let wide = wide(text);
    // SAFETY: `wide` is NUL terminated; `SHStrDupW` copies it into CoTaskMem memory that `PROPVARIANT`'s drop
    // (`PropVariantClear`) frees.
    let copy: PWSTR = unsafe { SHStrDupW(PCWSTR(wide.as_ptr())) }.map_err(com)?;
    Ok(PROPVARIANT {
        Anonymous: PROPVARIANT_0 {
            Anonymous: std::mem::ManuallyDrop::new(PROPVARIANT_0_0 {
                vt: VT_LPWSTR,
                wReserved1: 0,
                wReserved2: 0,
                wReserved3: 0,
                Anonymous: PROPVARIANT_0_0_0 { pwszVal: copy },
            }),
        },
    })
}

fn save_link(link: &Path, target: &Path, working_dir: &Path, icon: &Path, aumid: &str) -> io::Result<()> {
    let (target, dir, icon_w, link_w) = (wide_path(target), wide_path(working_dir), wide_path(icon), wide_path(link));
    // SAFETY: COM is initialized by the caller on this thread; every string is NUL terminated and outlives its call; the
    // interfaces are released when they drop.
    unsafe {
        let shell: IShellLinkW = CoCreateInstance(&ShellLink, None, CLSCTX_INPROC_SERVER).map_err(com)?;
        shell.SetPath(PCWSTR(target.as_ptr())).map_err(com)?;
        shell.SetWorkingDirectory(PCWSTR(dir.as_ptr())).map_err(com)?;
        shell.SetIconLocation(PCWSTR(icon_w.as_ptr()), 0).map_err(com)?;
        let props: IPropertyStore = shell.cast().map_err(com)?;
        let id = lpwstr_variant(aumid)?;
        props.SetValue(&PKEY_AppUserModel_ID, &id).map_err(com)?;
        props.Commit().map_err(com)?;
        let file: IPersistFile = shell.cast().map_err(com)?;
        file.Save(PCWSTR(link_w.as_ptr()), true).map_err(com)
    }
}

/// Creates a `.lnk` (and its folder) with working directory, icon and AppUserModelID.
pub fn create_shortcut(link: &Path, target: &Path, working_dir: &Path, icon: &Path, aumid: &str) -> io::Result<()> {
    if let Some(parent) = link.parent() {
        std::fs::create_dir_all(parent)?;
    }
    // SAFETY: plain COM init on this thread; balanced below when it succeeded (also for S_FALSE). A thread that is
    // already in another apartment returns an error, and then COM stays usable as it is.
    let init = unsafe { CoInitializeEx(None, COINIT_APARTMENTTHREADED) };
    let result = save_link(link, target, working_dir, icon, aumid);
    if init.is_ok() {
        // SAFETY: pairs with the successful `CoInitializeEx` above.
        unsafe { CoUninitialize() };
    }
    result
}

/// Tells Explorer that file associations changed.
pub fn notify_assoc_changed() {
    // SAFETY: no item pointers are passed for `SHCNF_IDLIST` with `SHCNE_ASSOCCHANGED`, as documented.
    unsafe { SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST, None, None) };
}

fn same_path(a: &str, b: &Path) -> bool {
    let norm = |s: &str| s.replace('/', "\\").to_lowercase();
    norm(a) == norm(&b.to_string_lossy())
}

/// Process ids of running programs whose image file is `exe`.
pub fn running_instances(exe: &Path) -> Vec<u32> {
    let mut found = Vec::new();
    // SAFETY: the snapshot handle is closed at the end; `entry.dwSize` is set as the API requires.
    unsafe {
        let Ok(snapshot) = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) else { return found };
        let mut entry = PROCESSENTRY32W { dwSize: std::mem::size_of::<PROCESSENTRY32W>() as u32, ..Default::default() };
        let mut more = Process32FirstW(snapshot, &mut entry).is_ok();
        while more {
            if let Ok(process) = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, entry.th32ProcessID) {
                let mut buffer = vec![0u16; 1024];
                let mut len = buffer.len() as u32;
                if QueryFullProcessImageNameW(process, PROCESS_NAME_WIN32, PWSTR(buffer.as_mut_ptr()), &mut len).is_ok()
                {
                    let path = OsString::from_wide(&buffer[..len as usize]);
                    if same_path(&path.to_string_lossy(), exe) {
                        found.push(entry.th32ProcessID);
                    }
                }
                let _ = CloseHandle(process);
            }
            more = Process32NextW(snapshot, &mut entry).is_ok();
        }
        let _ = CloseHandle(snapshot);
    }
    found
}

unsafe extern "system" fn close_if_listed(hwnd: HWND, lparam: LPARAM) -> BOOL {
    // SAFETY: `lparam` is the address of the `Vec<u32>` that `request_close` keeps alive for the whole `EnumWindows` call.
    let pids = unsafe { &*(lparam.0 as *const Vec<u32>) };
    let mut pid = 0u32;
    // SAFETY: `hwnd` comes from the enumeration; `pid` is a valid out pointer.
    unsafe { GetWindowThreadProcessId(hwnd, Some(&mut pid)) };
    if pids.contains(&pid) {
        // SAFETY: posting a message to a window handle is always sound; a dead window just fails.
        let _ = unsafe { PostMessageW(Some(hwnd), WM_CLOSE, WPARAM(0), LPARAM(0)) };
    }
    true.into()
}

/// Posts `WM_CLOSE` to every top-level window of the running programs whose image is `exe`.
pub fn request_close(exe: &Path) {
    let pids = running_instances(exe);
    if pids.is_empty() {
        return;
    }
    // SAFETY: `pids` outlives the call; the callback only reads it through the pointer.
    let _ = unsafe { EnumWindows(Some(close_if_listed), LPARAM((&raw const pids) as isize)) };
}

/// Schedules a file or an empty folder for removal at the next restart.
pub fn delete_at_reboot(path: &Path) -> io::Result<()> {
    let path = wide_path(path);
    // SAFETY: the path is NUL terminated and lives through the call; a null new name means delete.
    unsafe { MoveFileExW(PCWSTR(path.as_ptr()), PCWSTR::null(), MOVEFILE_DELAY_UNTIL_REBOOT) }.map_err(com)
}

/// `Windows 11 26100` from the build number (build 22000 and up is Windows 11, whatever the product name says).
pub fn windows_version() -> String {
    let key = r"SOFTWARE\Microsoft\Windows NT\CurrentVersion";
    let build = get_string(HKEY_LOCAL_MACHINE, key, Some("CurrentBuildNumber")).unwrap_or_default();
    let name = if build.parse::<u32>().is_ok_and(|b| b >= 22000) { "Windows 11" } else { "Windows 10" };
    format!("{name} {build}").trim_end().to_string()
}

/// Whether apps use the light theme; light when the setting is missing (the Windows default before dark mode existed).
pub fn uses_light_theme() -> bool {
    let key = r"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize";
    get_raw(HKEY_CURRENT_USER, key, Some("AppsUseLightTheme"), RRF_RT_REG_DWORD)
        .and_then(|b| <[u8; 4]>::try_from(b.as_slice()).ok())
        .is_none_or(|b| u32::from_le_bytes(b) != 0)
}

fn known_folder(id: &GUID) -> Option<PathBuf> {
    // SAFETY: the returned string is CoTaskMem memory: copied out, then freed once.
    unsafe {
        let ptr = SHGetKnownFolderPath(id, KF_FLAG_DEFAULT, None).ok()?;
        let path = PathBuf::from(OsString::from_wide(ptr.as_wide()));
        CoTaskMemFree(Some(ptr.0 as *const c_void));
        Some(path)
    }
}

/// The user's Desktop (it may be redirected to OneDrive).
pub fn desktop_folder() -> Option<PathBuf> {
    known_folder(&FOLDERID_Desktop)
}

/// `%APPDATA%\Microsoft\Windows\Start Menu\Programs`.
pub fn start_menu_programs_folder() -> Option<PathBuf> {
    known_folder(&FOLDERID_Programs)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn registry_values_round_trip_and_the_key_deletes_with_its_children() {
        let key = format!(r"Software\SequenceStudioSetupTest{}", std::process::id());
        let child = format!(r"{key}\child");
        assert!(reg_set_string(&child, None, "default").is_ok());
        assert!(reg_set_string(&key, Some("Name"), "value ü").is_ok());
        assert!(reg_set_dword(&key, "Number", 7).is_ok());
        assert_eq!(reg_get_string(&child, None).as_deref(), Some("default"));
        assert_eq!(reg_get_string(&key, Some("Name")).as_deref(), Some("value ü"));
        assert!(reg_delete_value(&key, Some("Name")).is_ok());
        assert_eq!(reg_get_string(&key, Some("Name")), None);
        assert!(reg_delete_key(&key).is_ok());
        assert_eq!(reg_get_string(&child, None), None);
        assert!(reg_delete_key(&key).is_ok(), "a missing key is fine");
        assert!(reg_delete_value(&key, Some("Name")).is_ok());
    }

    #[test]
    fn a_shortcut_is_written_and_the_facts_are_there() {
        let dir = std::env::temp_dir().join(format!("sq-setup-lnk-{}", std::process::id()));
        let link = dir.join("Test.lnk");
        assert!(
            create_shortcut(
                &link,
                Path::new(r"C:\Windows\notepad.exe"),
                Path::new(r"C:\Windows"),
                Path::new(r"C:\Windows\notepad.exe"),
                "SequenceStudio.Test"
            )
            .is_ok()
        );
        assert!(link.exists());
        let _ = std::fs::remove_dir_all(&dir);
        assert!(windows_version().starts_with("Windows "));
        assert!(desktop_folder().is_some() && start_menu_programs_folder().is_some());
        assert!(running_instances(Path::new(r"C:\no\such\program.exe")).is_empty());
    }
}
