//! What the screens ask before a job starts: is the app installed, where should it go, is that place usable, how much
//! data would an uninstall remove. Pure apart from the registry reads (through the host) and the disk probes.

use crate::host::Host;
use crate::plan::{APP_NAME, INNO_UNINSTALL_KEY, UNINSTALL_KEY};
use crate::version::Version;
use std::path::{Path, PathBuf};

/// Which installer wrote the install that was found.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InstallSource {
    /// This installer (the `SequenceStudio` Uninstall key).
    Ours,
    /// The old Inno Setup installer.
    Inno,
}

/// An existing install.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Installed {
    pub version: Version,
    pub location: PathBuf,
    pub source: InstallSource,
}

/// How the version of this setup relates to the installed one.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum UpdateKind {
    /// This setup is newer than the installed version: a normal update.
    Newer,
    Same,
    /// This setup is older than the installed version: a downgrade.
    Older,
}

/// The result of checking a folder for the Welcome screen.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LocationCheck {
    /// Usable; `free` is `u64::MAX` when the system could not say.
    Ok {
        free: u64,
    },
    NoSpace {
        need: u64,
        free: u64,
    },
    NotWritable,
}

/// The install found in the registry: our key first, else the Inno one. An entry whose version cannot be read or whose
/// location is empty does not count.
pub fn detect_installed(host: &dyn Host) -> Option<Installed> {
    [(UNINSTALL_KEY, InstallSource::Ours), (INNO_UNINSTALL_KEY, InstallSource::Inno)].into_iter().find_map(
        |(key, source)| {
            let version = Version::parse(&host.reg_get_string(key, Some("DisplayVersion"))?)?;
            let location = host.reg_get_string(key, Some("InstallLocation"))?;
            let location = location.trim().trim_end_matches(['\\', '/']);
            (!location.is_empty()).then(|| Installed { version, location: PathBuf::from(location), source })
        },
    )
}

/// `Newer` when `new` is newer than `installed`.
pub fn update_kind(new: &Version, installed: &Version) -> UpdateKind {
    match new.cmp(installed) {
        std::cmp::Ordering::Greater => UpdateKind::Newer,
        std::cmp::Ordering::Equal => UpdateKind::Same,
        std::cmp::Ordering::Less => UpdateKind::Older,
    }
}

/// The folder the app goes into for a picked folder: `Sequence Studio` is appended unless the pick already ends in it
/// (case-insensitive).
pub fn resolve_location(picked: &Path) -> PathBuf {
    let ends_in_name = picked.file_name().is_some_and(|n| n.to_string_lossy().eq_ignore_ascii_case(APP_NAME));
    if ends_in_name { picked.to_path_buf() } else { picked.join(APP_NAME) }
}

/// `<LOCALAPPDATA>\Programs\Sequence Studio`.
pub fn default_location(local_app_data: &Path) -> PathBuf {
    local_app_data.join("Programs").join(APP_NAME)
}

/// Checks the (resolved) install folder: a file is created and deleted in its nearest existing parent, then the free
/// space is compared with `need_bytes`. Program Files and read-only drives fail the probe.
pub fn check_location(host: &dyn Host, location: &Path, need_bytes: u64) -> LocationCheck {
    let Some(parent) = location.ancestors().find(|p| !p.as_os_str().is_empty() && p.is_dir()) else {
        return LocationCheck::NotWritable;
    };
    let probe = parent.join(format!(".sq-setup-probe-{}", std::process::id()));
    if std::fs::write(&probe, b"x").is_err() {
        return LocationCheck::NotWritable;
    }
    let _ = std::fs::remove_file(&probe);
    match host.free_bytes(parent) {
        Some(free) if free < need_bytes => LocationCheck::NoSpace { need: need_bytes, free },
        Some(free) => LocationCheck::Ok { free },
        None => LocationCheck::Ok { free: u64::MAX },
    }
}

fn dir_bytes(dir: &Path, total: &mut u64, files: &mut u64) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        match entry.file_type() {
            Ok(t) if t.is_dir() => dir_bytes(&entry.path(), total, files),
            Ok(_) => {
                *files += 1;
                *total += entry.metadata().map_or(0, |m| m.len());
            }
            Err(_) => {}
        }
    }
}

