//! Menu entry and `.sqproj` association for the Linux AppImage. An AppImage does not install itself, so the app offers to
//! move the AppImage to `~/Applications` and to write the desktop file, the icon and the MIME type into the user's data
//! folder (`~/.local/share`), the way AppImage helper tools do, and removes exactly those files again. The logic is plain
//! file work and runs on any host; only the Linux build reads the AppImage's environment (`APPIMAGE`, `APPDIR`).

use sq_setup_engine::Version;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

const DESKTOP_FILE: &str = "sequence-studio.desktop";
/// The window's app id (Wayland `app_id`, X11 class): the desktop entry's id without `.desktop`, so the dock and taskbar
/// match the entry and its icon.
pub const APP_ID: &str = "sequence-studio";
const MIME_FILE: &str = "de.paulherter.sequencestudio.xml";
const ICON_FILE: &str = "sequence-studio.png";
/// Beside the user's data: remembers a "No thanks" so the offer does not come back every start.
/// The stable name of the integrated AppImage: the menu entry keeps working across versions.
pub const INTEGRATED_NAME: &str = "SequenceStudio.AppImage";
/// The desktop file key that says which version the integrated file is.
const VERSION_KEY: &str = "X-AppImage-Version";
const DECLINED_MARKER: &str = "sequence-studio/desktop-offer-declined";

/// Where the AppImage is and where its files go.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DesktopEnv {
    /// The `.AppImage` file that runs (`$APPIMAGE`).
    pub appimage: PathBuf,
    /// The mounted image (`$APPDIR`): the desktop file, MIME file and icon are in its `usr/share`.
    pub appdir: PathBuf,
    /// `$XDG_DATA_HOME` or `~/.local/share`.
    pub data_home: PathBuf,
    /// The user's home folder (`$HOME`): `~/Applications` and the `~` in shown paths.
    pub home: PathBuf,
    /// The version of the running AppImage (the workspace version, the one `AppVersion` shows).
    pub version: String,
}

impl DesktopEnv {
    /// `None` when the app does not run from an AppImage or the environment names no data folder.
    pub fn from_env(env: impl Fn(&str) -> Option<std::ffi::OsString>) -> Option<Self> {
        let appimage = PathBuf::from(env("APPIMAGE").filter(|v| !v.is_empty())?);
        let appdir = PathBuf::from(env("APPDIR").filter(|v| !v.is_empty())?);
        let home = PathBuf::from(env("HOME").filter(|v| !v.is_empty())?);
        let data_home = sq_os::Platform::Linux.data_dir(&env)?;
        Some(Self { appimage, appdir, data_home, home, version: env!("CARGO_PKG_VERSION").to_string() })
    }

    /// The running AppImage's environment, on Linux only.
    pub fn current() -> Option<Self> {
        if cfg!(target_os = "linux") { Self::from_env(|k| std::env::var_os(k)) } else { None }
    }

    fn desktop_path(&self) -> PathBuf {
        self.data_home.join("applications").join(DESKTOP_FILE)
    }
    fn mime_path(&self) -> PathBuf {
        self.data_home.join("mime/packages").join(MIME_FILE)
    }
    fn icon_path(&self) -> PathBuf {
        self.data_home.join("icons/hicolor/256x256/apps").join(ICON_FILE)
    }
    fn marker_path(&self) -> PathBuf {
        self.data_home.join(DECLINED_MARKER)
    }

    /// `path` with the home folder written as `~`, the way the screens show it.
    pub fn tilde(&self, path: &Path) -> String {
        match path.strip_prefix(&self.home) {
            Ok(rest) if rest.as_os_str().is_empty() => "~".to_string(),
            Ok(rest) => format!("~/{}", rest.display()),
            Err(_) => path.display().to_string(),
        }
    }
}

/// What the app knows about its menu entry. One value drives the Settings row and the first-run window.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DesktopState {
    /// Not an AppImage run (a build from source, the Mac, Windows): nothing to offer.
    Unavailable,
    /// Not installed and not turned down: offer it.
    Offer,
    /// Turned down: only Settings > General offers it.
    Declined,
    /// Installed; the integrated file is this version or newer (a newer one just runs, no question).
    Installed,
    /// Installed, but the integrated file is older than the running AppImage: offer an update.
    Outdated {
        /// The version in the desktop file.
        installed: String,
    },
    /// The entry is there but its file is gone, or it is an old entry without a version: refreshed without asking.
    Stale,
}

/// Why adding, updating or removing failed: the code and details the error screens show (spec section 11).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SetupFailure {
    /// 301 the data folder is not writable, 302 the AppImage move failed, 399 anything else.
    pub code: u16,
    /// What was being done (`moving the AppImage`).
    pub step: String,
    /// The file or folder concerned.
    pub path: Option<PathBuf>,
    /// The OS message.
    pub system: String,
}

