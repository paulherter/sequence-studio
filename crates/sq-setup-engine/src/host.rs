//! The OS calls the engine needs, behind one trait so the engine runs against [`FakeHost`] in tests. The real one is
//! `WindowsHost` (Windows only), built on `sq_platform_win::setup`.

use crate::plan::ShortcutSpec;
use std::collections::{BTreeMap, BTreeSet};
use std::io;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::Duration;

/// The folders Windows names for the user.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct KnownFolders {
    pub local_app_data: PathBuf,
    pub app_data: PathBuf,
    pub desktop: PathBuf,
    pub start_menu_programs: PathBuf,
    pub temp: PathBuf,
}

/// What the engine asks of the machine. Registry keys are relative to `HKEY_CURRENT_USER`; `name: None` is the default
/// value. Every method takes `&self` so one host serves the worker thread and the UI.
pub trait Host: Send + Sync {
    fn reg_set_string(&self, key: &str, name: Option<&str>, value: &str) -> io::Result<()>;
    fn reg_set_dword(&self, key: &str, name: &str, value: u32) -> io::Result<()>;
    fn reg_get_string(&self, key: &str, name: Option<&str>) -> Option<String>;
    /// Deletes the key with everything below it; a key that is not there is `Ok`.
    fn reg_delete_key(&self, key: &str) -> io::Result<()>;
    /// Deletes one value; a value that is not there is `Ok`.
    fn reg_delete_value(&self, key: &str, name: Option<&str>) -> io::Result<()>;
    /// Deletes the key only when it has no values and no sub keys; a key that is not there is `Ok`.
    fn reg_delete_key_if_empty(&self, key: &str) -> io::Result<()>;
    /// Creates the `.lnk` (and its folder) with working directory, icon and AppUserModelID.
    fn create_shortcut(&self, spec: &ShortcutSpec) -> io::Result<()>;
    /// `SHChangeNotify(SHCNE_ASSOCCHANGED)`.
    fn notify_assoc_changed(&self);
    /// Process ids of running programs whose image is `exe`.
    fn running_instances(&self, exe: &Path) -> Vec<u32>;
    /// Posts `WM_CLOSE` to the windows of those programs (the app may ask to save).
    fn request_close(&self, exe: &Path);
    /// Schedules the removal of a locked file or folder for the next restart.
    fn delete_at_reboot(&self, path: &Path) -> io::Result<()>;
    /// Deletes `path` once the running program (this process, when `path` is its own file) has ended.
    fn delete_after_exit(&self, path: &Path) -> io::Result<()>;
    /// Bytes this user can still write on the volume of `path` (its nearest existing parent); `None` = unknown.
    fn free_bytes(&self, path: &Path) -> Option<u64>;
    /// `C:` for a path on drive C.
    fn drive_label(&self, path: &Path) -> String;
    /// `Windows 11 26100`.
    fn windows_version(&self) -> String;
    /// Whether apps use the light theme (`AppsUseLightTheme`).
    fn uses_light_theme(&self) -> bool;
    fn folders(&self) -> KnownFolders;
    /// How long the engine waits for a running app to close (spec: 10 s).
    fn close_timeout(&self) -> Duration {
        Duration::from_secs(10)
    }
}

/// A registry value in the fake.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum FakeValue {
    Str(String),
    Dword(u32),
}

/// What [`FakeHost`] has been told to do or to fail.
#[derive(Debug, Default)]
pub struct FakeState {
    /// `(lower-case key, lower-case value name or "")` to value.
    pub registry: BTreeMap<(String, String), FakeValue>,
    pub shortcuts: Vec<ShortcutSpec>,
    pub assoc_changes: u32,
    pub reboot_deletes: Vec<PathBuf>,
    /// Files asked to go once the program has ended (the uninstaller's own copy).
    pub exit_deletes: Vec<PathBuf>,
    /// Lower-case keys that exist without any value or sub key (what is left when the last value is deleted).
    pub empty_keys: BTreeSet<String>,
    pub close_requests: u32,
    /// Programs reported as running; a close request removes them when `closes_on_request`.
    pub running: Vec<PathBuf>,
    pub closes_on_request: bool,
    pub free: Option<u64>,
    pub fail_shortcut: bool,
    /// Registry writes of this value name (`"UninstallString"`) fail with access denied.
    pub fail_reg_name: Option<String>,
}

/// A host that keeps everything in memory, except `.lnk` files, which it writes as small text files so the engine's file
/// removal can be checked on disk.
#[derive(Debug)]
pub struct FakeHost {
    pub state: Mutex<FakeState>,
    pub folders: KnownFolders,
}

fn norm(key: &str, name: Option<&str>) -> (String, String) {
    (key.trim_matches('\\').to_lowercase(), name.unwrap_or("").to_lowercase())
}

impl FakeHost {
    /// All known folders below `root`; 100 GB free; nothing running.
    pub fn new(root: &Path) -> FakeHost {
        let folders = KnownFolders {
            local_app_data: root.join("Local"),
            app_data: root.join("Roaming"),
            desktop: root.join("Desktop"),
            start_menu_programs: root.join("Roaming").join("Start Menu").join("Programs"),
            temp: root.join("Temp"),
        };
        let state = FakeState { free: Some(100 << 30), closes_on_request: true, ..FakeState::default() };
        FakeHost { state: Mutex::new(state), folders }
    }

