//! Port of `NearProjectRelink.swift` (the path matching). Media of a project that was copied to another machine or
//! folder (a Mac project opened on Windows, a moved project folder): the stored paths point at the old place. On open,
//! files that sit next to the project file are linked again:
//! 1. the stored path's trailing part below the project's folder, longest first, POSIX or Windows stored paths
//!    (`trailing_match`);
//! 2. else the same file name below the folder (`DEPTH` levels) with the recorded size (`plan`, in sq-core-project:
//!    `NearProjectRelinkPlanExt`, because it needs `RelinkPlanner` and `RelinkScanner`).
//!
//! A recorded size of 0 (unknown) accepts the name. File system only: call off the UI thread.
// Name + size only, no probed duration (a probe per candidate is slow), as in Swift.

use std::path::{Path, PathBuf};

/// `enum NearProjectRelink`.
pub struct NearProjectRelink;

impl NearProjectRelink {
    /// Folder levels searched by name below the project's folder.
    pub const DEPTH: usize = 5;

    /// The longest trailing part of `stored_path` (up to `max_trailing` components, the file name at least) that is a
    /// file below `folder` with the recorded `size` (0 = unknown, any size).
    pub fn trailing_match(stored_path: &str, folder: &Path, size: i64, max_trailing: usize) -> Option<String> {
        let parts: Vec<&str> = stored_path.split(['/', '\\']).filter(|p| !p.is_empty() && !p.ends_with(':')).collect();
        if parts.is_empty() {
            return None;
        }
        for n in (1..=max_trailing.min(parts.len())).rev() {
            let url: PathBuf = parts[parts.len() - n..].iter().fold(folder.to_path_buf(), |p, c| p.join(c));
            let Ok(meta) = std::fs::metadata(&url) else { continue };
            if meta.is_dir() {
                continue;
            }
            if size > 0 && i64::try_from(meta.len()).ok() != Some(size) {
                continue;
            }
            return Some(url.to_string_lossy().into_owned());
        }
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    struct TempDir(PathBuf);

    impl TempDir {
        fn new() -> TempDir {
            static N: AtomicUsize = AtomicUsize::new(0);
            let dir = std::env::temp_dir().join(format!(
                "sq-near-{}-{}",
                std::process::id(),
                N.fetch_add(1, Ordering::Relaxed)
            ));
            std::fs::create_dir_all(&dir).unwrap();
            TempDir(dir)
        }

        fn file(&self, rel: &str, size: usize) -> String {
            let p = rel.split('/').fold(self.0.clone(), |p, c| p.join(c)); // one separator style on Windows too
            std::fs::create_dir_all(p.parent().unwrap()).unwrap();
            std::fs::write(&p, vec![0u8; size]).unwrap();
            p.to_string_lossy().into_owned()
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn stored_mac_paths_resolve_by_their_trailing_folders() {
        let dir = TempDir::new();
        let imported = dir.file("Files/Imported/C2171.MP4", 10);
        dir.file("Media/C2171.MP4", 10); // same name and size elsewhere: the trailing folders decide
        let media = dir.file("Media/C2174.MP4", 20);
        let m = |p, size| NearProjectRelink::trailing_match(p, &dir.0, size, 8);
        assert_eq!(m("/Users/me/Documents/Projects/Client Film/Files/Imported/C2171.MP4", 10), Some(imported));
        assert_eq!(m("/Users/me/Documents/Projects/Client/Media/C2174.MP4", 20), Some(media));
    }

    #[test]
    fn windows_stored_paths_use_the_same_trailing_parts() {
        let dir = TempDir::new();
        let clip = dir.file("Card 1/clip.mov", 30);
        assert_eq!(NearProjectRelink::trailing_match(r"D:\Footage\Card 1\clip.mov", &dir.0, 30, 8), Some(clip));
        assert_eq!(NearProjectRelink::trailing_match(r"D:\Footage\Card 2\clip.mov", &dir.0, 30, 8), None);
    }

    #[test]
    fn trailing_match_prefers_the_longest_existing_suffix_and_checks_the_size() {
        let dir = TempDir::new();
        let long = dir.file("Proj/Files/x.mp4", 5);
        dir.file("x.mp4", 5);
        let m = |size| NearProjectRelink::trailing_match("/Users/a/Proj/Files/x.mp4", &dir.0, size, 8);
        assert_eq!(m(5), Some(long.clone()));
        assert_eq!(m(6), None);
        assert_eq!(m(0), Some(long));
    }

    #[test]
    fn nothing_near_the_project_gives_no_match() {
        let dir = TempDir::new();
        assert_eq!(NearProjectRelink::trailing_match("/Users/a/gone.mov", &dir.0, 1, 8), None);
        assert_eq!(NearProjectRelink::trailing_match("", &dir.0, 1, 8), None);
    }
}