impl SetupFailure {
    fn new(code: u16, step: &str, path: Option<&Path>, error: impl std::fmt::Display) -> Self {
        Self { code, step: step.to_string(), path: path.map(Path::to_path_buf), system: error.to_string() }
    }
}

impl std::fmt::Display for SetupFailure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "SQI-{} {}: {}", self.code, self.step, self.system)
    }
}

/// How [`add`] and [`update`] ended.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AddEnd {
    /// The AppImage is in the apps folder and the menu entry points at it.
    Done {
        /// The integrated file.
        integrated: PathBuf,
    },
    /// The user canceled during the copy; nothing changed.
    Canceled,
}

/// The desktop file's `Exec` value for `path`: quoted as the Desktop Entry spec asks, then `%F` for the files to open.
pub fn exec_line(path: &Path) -> String {
    let mut quoted = String::from("\"");
    for c in path.to_string_lossy().chars() {
        // Exec quoting escapes these with a backslash, and the file's string syntax doubles that backslash.
        if matches!(c, '"' | '`' | '$' | '\\') {
            quoted.push_str("\\\\");
        } else if c == '%' {
            quoted.push('%'); // a literal percent is written %%
        }
        quoted.push(c);
    }
    quoted.push('"');
    format!("{quoted} %F")
}

/// The program path of an `Exec` value written by [`exec_line`]; `None` for any other shape.
fn parse_exec(value: &str) -> Option<PathBuf> {
    let inner = value.strip_prefix('"')?;
    let mut out = String::new();
    let mut chars = inner.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '"' => return Some(PathBuf::from(out)),
            '\\' if chars.peek() == Some(&'\\') => {
                chars.next();
                out.push(chars.next()?);
            }
            '%' if chars.peek() == Some(&'%') => {
                chars.next();
                out.push('%');
            }
            _ => out.push(c),
        }
    }
    None
}

/// The bundled desktop file with `Exec` pointing at the AppImage and the version of it.
fn desktop_text(template: &str, appimage: &Path, version: &str) -> String {
    let mut out = String::new();
    for line in template.lines() {
        if line.starts_with(VERSION_KEY) {
            continue;
        }
        if line.starts_with("Exec=") {
            out.push_str(&format!("Exec={}\n{VERSION_KEY}={version}", exec_line(appimage)));
        } else {
            out.push_str(line);
        }
        out.push('\n');
    }
    out
}

/// The `Exec` program and the version of the desktop file on disk.
fn read_entry(env: &DesktopEnv) -> Option<(Option<PathBuf>, Option<String>)> {
    let text = std::fs::read_to_string(env.desktop_path()).ok()?;
    let value = |key: &str| text.lines().find_map(|l| l.strip_prefix(key)?.strip_prefix('='));
    Some((value("Exec").and_then(parse_exec), value(VERSION_KEY).map(str::to_string)))
}

/// The AppImage file the menu entry starts, when the entry is there and the file exists.
pub fn integrated_file(env: &DesktopEnv) -> Option<PathBuf> {
    read_entry(env)?.0.filter(|p| p.is_file())
}

/// The folder the AppImage moves to: `~/Applications`.
pub fn default_apps_dir(env: &DesktopEnv) -> PathBuf {
    env.home.join("Applications")
}

/// Whether the running AppImage and `integrated` are the same file.
fn runs_integrated_file(env: &DesktopEnv, integrated: &Path) -> bool {
    matches!((std::fs::canonicalize(&env.appimage), std::fs::canonicalize(integrated)), (Ok(a), Ok(b)) if a == b)
}

/// The current state, from the files on disk.
pub fn state(env: Option<&DesktopEnv>) -> DesktopState {
    let Some(env) = env else { return DesktopState::Unavailable };
    let Some((exec, version)) = read_entry(env) else {
        return if env.marker_path().exists() { DesktopState::Declined } else { DesktopState::Offer };
    };
    let (Some(exec), Some(installed)) = (exec, version) else { return DesktopState::Stale };
    if !exec.is_file() {
        return DesktopState::Stale;
    }
    match (Version::parse(&installed), Version::parse(&env.version)) {
        // The running file IS the integrated one (replaced in place by a newer build): only the recorded version is old.
        (Some(have), Some(running)) if have < running && runs_integrated_file(env, &exec) => {
            DesktopState::Stale
        }
        (Some(have), Some(running)) if have < running => DesktopState::Outdated { installed },
        (Some(_), Some(_)) => DesktopState::Installed,
        _ if installed == env.version => DesktopState::Installed,
        _ => DesktopState::Stale,
    }
}

fn write(path: &Path, bytes: &[u8]) -> Result<(), String> {
    let dir = path.parent().ok_or("no folder")?;
    std::fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    std::fs::write(path, bytes).map_err(|e| format!("{}: {e}", path.display()))
}