    /// Runs `f` on the state.
    pub fn with<R>(&self, f: impl FnOnce(&mut FakeState) -> R) -> R {
        let mut guard = self.state.lock().unwrap_or_else(|e| e.into_inner());
        f(&mut guard)
    }

    pub fn get_string(&self, key: &str, name: Option<&str>) -> Option<String> {
        self.with(|s| match s.registry.get(&norm(key, name)) {
            Some(FakeValue::Str(v)) => Some(v.clone()),
            _ => None,
        })
    }

    pub fn get_dword(&self, key: &str, name: &str) -> Option<u32> {
        self.with(|s| match s.registry.get(&norm(key, Some(name))) {
            Some(FakeValue::Dword(v)) => Some(*v),
            _ => None,
        })
    }

    /// Every key that has a value or still exists empty, for "touches nothing else" checks.
    pub fn keys(&self) -> Vec<String> {
        self.with(|s| {
            let mut keys: Vec<String> = s.registry.keys().map(|(k, _)| k.clone()).collect();
            keys.extend(s.empty_keys.iter().cloned());
            keys.sort();
            keys.dedup();
            keys
        })
    }
}

/// Whether a value lives at `key` or below it.
fn has_entries(state: &FakeState, key: &str) -> bool {
    let below = format!("{key}\\");
    state.registry.keys().any(|(k, _)| k == key || k.starts_with(&below))
}

/// A write at `key` makes it and its parents non-empty.
fn touched(state: &mut FakeState, key: &str) {
    state.empty_keys.retain(|k| key != k && !key.starts_with(&format!("{k}\\")));
}

fn denied() -> io::Error {
    io::Error::from_raw_os_error(5)
}

impl Host for FakeHost {
    fn reg_set_string(&self, key: &str, name: Option<&str>, value: &str) -> io::Result<()> {
        self.with(|s| {
            if name.is_some() && s.fail_reg_name.as_deref() == name {
                return Err(denied());
            }
            touched(s, &norm(key, name).0);
            s.registry.insert(norm(key, name), FakeValue::Str(value.to_string()));
            Ok(())
        })
    }

    fn reg_set_dword(&self, key: &str, name: &str, value: u32) -> io::Result<()> {
        self.with(|s| {
            if s.fail_reg_name.as_deref() == Some(name) {
                return Err(denied());
            }
            touched(s, &norm(key, Some(name)).0);
            s.registry.insert(norm(key, Some(name)), FakeValue::Dword(value));
            Ok(())
        })
    }

    fn reg_get_string(&self, key: &str, name: Option<&str>) -> Option<String> {
        self.get_string(key, name)
    }

    fn reg_delete_key(&self, key: &str) -> io::Result<()> {
        let key = key.trim_matches('\\').to_lowercase();
        let below = format!("{key}\\");
        self.with(|s| {
            s.registry.retain(|(k, _), _| *k != key && !k.starts_with(&below));
            s.empty_keys.retain(|k| *k != key && !k.starts_with(&below));
        });
        Ok(())
    }

    fn reg_delete_value(&self, key: &str, name: Option<&str>) -> io::Result<()> {
        self.with(|s| {
            let (key, name) = norm(key, name);
            if s.registry.remove(&(key.clone(), name)).is_some() && !has_entries(s, &key) {
                s.empty_keys.insert(key);
            }
        });
        Ok(())
    }

    fn reg_delete_key_if_empty(&self, key: &str) -> io::Result<()> {
        let key = key.trim_matches('\\').to_lowercase();
        self.with(|s| {
            if !has_entries(s, &key) {
                s.empty_keys.remove(&key);
            }
        });
        Ok(())
    }

    fn create_shortcut(&self, spec: &ShortcutSpec) -> io::Result<()> {
        if self.with(|s| s.fail_shortcut) {
            return Err(denied());
        }
        if let Some(parent) = spec.link.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::write(&spec.link, spec.target.to_string_lossy().as_bytes())?;
        self.with(|s| s.shortcuts.push(spec.clone()));
        Ok(())
    }

    fn notify_assoc_changed(&self) {
        self.with(|s| s.assoc_changes += 1);
    }

    fn running_instances(&self, exe: &Path) -> Vec<u32> {
        self.with(|s| s.running.iter().filter(|p| p.as_path() == exe).map(|_| 4242).collect())
    }

    fn request_close(&self, exe: &Path) {
        self.with(|s| {
            s.close_requests += 1;
            if s.closes_on_request {
                s.running.retain(|p| p.as_path() != exe);
            }
        });
    }

    fn delete_at_reboot(&self, path: &Path) -> io::Result<()> {
        self.with(|s| s.reboot_deletes.push(path.to_path_buf()));
        Ok(())
    }

    fn delete_after_exit(&self, path: &Path) -> io::Result<()> {
        self.with(|s| s.exit_deletes.push(path.to_path_buf()));
        Ok(())
    }

    fn free_bytes(&self, _path: &Path) -> Option<u64> {
        self.with(|s| s.free)
    }

    fn drive_label(&self, _path: &Path) -> String {
        "C:".to_string()
    }

    fn windows_version(&self) -> String {
        "Windows 11 26100".to_string()
    }

    fn uses_light_theme(&self) -> bool {
        false
    }

    fn folders(&self) -> KnownFolders {
        self.folders.clone()
    }

    fn close_timeout(&self) -> Duration {
        Duration::from_millis(60)
    }
}
