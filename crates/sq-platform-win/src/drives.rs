// Swift: App/Sources/SharedUI/MacShell/MacCardVolumes.swift (the Windows counterpart: `DriveFacts`)
//! The drives Windows reports, as `DriveFacts` for the card import (`GetDriveTypeW`, the storage bus from
//! `IOCTL_STORAGE_QUERY_PROPERTY`: USB and Thunderbolt SSDs report DRIVE_FIXED, so the bus decides).

use sq_library::card_import::{DriveBus, DriveFacts, DriveKind};
use std::ffi::OsStr;
use std::os::windows::ffi::OsStrExt;
use windows_sys::Win32::Foundation::{CloseHandle, INVALID_HANDLE_VALUE};
use windows_sys::Win32::Storage::FileSystem::{
    CreateFileW, FILE_SHARE_READ, FILE_SHARE_WRITE, GetDriveTypeW, GetLogicalDrives, OPEN_EXISTING,
};
use windows_sys::Win32::System::IO::DeviceIoControl;
use windows_sys::Win32::System::Ioctl::{
    IOCTL_STORAGE_QUERY_PROPERTY, PropertyStandardQuery, STORAGE_DEVICE_DESCRIPTOR, STORAGE_PROPERTY_QUERY,
    StorageDeviceProperty,
};

const DRIVE_REMOVABLE: u32 = 2;
const DRIVE_FIXED: u32 = 3;

fn wide(s: &str) -> Vec<u16> {
    OsStr::new(s).encode_wide().chain(std::iter::once(0)).collect()
}

/// The bus code of `STORAGE_BUS_TYPE`: 7 USB, 4 FireWire (1394), 12 SD, 13 MMC.
pub fn bus_of_code(code: u32) -> DriveBus {
    match code {
        7 => DriveBus::Usb,
        4 => DriveBus::Firewire,
        12 => DriveBus::Sd,
        13 => DriveBus::Mmc,
        _ => DriveBus::Other,
    }
}

fn bus(letter: char) -> DriveBus {
    let path = wide(&format!("\\\\.\\{letter}:"));
    // SAFETY: `path` is NUL-terminated and lives through the call; the handle is closed below.
    let handle = unsafe {
        CreateFileW(
            path.as_ptr(),
            0,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            std::ptr::null(),
            OPEN_EXISTING,
            0,
            std::ptr::null_mut(),
        )
    };
    if handle == INVALID_HANDLE_VALUE {
        return DriveBus::Other;
    }
    let query = STORAGE_PROPERTY_QUERY {
        PropertyId: StorageDeviceProperty,
        QueryType: PropertyStandardQuery,
        AdditionalParameters: [0],
    };
    let mut out = [0_u8; 1024];
    let mut returned = 0_u32;
    // SAFETY: both buffers are valid for the sizes passed; the descriptor is read from the aligned-enough prefix of
    // `out` with an unaligned read, only when the call succeeded and returned at least the header size.
    let ok = unsafe {
        DeviceIoControl(
            handle,
            IOCTL_STORAGE_QUERY_PROPERTY,
            std::ptr::from_ref(&query).cast(),
            std::mem::size_of::<STORAGE_PROPERTY_QUERY>() as u32,
            out.as_mut_ptr().cast(),
            out.len() as u32,
            &mut returned,
            std::ptr::null_mut(),
        )
    };
    // SAFETY: the handle came from CreateFileW above.
    unsafe { CloseHandle(handle) };
    if ok == 0 || (returned as usize) < std::mem::size_of::<STORAGE_DEVICE_DESCRIPTOR>() {
        return DriveBus::Other;
    }
    // SAFETY: `out` holds at least a full descriptor (checked above).
    let d: STORAGE_DEVICE_DESCRIPTOR = unsafe { std::ptr::read_unaligned(out.as_ptr().cast()) };
    bus_of_code(d.BusType as u32)
}

/// Every drive letter in use, with what the card import needs to know about it.
pub fn drives() -> Vec<DriveFacts> {
    let system = std::env::var("SystemDrive").unwrap_or_else(|_| "C:".to_string()).to_uppercase();
    // SAFETY: no arguments.
    let mask = unsafe { GetLogicalDrives() };
    ('A'..='Z')
        .enumerate()
        .filter(|(i, _)| mask & (1 << i) != 0)
        .map(|(_, letter)| {
            let root = format!("{letter}:\\");
            // SAFETY: NUL-terminated root path that lives through the call.
            let kind = match unsafe { GetDriveTypeW(wide(&root).as_ptr()) } {
                DRIVE_REMOVABLE => DriveKind::Removable,
                DRIVE_FIXED => DriveKind::Fixed,
                _ => DriveKind::Other,
            };
            let bus = if kind == DriveKind::Other { DriveBus::Other } else { bus(letter) };
            DriveFacts { is_system: format!("{letter}:") == system, root, kind, bus }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bus_codes_follow_storage_bus_type() {
        assert_eq!(bus_of_code(7), DriveBus::Usb);
        assert_eq!(bus_of_code(12), DriveBus::Sd);
        assert_eq!(bus_of_code(11), DriveBus::Other);
    }

    #[test]
    fn the_system_drive_is_listed_and_never_an_import_source() {
        let all = drives();
        let sys = all.iter().find(|d| d.is_system).expect("system drive");
        assert!(!sys.is_import_source());
    }
}