/// Tells the desktop about changed files; the tools may be missing, which only delays the menu by a re-login.
fn refresh_caches(env: &DesktopEnv) {
    for (tool, dir) in [
        ("update-mime-database", env.data_home.join("mime")),
        ("update-desktop-database", env.data_home.join("applications")),
    ] {
        if !dir.is_dir() {
            continue;
        }
        let _ = Command::new(tool).arg(dir).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).status();
    }
}

/// Writes the desktop file (`Exec` at `exec`), the MIME type and the icon, and clears a "No thanks".
fn write_entry(env: &DesktopEnv, exec: &Path) -> Result<(), SetupFailure> {
    let share = env.appdir.join("usr/share");
    let read =
        |p: PathBuf| std::fs::read(&p).map_err(|e| SetupFailure::new(399, "reading the app's files", Some(&p), e));
    let template = read(share.join("applications").join(DESKTOP_FILE))?;
    let template =
        String::from_utf8(template).map_err(|e| SetupFailure::new(399, "reading the app's files", None, e))?;
    let mime = read(share.join("mime/packages").join(MIME_FILE))?;
    let icon = read(share.join("icons/hicolor/256x256/apps").join(ICON_FILE))?;
    let put = |p: PathBuf, bytes: &[u8]| {
        write(&p, bytes).map_err(|e| SetupFailure::new(301, "writing the menu entry", Some(&p), e))
    };
    put(env.mime_path(), &mime)?;
    put(env.icon_path(), &icon)?;
    put(env.desktop_path(), desktop_text(&template, exec, &env.version).as_bytes())?;
    let _ = std::fs::remove_file(env.marker_path());
    Ok(())
}

/// Points the menu entry at the running AppImage where it is, without moving it (an old entry or a missing file).
pub fn refresh(env: &DesktopEnv) -> Result<(), SetupFailure> {
    write_entry(env, &env.appimage)?;
    refresh_caches(env);
    Ok(())
}

/// What a move reports: done, or the user canceled it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Moved {
    Done,
    Canceled,
}

/// Moves `src` to `dst`: `rename(2)` on the same file system, else a copy. `progress(done, total)` answers false to cancel.
fn move_file(src: &Path, dst: &Path, progress: &mut dyn FnMut(u64, u64) -> bool) -> std::io::Result<Moved> {
    // Any rename failure falls back to the copy: across file systems it is EXDEV, and a copy that fails for another
    // reason reports that reason itself.
    if std::fs::rename(src, dst).is_ok() {
        let size = std::fs::metadata(dst).map(|m| m.len()).unwrap_or(0);
        progress(size, size);
        return Ok(Moved::Done);
    }
    copy_file(src, dst, progress)
}

/// Copies `src` to `dst` with byte progress, syncs it, then removes `src` (a running AppImage keeps working: its mount
/// holds the inode). A canceled or failed copy removes the partial file and keeps `src`.
fn copy_file(src: &Path, dst: &Path, progress: &mut dyn FnMut(u64, u64) -> bool) -> std::io::Result<Moved> {
    let result = copy_chunks(src, dst, progress);
    if !matches!(result, Ok(Moved::Done)) {
        let _ = std::fs::remove_file(dst);
    } else {
        // The copy is complete and synced; a source that cannot be removed only stays behind.
        let _ = std::fs::remove_file(src);
    }
    result
}

fn copy_chunks(src: &Path, dst: &Path, progress: &mut dyn FnMut(u64, u64) -> bool) -> std::io::Result<Moved> {
    let mut input = std::fs::File::open(src)?;
    let meta = input.metadata()?;
    let mut out = std::fs::File::create(dst)?;
    let mut buf = vec![0u8; 1 << 20];
    let mut done = 0u64;
    loop {
        let n = input.read(&mut buf)?;
        if n == 0 {
            break;
        }
        out.write_all(&buf[..n])?;
        done += n as u64;
        if !progress(done, meta.len()) {
            return Ok(Moved::Canceled);
        }
    }
    out.sync_all()?;
    std::fs::set_permissions(dst, meta.permissions())?;
    Ok(Moved::Done)
}

fn create_apps_dir(dir: &Path) -> std::io::Result<()> {
    let mut b = std::fs::DirBuilder::new();
    b.recursive(true);
    #[cfg(unix)]
    std::os::unix::fs::DirBuilderExt::mode(&mut b, 0o755);
    b.create(dir)
}

/// Moves `path` to the XDG trash (`<data>/Trash/files` + `info/<name>.trashinfo`, a free name on a clash).
fn trash_file(env: &DesktopEnv, path: &Path) -> std::io::Result<()> {
    #[cfg(unix)]
    {
        if sq_trash::freedesktop::trash_into(path, &env.data_home.join("Trash"), None).is_ok() {
            return Ok(());
        }
    }
    #[cfg(not(unix))]
    let _ = env;
    // Another file system than the home trash, or no unix trash: the system function finds the right one.
    sq_trash::trash(path)
}

