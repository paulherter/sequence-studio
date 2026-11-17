// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: SQPlayback/AudioOutputDevices.swift, AudioEngine.setOutputDevice(uid:)
//! The output devices that exist right now and the one the user picked in Preferences > Audio. The device uid is cpal's
//! `DeviceId` text (stable per device and host); `None` = the system default output.

use cpal::traits::{DeviceTrait, HostTrait};
use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering::Relaxed};

/// One audio output device as the Preferences popup sees it.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct OutputDeviceInfo {
    pub uid: String,
    pub name: String,
}

/// The device a stored uid selects: `None` (= system default output) for no uid, an empty one, or a uid that is not
/// connected (unplugged headphones, a setup moved to another machine).
pub fn resolve<'a>(uid: Option<&str>, devices: &'a [OutputDeviceInfo]) -> Option<&'a OutputDeviceInfo> {
    let uid = uid.filter(|u| !u.is_empty())?;
    devices.iter().find(|d| d.uid == uid)
}

/// Output devices that exist right now.
pub fn available() -> Vec<OutputDeviceInfo> {
    let host = cpal::default_host();
    let Ok(devices) = host.output_devices() else { return Vec::new() };
    devices
        .filter_map(|d| {
            let uid = d.id().ok()?.to_string();
            let name = d.description().map(|x| x.name().to_string()).unwrap_or_else(|_| uid.clone());
            Some(OutputDeviceInfo { uid, name })
        })
        .collect()
}

static PREFERRED: Mutex<Option<String>> = Mutex::new(None);

/// Sets the preferred output (Preferences > Audio); the next stream build uses it. `None` = system default.
pub fn set_preferred(uid: Option<String>) {
    let uid = uid.filter(|u| !u.is_empty());
    let mut slot = PREFERRED.lock().unwrap_or_else(|e| e.into_inner());
    if *slot != uid {
        *slot = uid;
        CHANGES.fetch_add(1, Relaxed);
    }
}

static CHANGES: AtomicU64 = AtomicU64::new(0);

/// How often the preferred output changed; a running output rebuilds its stream when it moves.
pub fn changes() -> u64 {
    CHANGES.load(Relaxed)
}

/// The preferred output uid last set.
pub fn preferred() -> Option<String> {
    PREFERRED.lock().unwrap_or_else(|e| e.into_inner()).clone()
}

/// The device to open: the preferred one when it is connected, else the system default.
pub(super) fn pick(host: &cpal::Host) -> Option<cpal::Device> {
    if let Some(uid) = preferred()
        && let Ok(id) = uid.parse::<cpal::DeviceId>()
        && let Some(d) = host.device_by_id(&id)
    {
        return Some(d);
    }
    host.default_output_device()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn list() -> Vec<OutputDeviceInfo> {
        vec![
            OutputDeviceInfo { uid: "a".into(), name: "Speakers".into() },
            OutputDeviceInfo { uid: "b".into(), name: "USB".into() },
        ]
    }

    // Swift AudioOutputDevices.resolve
    #[test]
    fn a_stored_uid_resolves_only_while_the_device_is_connected() {
        let l = list();
        assert_eq!(resolve(Some("b"), &l).map(|d| d.name.as_str()), Some("USB"));
        assert_eq!(resolve(Some("gone"), &l), None);
        assert_eq!(resolve(Some(""), &l), None);
        assert_eq!(resolve(None, &l), None);
    }

    #[test]
    fn the_preferred_uid_is_kept_and_empty_means_default() {
        set_preferred(Some("x".into()));
        assert_eq!(preferred().as_deref(), Some("x"));
        let before = changes();
        set_preferred(Some("x".into()));
        assert_eq!(changes(), before, "the same choice is no change");
        set_preferred(Some(String::new()));
        assert_eq!(preferred(), None);
        assert_eq!(changes(), before + 1);
    }
}
