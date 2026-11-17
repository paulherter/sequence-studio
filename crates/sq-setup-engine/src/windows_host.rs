//! The real [`Host`]: every call goes to `sq_platform_win::setup` (where the `unsafe` lives).

use crate::host::{Host, KnownFolders};
use crate::plan::ShortcutSpec;
use sq_platform_win::setup;
use std::io;
use std::path::{Component, Path, PathBuf};

/// The machine the setup runs on.
#[derive(Clone, Copy, Debug, Default)]
pub struct WindowsHost;

fn env_folder(name: &str) -> PathBuf {
    std::env::var_os(name).map(PathBuf::from).unwrap_or_default()
}

impl Host for WindowsHost {
    fn reg_set_string(&self, key: &str, name: Option<&str>, value: &str) -> io::Result<()> {
        setup::reg_set_string(key, name, value)
    }

    fn reg_set_dword(&self, key: &str, name: &str, value: u32) -> io::Result<()> {
        setup::reg_set_dword(key, name, value)
    }

    fn reg_get_string(&self, key: &str, name: Option<&str>) -> Option<String> {
        setup::reg_get_string(key, name)
    }

    fn reg_delete_key(&self, key: &str) -> io::Result<()> {
        setup::reg_delete_key(key)
    }

    fn reg_delete_value(&self, key: &str, name: Option<&str>) -> io::Result<()> {
        setup::reg_delete_value(key, name)
    }

    fn reg_delete_key_if_empty(&self, key: &str) -> io::Result<()> {
        setup::reg_delete_key_if_empty(key)
    }

    fn create_shortcut(&self, spec: &ShortcutSpec) -> io::Result<()> {
        setup::create_shortcut(&spec.link, &spec.target, &spec.working_dir, &spec.icon, &spec.aumid)
    }

    fn notify_assoc_changed(&self) {
        setup::notify_assoc_changed();
    }

    fn running_instances(&self, exe: &Path) -> Vec<u32> {
        setup::running_instances(exe)
    }

    fn request_close(&self, exe: &Path) {
        setup::request_close(exe);
    }

    fn delete_at_reboot(&self, path: &Path) -> io::Result<()> {
        setup::delete_at_reboot(path)
    }

    fn delete_after_exit(&self, path: &Path) -> io::Result<()> {
        use std::os::windows::process::CommandExt;
        use std::process::{Command, Stdio};
        const NO_WINDOW: u32 = 0x0800_0000;
        const NEW_GROUP: u32 = 0x0000_0200;
        const BREAKAWAY: u32 = 0x0100_0000;
        // `cmd` parses its own quoting, not Rust's `\"`, so the command goes in raw (an escaped path never matched a file).
        // It tries for 30 s: the file stays locked until this process has ended. The helper leaves our job object when it
        // may, so a harness that kills the process tree does not take it along.
        let file = path.display();
        let script = format!(
            "/D /C \"for /l %i in (1,1,30) do (del /f /q \"{file}\" >nul 2>&1 & if not exist \"{file}\" exit /b & ping -n 2 127.0.0.1 >nul)\""
        );
        let spawn = |flags: u32| {
            Command::new("cmd")
                .raw_arg(&script)
                .creation_flags(flags)
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
        };
        spawn(NO_WINDOW | NEW_GROUP | BREAKAWAY)
            .or_else(|_| spawn(NO_WINDOW | NEW_GROUP))
            .map(|_| ())
            .or_else(|_| setup::delete_at_reboot(path))
    }

    fn free_bytes(&self, path: &Path) -> Option<u64> {
        sq_platform_win::free_bytes(path).and_then(|b| u64::try_from(b).ok())
    }

    fn drive_label(&self, path: &Path) -> String {
        match path.components().next() {
            Some(Component::Prefix(p)) => p.as_os_str().to_string_lossy().into_owned(),
            _ => String::new(),
        }
    }

    fn windows_version(&self) -> String {
        setup::windows_version()
    }

    fn uses_light_theme(&self) -> bool {
        setup::uses_light_theme()
    }

    fn folders(&self) -> KnownFolders {
        let app_data = env_folder("APPDATA");
        KnownFolders {
            local_app_data: env_folder("LOCALAPPDATA"),
            desktop: setup::desktop_folder().unwrap_or_else(|| env_folder("USERPROFILE").join("Desktop")),
            start_menu_programs: setup::start_menu_programs_folder()
                .unwrap_or_else(|| app_data.join("Microsoft").join("Windows").join("Start Menu").join("Programs")),
            app_data,
            temp: std::env::temp_dir(),
        }
    }
}