/// Adds the app to the menu: moves the running AppImage to `apps_dir` as `SequenceStudio.AppImage` (nothing moves when it
/// already sits there), writes the desktop file with that `Exec` and the version, the MIME type and the icon.
/// `progress(done, total)` reports the bytes of a copy and answers false to cancel; a cancel or a failure leaves the
/// original and the old menu state as they were.
pub fn add(
    env: &DesktopEnv,
    apps_dir: &Path,
    progress: &mut dyn FnMut(u64, u64) -> bool,
) -> Result<AddEnd, SetupFailure> {
    integrate(env, &apps_dir.join(INTEGRATED_NAME), move_file, progress)
}

/// Replaces the integrated AppImage with the running one (the old file goes to the XDG trash) and rewrites the entry.
/// Same steps and results as [`add`]. The file replaced is the one the entry starts (wherever it lives and whatever its
/// name); `apps_dir` is only used when there is no such file, and a file given as `apps_dir` counts as its folder.
/// Staging happens next to the target, so the last step is one atomic rename on one file system.
pub fn update(
    env: &DesktopEnv,
    apps_dir: &Path,
    progress: &mut dyn FnMut(u64, u64) -> bool,
) -> Result<AddEnd, SetupFailure> {
    let target = integrated_file(env).unwrap_or_else(|| {
        let dir = if apps_dir.is_file() { apps_dir.parent().unwrap_or(apps_dir) } else { apps_dir };
        dir.join(INTEGRATED_NAME)
    });
    integrate(env, &target, move_file, progress)
}

fn integrate(
    env: &DesktopEnv,
    target: &Path,
    mover: impl Fn(&Path, &Path, &mut dyn FnMut(u64, u64) -> bool) -> std::io::Result<Moved>,
    progress: &mut dyn FnMut(u64, u64) -> bool,
) -> Result<AddEnd, SetupFailure> {
    let apps_dir = target.parent().unwrap_or(Path::new("."));
    let was_declined = env.marker_path().exists();
    // The entry goes first: a data folder that does not allow writing fails before the AppImage is touched.
    let undo = |failure: SetupFailure| {
        let _ = remove(env, false);
        if was_declined {
            let _ = write(&env.marker_path(), b"declined\n");
        }
        failure
    };
    write_entry(env, target).map_err(undo)?;
    let already_there = match (std::fs::canonicalize(&env.appimage), std::fs::canonicalize(target)) {
        (Ok(a), Ok(b)) => a == b,
        _ => false,
    };
    if !already_there {
        let moving = |e: std::io::Error| SetupFailure::new(302, "moving the AppImage", Some(apps_dir), e);
        create_apps_dir(apps_dir).map_err(|e| undo(moving(e)))?;
        let stage = apps_dir.join(format!("{}.new", target.file_name().and_then(|n| n.to_str()).unwrap_or(INTEGRATED_NAME)));
        match mover(&env.appimage, &stage, progress) {
            Ok(Moved::Done) => {}
            Ok(Moved::Canceled) => {
                let _ = undo(SetupFailure::new(399, "canceled", None, "canceled"));
                return Ok(AddEnd::Canceled);
            }
            Err(e) => return Err(undo(moving(e))),
        }
        // The old file goes to the trash when it can; a trash that refuses must not stop the update, the rename below
        // replaces the old file atomically either way (a running old app keeps its inode).
        if target.exists() {
            let _ = trash_file(env, target);
        }
        if let Err(e) = std::fs::rename(&stage, target) {
            let _ = std::fs::remove_file(&stage);
            return Err(undo(SetupFailure::new(302, "moving the AppImage", Some(target), e)));
        }
    }
    refresh_caches(env);
    Ok(AddEnd::Done { integrated: target.to_path_buf() })
}

/// Deletes the three files this module wrote (and a "No thanks").
fn remove_files(env: &DesktopEnv) -> Result<(), SetupFailure> {
    for p in [env.desktop_path(), env.mime_path(), env.icon_path(), env.marker_path()] {
        match std::fs::remove_file(&p) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(SetupFailure::new(301, "removing the menu entry", Some(&p), e)),
        }
    }
    Ok(())
}

