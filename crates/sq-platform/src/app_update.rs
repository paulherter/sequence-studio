//! Puts a downloaded and verified update in place. Linux (AppImage) replaces the file in place; the other systems answer
//! [`ApplyError::Unsupported`] until their installers are wired, and the updater then offers the download link instead.

use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

pub mod autotest;
mod mac;
pub mod windows;

use crate::desktop_integration::{self as di, AddEnd, DesktopEnv};

/// Why an update was not put in place.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ApplyError {
    /// This system has no in-place install (yet).
    Unsupported,
    /// The install failed; the text is for the user.
    Failed(String),
}

/// Whether [`apply_update`] can install here: a running AppImage, or a macOS app in a writable, untranslocated folder.
pub fn supported() -> bool {
    #[cfg(windows)]
    return windows::supported(&sq_setup_engine::WindowsHost, sq_setup_engine::Identity::build());
    #[cfg(target_os = "macos")]
    return mac::supported();
    #[cfg(not(any(windows, target_os = "macos")))]
    DesktopEnv::current().is_some()
}

/// What starts once this process has quit and let go of the single-instance claim.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Relaunch {
    /// The program to start.
    pub program: PathBuf,
    /// Its arguments.
    pub args: Vec<OsString>,
}

static RELAUNCH: Mutex<Option<Relaunch>> = Mutex::new(None);

/// Records what to start after the app has quit (the one restart mechanism of every system: the new instance would
/// otherwise meet the running one's claim and hand over to it). The last record wins.
pub fn set_relaunch(relaunch: Relaunch) {
    if let Ok(mut slot) = RELAUNCH.lock() {
        *slot = Some(relaunch);
    }
}

/// The recorded relaunch, once.
pub fn take_relaunch() -> Option<Relaunch> {
    RELAUNCH.lock().ok()?.take()
}

/// Starts the recorded relaunch, if any. Call it after the single-instance claim is released.
pub fn start_pending_relaunch() -> std::io::Result<()> {
    match take_relaunch() {
        Some(r) => start_detached(&r).map(|_| ()),
        None => Ok(()),
    }
}

/// Puts `staged` (a verified installer of `version`) in place of the running app; with `restart` the new app is
/// recorded as the [`Relaunch`] (it starts after the app quit); on macOS the swap script starts it itself, because the
/// swap must finish first, and nothing is recorded. The staged file is consumed.
pub fn apply_update(staged: &Path, version: &str, restart: bool) -> Result<(), ApplyError> {
    #[cfg(windows)]
    {
        let _ = version;
        return windows::apply(staged, restart);
    }
    #[cfg(target_os = "macos")]
    {
        let _ = version;
        return mac::apply(staged, restart);
    }
    #[cfg(not(any(windows, target_os = "macos")))]
    apply_appimage(staged, version, restart)
}

#[cfg(not(any(windows, target_os = "macos")))]
fn apply_appimage(staged: &Path, version: &str, restart: bool) -> Result<(), ApplyError> {
    let env = DesktopEnv::current().ok_or(ApplyError::Unsupported)?;
    let target = apply_with_env(&env, staged, version)?;
    if restart {
        set_relaunch(Relaunch { program: target, args: Vec::new() });
    }
    Ok(())
}

/// The replace step for an AppImage environment; returns the file that now holds the new version. The file the menu
/// entry starts is replaced (the existing in-place update, which also rewrites the entry); without an entry the running
/// file itself is replaced and no entry is added.
pub fn apply_with_env(env: &DesktopEnv, staged: &Path, version: &str) -> Result<PathBuf, ApplyError> {
    let failed = |e: &dyn std::fmt::Display| ApplyError::Failed(e.to_string());
    make_executable(staged).map_err(|e| failed(&e))?;
    if di::integrated_file(env).is_some() {
        let source = DesktopEnv { appimage: staged.to_path_buf(), version: version.to_string(), ..env.clone() };
        return match di::update(&source, &di::default_apps_dir(env), &mut |_, _| true) {
            Ok(AddEnd::Done { integrated }) => Ok(integrated),
            Ok(_) => Err(ApplyError::Failed("the update was canceled".into())),
            Err(e) => Err(failed(&e)),
        };
    }
    let target = env.appimage.clone();
    let name = target.file_name().and_then(|n| n.to_str()).unwrap_or("SequenceStudio.AppImage");
    let stage = target.with_file_name(format!("{name}.new"));
    // Staging sits next to the target, so the last step is one atomic rename; a running old app keeps its inode.
    if let Err(e) = std::fs::copy(staged, &stage) {
        let _ = std::fs::remove_file(&stage);
        return Err(failed(&e));
    }
    if let Err(e) = std::fs::rename(&stage, &target) {
        let _ = std::fs::remove_file(&stage);
        return Err(failed(&e));
    }
    let _ = std::fs::remove_file(staged);
    Ok(target)
}

