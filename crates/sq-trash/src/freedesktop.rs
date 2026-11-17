//! freedesktop.org Trash specification 1.0 (also what KDE, GNOME and Xfce read).
//!
//! The home trash (`$XDG_DATA_HOME/Trash`) takes files on the home volume. A file on another volume goes to
//! `<mount top>/.Trash-<uid>` (never to the shared `.Trash` folder: it needs the sticky bit set by an admin).

use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::{DirBuilderExt, MetadataExt};
use std::path::{Path, PathBuf};

pub fn trash(path: &Path) -> io::Result<()> {
    let abs = std::path::absolute(path)?;
    let meta = fs::symlink_metadata(&abs)?;
    let home = data_home().join("Trash");
    fs::DirBuilder::new().recursive(true).mode(0o700).create(&home)?;
    if fs::metadata(&home)?.dev() == meta.dev() {
        return trash_into(&abs, &home, None);
    }
    let top = mount_top(&abs, meta.dev());
    // SAFETY: getuid has no preconditions.
    let uid = unsafe { libc::getuid() };
    let root = top.join(format!(".Trash-{uid}"));
    fs::DirBuilder::new().recursive(true).mode(0o700).create(&root)?;
    trash_into(&abs, &root, Some(&top))
}

fn data_home() -> PathBuf {
    if let Some(d) = std::env::var_os("XDG_DATA_HOME").map(PathBuf::from).filter(|p| p.is_absolute()) {
        return d;
    }
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
    home.join(".local/share")
}

/// The highest parent that is still on device `dev`.
fn mount_top(path: &Path, dev: u64) -> PathBuf {
    let mut top = path.parent().unwrap_or(Path::new("/")).to_path_buf();
    while let Some(up) = top.parent() {
        if fs::metadata(up).map(|m| m.dev()).ok() != Some(dev) {
            break;
        }
        top = up.to_path_buf();
    }
    top
}

/// Moves `path` into `root/files` and writes `root/info/<name>.trashinfo`. `relative_to` is the mount top for a
/// volume trash (the info `Path` is then relative to it); `None` writes the absolute path.
pub fn trash_into(path: &Path, root: &Path, relative_to: Option<&Path>) -> io::Result<()> {
    let files = root.join("files");
    let info = root.join("info");
    for d in [&files, &info] {
        fs::DirBuilder::new().recursive(true).mode(0o700).create(d)?;
    }
    let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let (stem, ext) = match name.rfind('.') {
        Some(i) if i > 0 => (name[..i].to_string(), name[i..].to_string()),
        _ => (name.clone(), String::new()),
    };
    let shown = match relative_to {
        Some(top) => path.strip_prefix(top).unwrap_or(path),
        None => path,
    };
    let body = format!(
        "[Trash Info]\nPath={}\nDeletionDate={}\n",
        percent_encode(&shown.to_string_lossy()),
        chrono::Local::now().format("%Y-%m-%dT%H:%M:%S")
    );
    // The info file is created exclusively: it claims the name, so two trashers never share one.
    for n in 0..1000 {
        let candidate = if n == 0 { name.clone() } else { format!("{stem} {}{ext}", n + 1) };
        let info_path = info.join(format!("{candidate}.trashinfo"));
        let mut f = match OpenOptions::new().write(true).create_new(true).open(&info_path) {
            Ok(f) => f,
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(e),
        };
        let target = files.join(&candidate);
        if target.exists() {
            let _ = fs::remove_file(&info_path);
            continue;
        }
        let done = f.write_all(body.as_bytes()).and_then(|()| fs::rename(path, &target));
        if done.is_err() {
            let _ = fs::remove_file(&info_path);
        }
        return done;
    }
    Err(io::Error::other("no free name in the Trash"))
}

/// RFC 3986 percent-encoding of everything except unreserved characters and `/`.
fn percent_encode(s: &str) -> String {
    let mut out = String::new();
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'~' | b'/') {
            out.push(char::from(b));
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("sq-trash-fd-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        let _ = fs::create_dir_all(&d);
        d
    }

    #[test]
    fn moves_the_file_and_writes_the_info_file() {
        let d = temp("a");
        let f = d.join("my clip.mov");
        assert!(fs::write(&f, b"data").is_ok());
        let root = d.join("Trash");
        assert!(trash_into(&f, &root, None).is_ok());
        assert!(!f.exists());
        assert_eq!(fs::read(root.join("files/my clip.mov")).ok().as_deref(), Some(&b"data"[..]));
        let info = fs::read_to_string(root.join("info/my clip.mov.trashinfo")).unwrap_or_default();
        assert!(info.starts_with("[Trash Info]\nPath="));
        assert!(info.contains("my%20clip.mov\nDeletionDate="));
        let _ = fs::remove_dir_all(&d);
    }

    #[test]
    fn a_name_clash_gets_a_new_name_in_files_and_info() {
        let d = temp("b");
        let root = d.join("Trash");
        for body in [b"1", b"2"] {
            let f = d.join("a.txt");
            assert!(fs::write(&f, body).is_ok());
            assert!(trash_into(&f, &root, None).is_ok());
        }
        assert_eq!(fs::read(root.join("files/a.txt")).ok().as_deref(), Some(&b"1"[..]));
        assert_eq!(fs::read(root.join("files/a 2.txt")).ok().as_deref(), Some(&b"2"[..]));
        assert!(root.join("info/a 2.txt.trashinfo").exists());
        let _ = fs::remove_dir_all(&d);
    }

    #[test]
    fn a_volume_trash_writes_a_path_relative_to_the_mount_top() {
        let d = temp("c");
        let f = d.join("sub/x.bin");
        assert!(fs::create_dir_all(d.join("sub")).is_ok() && fs::write(&f, b"x").is_ok());
        let root = d.join(".Trash-1000");
        assert!(trash_into(&f, &root, Some(&d)).is_ok());
        let info = fs::read_to_string(root.join("info/x.bin.trashinfo")).unwrap_or_default();
        assert!(info.contains("Path=sub/x.bin\n"));
        let _ = fs::remove_dir_all(&d);
    }

    #[test]
    fn percent_encoding_keeps_unreserved_and_slash() {
        assert_eq!(percent_encode("/a b/ü.mov"), "/a%20b/%C3%BC.mov");
    }
}