/// Deletes the three files this module wrote (and a "No thanks"), then the folders and the generated caches that only
/// they kept alive. Files of other programs stay. With `trash_app_file` the integrated AppImage goes to the XDG trash
/// first (a failure there removes nothing).
pub fn remove(env: &DesktopEnv, trash_app_file: bool) -> Result<(), SetupFailure> {
    if trash_app_file && let Some(file) = integrated_file(env) {
        trash_file(env, &file)
            .map_err(|e| SetupFailure::new(399, "moving the app file to the Trash", Some(&file), e))?;
    }
    remove_files(env)?;
    let (mime, apps) = (env.data_home.join("mime"), env.data_home.join("applications"));
    let is_empty = |dir: &Path| std::fs::read_dir(dir).map(|mut d| d.next().is_none()).unwrap_or(true);
    if is_empty(&mime.join("packages")) {
        // No type package left: the generated database is only ours.
        let _ = std::fs::remove_dir_all(&mime);
    }
    let has_desktop_file = std::fs::read_dir(&apps)
        .map(|d| d.flatten().any(|e| e.path().extension().is_some_and(|x| x == "desktop")))
        .unwrap_or(false);
    if !has_desktop_file {
        for cache in ["mimeinfo.cache", "intent.cache"] {
            let _ = std::fs::remove_file(apps.join(cache));
        }
    }
    // Empty folders go (never the data folder itself); `remove_dir` refuses a folder that still holds something.
    for dir in [
        apps,
        env.data_home.join("icons/hicolor/256x256/apps"),
        env.data_home.join("icons/hicolor/256x256"),
        env.data_home.join("icons/hicolor"),
        env.data_home.join("icons"),
        env.data_home.join("sequence-studio"),
    ] {
        let _ = std::fs::remove_dir(dir);
    }
    refresh_caches(env);
    Ok(())
}