#[cfg(unix)]
fn make_executable(file: &Path) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(file, std::fs::Permissions::from_mode(0o755))
}

#[cfg(not(unix))]
fn make_executable(_file: &Path) -> std::io::Result<()> {
    Ok(())
}

/// The folder the relaunched program starts in: its own. A child that inherits the quitting app's folder (the install folder,
/// where a shortcut starts it) keeps that folder busy, so the setup could not rename it away (os error 32).
#[cfg(any(windows, test))]
fn relaunch_dir(r: &Relaunch) -> Option<&Path> {
    r.program.parent().filter(|p| !p.as_os_str().is_empty())
}

/// Starts the program on its own, without the AppImage variables of the image that is quitting.
fn start_detached(r: &Relaunch) -> std::io::Result<std::process::Child> {
    let mut command = std::process::Command::new(&r.program);
    command
        .args(&r.args)
        .env_remove("APPIMAGE")
        .env_remove("APPDIR")
        .env_remove("ARGV0")
        .env_remove("OWD")
        .envs(autotest::relaunch_env_now())
        .stdin(std::process::Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        if let Some(dir) = relaunch_dir(r) {
            command.current_dir(dir);
        }
        // Own console-less process group; some job objects refuse the breakaway, which a harness may set.
        const DETACHED_PROCESS: u32 = 0x0000_0008;
        const NEW_GROUP: u32 = 0x0000_0200;
        const BREAKAWAY: u32 = 0x0100_0000;
        if let Ok(child) = command.creation_flags(DETACHED_PROCESS | NEW_GROUP | BREAKAWAY).spawn() {
            return Ok(child);
        }
        command.creation_flags(DETACHED_PROCESS | NEW_GROUP);
    }
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        // The AppImage runtime hands the app an open descriptor of its mount (fd 1023). A new program that inherits it keeps the
        // old image's mount busy, so the old runtime never unmounts and lingers. Close every descriptor above stderr.
        // SAFETY: only async-signal-safe calls (close_range / close) between fork and exec.
        unsafe {
            command.pre_exec(|| {
                #[cfg(target_os = "linux")]
                if libc::syscall(libc::SYS_close_range, 3u32, u32::MAX, 0u32) == 0 {
                    return Ok(());
                }
                // shortcut: fixed upper bound for kernels without close_range; raise it if descriptors above 4096 ever show up.
                for fd in 3..4096 {
                    libc::close(fd);
                }
                Ok(())
            });
        }
    }
    command.spawn()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rig(name: &str) -> (PathBuf, DesktopEnv) {
        let root = std::env::temp_dir().join(format!("sq-apply-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let appdir = root.join("mnt");
        for (rel, bytes) in [
            ("usr/share/applications/sequence-studio.desktop", &b"[Desktop Entry]\nExec=x\n"[..]),
            ("usr/share/mime/packages/de.paulherter.sequencestudio.xml", b"<mime-info/>"),
            ("usr/share/icons/hicolor/256x256/apps/sequence-studio.png", b"png"),
        ] {
            let p = appdir.join(rel);
            std::fs::create_dir_all(p.parent().expect("parent")).expect("dirs");
            std::fs::write(p, bytes).expect("file");
        }
        let appimage = root.join("home/Downloads/Old.AppImage");
        std::fs::create_dir_all(appimage.parent().expect("parent")).expect("dirs");
        std::fs::write(&appimage, b"old").expect("old");
        let env = DesktopEnv {
            appimage,
            appdir,
            data_home: root.join("home/.local/share"),
            home: root.join("home"),
            version: "0.2.0".into(),
            identity: crate::desktop_integration::Identity::STABLE,
        };
        (root, env)
    }

    #[test]
    fn without_a_menu_entry_the_running_file_is_replaced() {
        let (root, env) = rig("plain");
        let staged = root.join("cache/New.AppImage");
        std::fs::create_dir_all(staged.parent().expect("parent")).expect("dirs");
        std::fs::write(&staged, b"new").expect("new");
        assert_eq!(apply_with_env(&env, &staged, "0.3.0"), Ok(env.appimage.clone()));
        assert_eq!(std::fs::read(&env.appimage).expect("read"), b"new");
        assert!(!staged.exists());
        assert!(!env.appimage.with_file_name("Old.AppImage.new").exists());
        assert!(!env.data_home.join("applications").exists(), "an update must not add a menu entry");
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn with_a_menu_entry_the_entry_file_is_replaced() {
        let (root, env) = rig("menu");
        let apps = di::default_apps_dir(&env);
        let Ok(AddEnd::Done { integrated }) = di::add(&env, &apps, &mut |_, _| true) else { panic!("add failed") };
        // The running file moved into the apps folder; the new one replaces it there.
        let running = DesktopEnv { appimage: integrated.clone(), ..env };
        let staged = root.join("cache/New.AppImage");
        std::fs::create_dir_all(staged.parent().expect("parent")).expect("dirs");
        std::fs::write(&staged, b"new").expect("new");
        assert_eq!(apply_with_env(&running, &staged, "0.3.0"), Ok(integrated.clone()));
        assert_eq!(std::fs::read(&integrated).expect("read"), b"new");
        let entry =
            std::fs::read_to_string(running.data_home.join("applications/sequence-studio.desktop")).expect("entry");
        assert!(entry.contains("0.3.0"), "{entry}");
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn apply_with_restart_only_records_the_relaunch() {
        // The record is process-wide: this is the only test that sets it.
        assert_eq!(take_relaunch(), None);
        set_relaunch(Relaunch { program: "/x/New.AppImage".into(), args: vec!["--a".into()] });
        set_relaunch(Relaunch { program: "/x/Newer.AppImage".into(), args: Vec::new() });
        assert_eq!(take_relaunch().map(|r| r.program), Some(PathBuf::from("/x/Newer.AppImage")));
        assert_eq!(take_relaunch(), None);
        assert!(start_pending_relaunch().is_ok(), "nothing recorded, nothing started");
    }

    #[cfg(unix)]
    #[test]
    fn a_relaunch_starts_the_program_with_its_arguments() {
        let root = std::env::temp_dir().join(format!("sq-relaunch-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).expect("dir");
        let script = root.join("app.sh");
        let marker = root.join("started");
        std::fs::write(&script, b"#!/bin/sh\necho \"$1 ${APPIMAGE:-none}\" > \"$2\"\n").expect("script");
        make_executable(&script).expect("chmod");
        let r = Relaunch { program: script, args: vec!["hello".into(), marker.clone().into()] };
        let status = start_detached(&r).expect("start").wait().expect("wait");
        assert!(status.success());
        assert_eq!(std::fs::read_to_string(&marker).expect("marker").trim(), "hello none");
        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    #[test]
    fn a_relaunch_does_not_inherit_open_descriptors() {
        use std::os::fd::AsRawFd;
        let root = std::env::temp_dir().join(format!("sq-relaunch-fd-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).expect("dir");
        let held = std::fs::File::open(&root).expect("open dir");
        let fd = held.as_raw_fd();
        // Leave the descriptor open across exec, as the AppImage runtime does.
        // SAFETY: plain fcntl on a descriptor this test owns.
        unsafe {
            let flags = libc::fcntl(fd, libc::F_GETFD);
            libc::fcntl(fd, libc::F_SETFD, flags & !libc::FD_CLOEXEC);
        }
        let script = root.join("app.sh");
        let marker = root.join("state");
        std::fs::write(
            &script,
            format!("#!/bin/sh\nif {{ true >&{fd}; }} 2>/dev/null; then echo open; else echo closed; fi > \"$1\"\n"),
        )
        .expect("script");
        make_executable(&script).expect("chmod");
        let r = Relaunch { program: script, args: vec![marker.clone().into()] };
        assert!(start_detached(&r).expect("start").wait().expect("wait").success());
        assert_eq!(std::fs::read_to_string(&marker).expect("marker").trim(), "closed");
        drop(held);
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn a_failed_copy_leaves_no_stage_file() {
        let (root, env) = rig("copyfail");
        // The staged path is a folder: the copy fails.
        let staged = root.join("cache");
        std::fs::create_dir_all(&staged).expect("dir");
        let got = apply_with_env(&env, &staged, "0.3.0");
        assert!(matches!(got, Err(ApplyError::Failed(_))));
        assert!(!env.appimage.with_file_name("Old.AppImage.new").exists());
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn the_relaunched_program_starts_in_its_own_folder_not_the_one_being_replaced() {
        let r = Relaunch { program: PathBuf::from("/cache/Updates/1.2.3/Setup.exe"), args: Vec::new() };
        assert_eq!(relaunch_dir(&r), Some(Path::new("/cache/Updates/1.2.3")));
        assert_eq!(relaunch_dir(&Relaunch { program: PathBuf::from("Setup.exe"), args: Vec::new() }), None);
    }

    #[test]
    fn a_missing_staged_file_fails_and_leaves_the_app() {
        let (root, env) = rig("missing");
        let got = apply_with_env(&env, &root.join("nope"), "0.3.0");
        assert!(matches!(got, Err(ApplyError::Failed(_))));
        assert_eq!(std::fs::read(&env.appimage).expect("read"), b"old");
        let _ = std::fs::remove_dir_all(root);
    }
}