/// Sum of the file sizes under `dirs`; `None` when there is nothing there.
pub fn measure_data(dirs: &[PathBuf]) -> Option<u64> {
    let (mut total, mut files) = (0, 0);
    for dir in dirs {
        dir_bytes(dir, &mut total, &mut files);
    }
    (files > 0).then_some(total)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::host::FakeHost;

    fn temp(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("sq-detect-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let _ = std::fs::create_dir_all(&dir);
        dir
    }

    #[test]
    fn our_key_wins_over_the_inno_key_and_trailing_slashes_go() {
        let dir = temp("detect");
        let host = FakeHost::new(&dir);
        assert_eq!(detect_installed(&host), None);
        let _ = host.reg_set_string(INNO_UNINSTALL_KEY, Some("DisplayVersion"), "0.1");
        let _ = host.reg_set_string(INNO_UNINSTALL_KEY, Some("InstallLocation"), "C:\\Apps\\Sequence Studio\\");
        let found = detect_installed(&host).expect("inno");
        assert_eq!((found.source, found.version.clone()), (InstallSource::Inno, Version::new(0, 1, 0)));
        assert_eq!(found.location, PathBuf::from("C:\\Apps\\Sequence Studio"));
        let _ = host.reg_set_string(UNINSTALL_KEY, Some("DisplayVersion"), "0.2.0");
        assert_eq!(detect_installed(&host).map(|i| i.source), Some(InstallSource::Inno), "no location yet");
        let _ = host.reg_set_string(UNINSTALL_KEY, Some("InstallLocation"), "D:\\SQ");
        let found = detect_installed(&host).expect("ours");
        assert_eq!((found.source, found.version), (InstallSource::Ours, Version::new(0, 2, 0)));
    }

    #[test]
    fn the_update_kind_names_the_setup_against_the_installed() {
        let (a, b) = (Version::new(0, 2, 0), Version::new(0, 10, 0));
        assert_eq!(update_kind(&b, &a), UpdateKind::Newer);
        assert_eq!(update_kind(&a, &a), UpdateKind::Same);
        assert_eq!(update_kind(&a, &b), UpdateKind::Older);
    }

    #[test]
    fn locations_resolve_and_default() {
        assert_eq!(resolve_location(Path::new("/x/Apps")), PathBuf::from("/x/Apps/Sequence Studio"));
        assert_eq!(resolve_location(Path::new("/x/sequence studio")), PathBuf::from("/x/sequence studio"));
        assert_eq!(default_location(Path::new("/L")), PathBuf::from("/L/Programs/Sequence Studio"));
    }

    #[test]
    fn a_location_check_reports_space_and_writability() {
        let dir = temp("check");
        let host = FakeHost::new(&dir);
        let target = dir.join("not").join("there").join("Sequence Studio");
        assert_eq!(check_location(&host, &target, 1 << 20), LocationCheck::Ok { free: 100 << 30 });
        assert!(!dir.join("not").exists(), "the check creates no folder");
        host.with(|s| s.free = Some(5 << 20));
        assert_eq!(check_location(&host, &target, 1 << 30), LocationCheck::NoSpace { need: 1 << 30, free: 5 << 20 });
        host.with(|s| s.free = None);
        assert_eq!(check_location(&host, &target, 1 << 30), LocationCheck::Ok { free: u64::MAX });
        assert_eq!(check_location(&host, Path::new(""), 1), LocationCheck::NotWritable);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let ro = dir.join("ro");
            let _ = std::fs::create_dir_all(&ro);
            let _ = std::fs::set_permissions(&ro, std::fs::Permissions::from_mode(0o555));
            // Root ignores the mode; only assert where the mode is honored.
            if std::fs::write(ro.join("t"), b"x").is_err() {
                assert_eq!(check_location(&host, &ro.join("Sequence Studio"), 1), LocationCheck::NotWritable);
            }
            let _ = std::fs::set_permissions(&ro, std::fs::Permissions::from_mode(0o755));
        }
    }

    #[test]
    fn data_is_measured_or_reported_empty() {
        let dir = temp("data");
        assert_eq!(measure_data(&[dir.join("a"), dir.join("b")]), None);
        let _ = std::fs::create_dir_all(dir.join("a").join("sub"));
        assert_eq!(measure_data(&[dir.join("a")]), None, "folders without files are empty");
        let _ = std::fs::write(dir.join("a").join("sub").join("f"), [0u8; 10]);
        let _ = std::fs::write(dir.join("b"), [0u8; 5]);
        assert_eq!(measure_data(&[dir.join("a"), dir.join("b")]), Some(10), "a plain file as a dir is skipped");
    }
}