/// Remembers "No thanks".
pub fn decline(env: &DesktopEnv) -> Result<(), SetupFailure> {
    let p = env.marker_path();
    write(&p, b"declined\n").map_err(|e| SetupFailure::new(301, "saving your answer", Some(&p), e))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_window_app_id_is_the_id_of_the_installed_desktop_entry() {
        assert_eq!(format!("{APP_ID}.desktop"), DESKTOP_FILE);
        let entry = include_str!("../../../packaging/linux/sequence-studio.desktop");
        assert!(entry.lines().any(|l| l == format!("StartupWMClass={APP_ID}")));
    }

    fn rig(name: &str) -> (PathBuf, DesktopEnv) {
        let root = std::env::temp_dir().join(format!("sq-desktop-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let appdir = root.join("mnt");
        let desktop = b"[Desktop Entry]\nName=Sequence Studio\nExec=sequence-studio %F\nIcon=sequence-studio\n";
        write(&appdir.join("usr/share/applications").join(DESKTOP_FILE), desktop).expect("desktop");
        write(&appdir.join("usr/share/mime/packages").join(MIME_FILE), b"<mime-info/>").expect("mime");
        write(&appdir.join("usr/share/icons/hicolor/256x256/apps").join(ICON_FILE), b"png").expect("icon");
        let appimage = root.join("home/Downloads/SequenceStudio-0.2.0-x86_64.AppImage");
        write(&appimage, b"appimage-bytes").expect("appimage");
        let env = DesktopEnv {
            appimage,
            appdir,
            data_home: root.join("home/.local/share"),
            home: root.join("home"),
            version: "0.2.0".into(),
        };
        (root, env)
    }

    fn no_progress() -> impl FnMut(u64, u64) -> bool {
        |_, _| true
    }

    fn added(env: &DesktopEnv) -> PathBuf {
        match add(env, &default_apps_dir(env), &mut no_progress()) {
            Ok(AddEnd::Done { integrated }) => integrated,
            other => panic!("add did not finish: {other:?}"),
        }
    }

    #[test]
    fn outside_an_appimage_nothing_is_offered() {
        assert_eq!(state(None), DesktopState::Unavailable);
        let none = |_: &str| None;
        assert_eq!(DesktopEnv::from_env(none), None);
        let only_home = |k: &str| (k == "HOME").then(|| "/h".into());
        assert_eq!(DesktopEnv::from_env(only_home), None);
        let full = |k: &str| match k {
            "APPIMAGE" => Some("/a/X.AppImage".into()),
            "APPDIR" => Some("/tmp/.mount_x".into()),
            "HOME" => Some("/h".into()),
            _ => None,
        };
        let env = DesktopEnv::from_env(full).expect("env");
        assert_eq!(env.data_home, PathBuf::from("/h/.local/share"));
        assert_eq!(default_apps_dir(&env), PathBuf::from("/h/Applications"));
        assert_eq!(env.tilde(Path::new("/h/Applications/X")), "~/Applications/X");
    }

    #[test]
    fn add_on_one_file_system_renames_into_a_0755_apps_folder_and_writes_the_entry() {
        let (root, env) = rig("add");
        assert_eq!(state(Some(&env)), DesktopState::Offer);
        let target = added(&env);
        assert_eq!(target, root.join("home/Applications/SequenceStudio.AppImage"));
        assert_eq!(std::fs::read(&target).expect("file"), b"appimage-bytes");
        assert!(!env.appimage.exists(), "moved, not copied");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(root.join("home/Applications")).expect("dir").permissions().mode();
            assert_eq!(mode & 0o777, 0o755);
        }
        assert_eq!(state(Some(&env)), DesktopState::Installed);
        assert_eq!(integrated_file(&env), Some(target.clone()));
        let text = std::fs::read_to_string(env.desktop_path()).expect("desktop");
        assert!(text.contains(&format!("Exec=\"{}\" %F\n", target.display())), "{text}");
        assert!(text.contains("X-AppImage-Version=0.2.0\n") && text.contains("Icon=sequence-studio"));
        assert_eq!(std::fs::read(env.mime_path()).expect("mime"), b"<mime-info/>");
        assert_eq!(std::fs::read(env.icon_path()).expect("icon"), b"png");
        assert!(!apps_leftovers(&root), "no staging file stays");
        let _ = std::fs::remove_dir_all(root);
    }

    fn apps_leftovers(root: &Path) -> bool {
        root.join("home/Applications/SequenceStudio.AppImage.new").exists()
    }

    #[test]
    fn an_appimage_already_at_the_target_does_not_move() {
        let (root, mut env) = rig("same");
        let target = root.join("home/Applications").join(INTEGRATED_NAME);
        write(&target, b"appimage-bytes").expect("file");
        env.appimage = target.clone();
        let calls = std::cell::Cell::new(0);
        let mover = |_: &Path, _: &Path, _: &mut dyn FnMut(u64, u64) -> bool| {
            calls.set(calls.get() + 1);
            Ok(Moved::Done)
        };
        let end = integrate(&env, &target, mover, &mut no_progress());
        assert_eq!(end, Ok(AddEnd::Done { integrated: target }));
        assert_eq!(calls.get(), 0);
        assert_eq!(state(Some(&env)), DesktopState::Installed);
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn the_cross_device_branch_copies_with_progress_and_removes_the_original() {
        let (root, env) = rig("copy");
        let big = vec![7u8; 3 * (1 << 20) + 5];
        std::fs::write(&env.appimage, &big).expect("big");
        // A mover that never renames stands in for a second file system.
        let mut seen = Vec::new();
        let end = integrate(&env, &default_apps_dir(&env).join(INTEGRATED_NAME), copy_file, &mut |d, t| {
            seen.push((d, t));
            true
        });
        let target = root.join("home/Applications").join(INTEGRATED_NAME);
        assert_eq!(end, Ok(AddEnd::Done { integrated: target.clone() }));
        assert_eq!(std::fs::read(&target).expect("file"), big);
        assert!(!env.appimage.exists());
        assert_eq!(seen.len(), 4, "one report per megabyte chunk: {seen:?}");
        assert_eq!(seen.last(), Some(&(big.len() as u64, big.len() as u64)));
        assert!(!apps_leftovers(&root));
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn a_canceled_copy_keeps_the_original_leaves_no_partial_file_and_restores_the_state() {
        let (root, env) = rig("cancel");
        std::fs::write(&env.appimage, vec![1u8; 3 << 20]).expect("big");
        decline(&env).expect("decline");
        let end = integrate(&env, &default_apps_dir(&env).join(INTEGRATED_NAME), copy_file, &mut |done, _| done < (1 << 20));
        assert_eq!(end, Ok(AddEnd::Canceled));
        assert!(env.appimage.is_file(), "the original stays");
        let apps = root.join("home/Applications");
        let left: Vec<_> = std::fs::read_dir(&apps).map(|d| d.flatten().collect()).unwrap_or_default();
        assert!(left.is_empty(), "no partial file: {left:?}");
        assert_eq!(state(Some(&env)), DesktopState::Declined, "the earlier No Thanks is back");
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn a_failed_move_is_302_and_writes_nothing() {
        let (root, env) = rig("move-fails");
        let mover = |_: &Path, _: &Path, _: &mut dyn FnMut(u64, u64) -> bool| Err(std::io::Error::other("disk gone"));
        let end = integrate(&env, &default_apps_dir(&env).join(INTEGRATED_NAME), mover, &mut no_progress()).expect_err("fails");
        assert_eq!((end.code, end.step.as_str()), (302, "moving the AppImage"));
        assert!(end.system.contains("disk gone"));
        assert!(env.appimage.is_file());
        assert_eq!(state(Some(&env)), DesktopState::Offer);
        assert!(!env.desktop_path().exists());
        // A missing source fails the real mover the same way.
        let _ = std::fs::remove_file(&env.appimage);
        let end = add(&env, &default_apps_dir(&env), &mut no_progress()).expect_err("fails");
        assert_eq!(end.code, 302);
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn an_unwritable_data_folder_is_301_and_the_appimage_stays() {
        let (root, mut env) = rig("data-301");
        // A file where the data folder should be: nothing can be written below it, whoever runs the test.
        env.data_home = root.join("a-file");
        std::fs::write(&env.data_home, b"x").expect("file");
        let end = add(&env, &default_apps_dir(&env), &mut no_progress()).expect_err("fails");
        assert_eq!(end.code, 301);
        assert!(env.appimage.is_file());
        assert!(!root.join("home/Applications").exists());
        assert_eq!(decline(&env).expect_err("fails").code, 301);
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn a_build_replaced_in_place_is_refreshed_not_offered_as_an_update() {
        let (root, mut env) = rig("in-place");
        env.version = "0.2.0".into();
        let target = added(&env);
        // The user overwrites the integrated file with 0.2.1 and starts it.
        env.version = "0.2.1".into();
        env.appimage = target.clone();
        assert_eq!(state(Some(&env)), DesktopState::Stale);
        refresh(&env).expect("refresh");
        assert_eq!(state(Some(&env)), DesktopState::Installed);
        let entry = std::fs::read_to_string(env.desktop_path()).expect("entry");
        assert!(entry.contains("0.2.1"), "{entry}");
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn an_older_integrated_file_is_outdated_and_update_trashes_it() {
        let (root, mut env) = rig("update");
        env.version = "0.1.2".into();
        let target = added(&env);
        assert_eq!(state(Some(&env)), DesktopState::Installed);
        // A new release starts: another file, a newer version.
        env.version = "0.2.0".into();
        env.appimage = root.join("home/Downloads/SequenceStudio-0.2.0-x86_64.AppImage");
        write(&env.appimage, b"new-bytes").expect("new");
        assert_eq!(state(Some(&env)), DesktopState::Outdated { installed: "0.1.2".into() });
        let end = update(&env, &default_apps_dir(&env), &mut no_progress());
        assert_eq!(end, Ok(AddEnd::Done { integrated: target.clone() }));
        assert_eq!(std::fs::read(&target).expect("file"), b"new-bytes");
        assert_eq!(state(Some(&env)), DesktopState::Installed);
        let trashed = env.data_home.join("Trash/files").join(INTEGRATED_NAME);
        assert_eq!(std::fs::read(trashed).expect("trashed"), b"appimage-bytes");
        let info =
            std::fs::read_to_string(env.data_home.join("Trash/info").join(format!("{INTEGRATED_NAME}.trashinfo")))
                .expect("info");
        assert!(info.starts_with("[Trash Info]\nPath=") && info.contains("/Applications/SequenceStudio.AppImage\n"));
        assert!(info.contains("DeletionDate="));
        // A second update finds the name taken in the trash and picks a new one.
        write(&env.appimage, b"newer-bytes").expect("newer");
        env.version = "0.3.0".into();
        update(&env, &default_apps_dir(&env), &mut no_progress()).expect("again");
        assert!(env.data_home.join("Trash/files/SequenceStudio 2.AppImage").is_file());
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn update_given_the_integrated_file_as_location_replaces_it_and_keeps_other_files() {
        // The Linux update screen once passed the integrated FILE as the folder: 302 "couldn't be moved".
        let (root, mut env) = rig("update-file");
        env.version = "0.2.0".into();
        let target = added(&env);
        let bak = target.with_file_name("SequenceStudio.AppImage.bak");
        write(&bak, b"old-copy").expect("bak");
        env.version = "0.2.1".into();
        env.appimage = root.join("home/Downloads/SequenceStudio-0.2.1-x86_64.AppImage");
        write(&env.appimage, b"new-bytes").expect("new");
        let end = update(&env, &target, &mut no_progress());
        assert_eq!(end, Ok(AddEnd::Done { integrated: target.clone() }));
        assert_eq!(std::fs::read(&target).expect("file"), b"new-bytes");
        assert_eq!(std::fs::read(&bak).expect("bak"), b"old-copy");
        assert!(!apps_leftovers(&root));
        assert_eq!(state(Some(&env)), DesktopState::Installed);
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn update_still_replaces_when_the_trash_refuses() {
        let (root, mut env) = rig("update-trash");
        env.version = "0.2.0".into();
        let target = added(&env);
        env.version = "0.2.1".into();
        env.appimage = root.join("home/Downloads/SequenceStudio-0.2.1-x86_64.AppImage");
        write(&env.appimage, b"new-bytes").expect("new");
        // A file where the trash folder must go: the trash cannot take the old file.
        write(&env.data_home.join("Trash"), b"in the way").expect("block");
        assert!(update(&env, &default_apps_dir(&env), &mut no_progress()).is_ok());
        assert_eq!(std::fs::read(&target).expect("file"), b"new-bytes");
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn update_reached_with_the_integrated_file_running_changes_nothing_and_asks_nothing() {
        let (root, mut env) = rig("update-inplace");
        env.version = "0.2.0".into();
        let target = added(&env);
        env.version = "0.2.1".into();
        env.appimage = target.clone();
        let end = update(&env, &default_apps_dir(&env), &mut no_progress());
        assert_eq!(end, Ok(AddEnd::Done { integrated: target.clone() }));
        assert_eq!(std::fs::read(&target).expect("file"), b"appimage-bytes");
        assert_eq!(state(Some(&env)), DesktopState::Installed);
        assert!(!env.data_home.join("Trash/files").exists(), "nothing trashed");
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn a_newer_integrated_file_just_runs_and_a_missing_file_is_stale() {
        let (root, mut env) = rig("newer");
        env.version = "0.3.0".into();
        let target = added(&env);
        env.version = "0.2.0".into();
        env.appimage = root.join("home/Downloads/Old.AppImage");
        assert_eq!(state(Some(&env)), DesktopState::Installed, "no question for an older AppImage");
        std::fs::remove_file(&target).expect("remove");
        assert_eq!(state(Some(&env)), DesktopState::Stale);
        write(&env.appimage, b"x").expect("old");
        refresh(&env).expect("refresh");
        assert_eq!(state(Some(&env)), DesktopState::Installed);
        assert_eq!(integrated_file(&env), Some(env.appimage.clone()));
        // An entry from before the version key is refreshed too.
        let text = std::fs::read_to_string(env.desktop_path()).expect("desktop");
        let legacy: String = text.lines().filter(|l| !l.starts_with(VERSION_KEY)).map(|l| format!("{l}\n")).collect();
        std::fs::write(env.desktop_path(), legacy).expect("legacy");
        assert_eq!(state(Some(&env)), DesktopState::Stale);
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn remove_deletes_what_add_wrote_and_nothing_else_and_keeps_the_app_file_by_default() {
        let (root, env) = rig("remove");
        let other = env.data_home.join("applications/other.desktop");
        write(&other, b"x").expect("other");
        let target = added(&env);
        remove(&env, false).expect("remove");
        assert_eq!(state(Some(&env)), DesktopState::Offer);
        assert!(!env.mime_path().exists() && !env.icon_path().exists() && !env.desktop_path().exists());
        assert!(other.exists(), "a foreign file stays");
        assert!(target.is_file(), "the app file stays");
        remove(&env, false).expect("removing twice is fine");
        assert!(!env.data_home.join("mime").exists(), "the generated type database goes with our type");
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn remove_can_move_the_app_file_to_the_trash() {
        let (root, env) = rig("remove-trash");
        let target = added(&env);
        remove(&env, true).expect("remove");
        assert!(!target.exists());
        assert_eq!(
            std::fs::read(env.data_home.join("Trash/files").join(INTEGRATED_NAME)).expect("trash"),
            b"appimage-bytes"
        );
        assert!(env.data_home.join("Trash/info").join(format!("{INTEGRATED_NAME}.trashinfo")).is_file());
        assert_eq!(state(Some(&env)), DesktopState::Offer);
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn removing_the_last_traces_leaves_an_empty_data_folder() {
        let (root, env) = rig("tidy");
        added(&env);
        // What update-mime-database and update-desktop-database write.
        write(&env.data_home.join("mime/globs2"), b"g").expect("globs");
        write(&env.data_home.join("applications/mimeinfo.cache"), b"c").expect("cache");
        remove(&env, false).expect("remove");
        let left: Vec<_> = std::fs::read_dir(&env.data_home).expect("dir").flatten().collect();
        assert!(left.is_empty(), "{left:?}");
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn a_no_thanks_is_remembered_until_the_user_adds() {
        let (root, env) = rig("decline");
        decline(&env).expect("decline");
        assert_eq!(state(Some(&env)), DesktopState::Declined);
        added(&env);
        assert_eq!(state(Some(&env)), DesktopState::Installed);
        assert!(!env.marker_path().exists());
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn exec_quoting_follows_the_desktop_entry_spec_and_reads_back() {
        assert_eq!(exec_line(Path::new("/a b/X.AppImage")), "\"/a b/X.AppImage\" %F");
        assert_eq!(exec_line(Path::new("/a\"b$c")), "\"/a\\\\\"b\\\\$c\" %F");
        assert_eq!(exec_line(Path::new("/100%/x")), "\"/100%%/x\" %F");
        for p in ["/a b/X.AppImage", "/a\"b$c", "/100%/x", "/back\\slash"] {
            assert_eq!(parse_exec(&exec_line(Path::new(p))), Some(PathBuf::from(p)), "{p}");
        }
        assert_eq!(parse_exec("sequence-studio %F"), None);
    }

    #[test]
    fn a_missing_bundled_file_is_399_and_writes_nothing() {
        let (root, env) = rig("missing");
        let _ = std::fs::remove_file(env.appdir.join("usr/share/mime/packages").join(MIME_FILE));
        let end = add(&env, &default_apps_dir(&env), &mut no_progress()).expect_err("fails");
        assert_eq!(end.code, 399);
        assert!(!env.desktop_path().exists());
        assert!(env.appimage.is_file());
        let _ = std::fs::remove_dir_all(root);
    }
}
