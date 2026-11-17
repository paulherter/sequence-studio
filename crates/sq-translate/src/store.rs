//! The model files on disk: where they live, the pinned download list, and the download itself.

use crate::pins::PINS;
use sq_core_time::sha256_digest::Sha256;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

/// Cancellation of a job; clones share the flag.
#[derive(Clone, Debug, Default)]
pub struct Cancel(Arc<AtomicBool>);

impl Cancel {
    /// Cancels every clone.
    pub fn cancel(&self) {
        self.0.store(true, Ordering::SeqCst);
    }

    /// Whether `cancel` was called.
    pub fn is_canceled(&self) -> bool {
        self.0.load(Ordering::SeqCst)
    }
}

/// Fetches one file.
pub trait Fetcher: Send + Sync {
    /// Writes the body of `url` to `file`, reporting the bytes so far (`size` is the expected total). Honors `cancel`.
    fn fetch(
        &self,
        url: &str,
        file: &Path,
        size: u64,
        progress: &mut dyn FnMut(u64),
        cancel: &Cancel,
    ) -> Result<(), String>;
}

/// Downloads with the system `curl` (Windows 10+ and macOS ship it; no HTTP library in the app).
pub struct CurlFetcher;

impl Fetcher for CurlFetcher {
    fn fetch(
        &self,
        url: &str,
        file: &Path,
        _size: u64,
        progress: &mut dyn FnMut(u64),
        cancel: &Cancel,
    ) -> Result<(), String> {
        let mut cmd = Command::new("curl");
        cmd.args(["-fsSL", "--retry", "2", "-o"]).arg(file).arg(url).stdout(Stdio::null()).stderr(Stdio::piped());
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            cmd.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
        }
        let mut child = cmd.spawn().map_err(|e| format!("cannot start curl: {e}"))?;
        loop {
            if cancel.is_canceled() {
                child.kill().ok();
                child.wait().ok();
                return Err("canceled".into());
            }
            match child.try_wait() {
                Ok(Some(status)) => {
                    if status.success() {
                        return Ok(());
                    }
                    let mut why = String::new();
                    if let Some(mut e) = child.stderr.take() {
                        std::io::Read::read_to_string(&mut e, &mut why).ok();
                    }
                    return Err(format!("the download failed ({}): {}", status, why.trim()));
                }
                Ok(None) => {
                    progress(fs::metadata(file).map_or(0, |m| m.len()));
                    std::thread::sleep(Duration::from_millis(120));
                }
                Err(e) => return Err(e.to_string()),
            }
        }
    }
}

/// SHA-256 of a file, read in chunks.
fn file_hex(path: &Path) -> std::io::Result<String> {
    use std::io::Read;
    let mut f = fs::File::open(path)?;
    let mut h = Sha256::new();
    let mut buf = vec![0u8; 1 << 20];
    loop {
        let n = f.read(&mut buf)?;
        if n == 0 {
            return Ok(h.finalize_hex());
        }
        h.update(&buf[..n]);
    }
}

/// One pinned file: name in the repo, size, sha256.
pub type PinnedFile = (&'static str, u64, &'static str);

/// The pinned commit and files of a direction's repo (`en-de`, `ROMANCE-en`, ...).
pub fn pin(repo: &str) -> Option<(&'static str, &'static [PinnedFile])> {
    PINS.iter().find(|(r, _, _)| *r == repo).map(|(_, commit, files)| (*commit, *files))
}

fn base_name(file: &str) -> &str {
    file.rsplit('/').next().unwrap_or(file)
}

/// The folder with the downloaded models.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TranslateStore {
    /// Root; one subfolder per direction.
    pub folder: PathBuf,
}

impl TranslateStore {
    /// A store in `folder`.
    pub fn new(folder: PathBuf) -> TranslateStore {
        TranslateStore { folder }
    }

    /// `SQ_TRANSLATE_MODELS`, else `%LOCALAPPDATA%\Sequence Studio\Translation`, else `~/Library/Application Support/Sequence Studio/Translation`
    /// (`env` reads the variables).
    pub fn default_folder(env: impl Fn(&str) -> Option<String>) -> PathBuf {
        sq_os::app_folders::data_subfolder(env, "SQ_TRANSLATE_MODELS", "Translation")
    }

    /// The folder of one direction.
    pub fn dir(&self, repo: &str) -> PathBuf {
        self.folder.join(repo)
    }

    /// Every file of the direction is there with its exact size.
    pub fn is_installed(&self, repo: &str) -> bool {
        let Some((_, files)) = pin(repo) else { return false };
        files
            .iter()
            .all(|(name, size, _)| fs::metadata(self.dir(repo).join(base_name(name))).is_ok_and(|m| m.len() == *size))
    }

    /// Bytes still to download for the direction.
    pub fn missing_bytes(&self, repo: &str) -> u64 {
        let Some((_, files)) = pin(repo) else { return 0 };
        files
            .iter()
            .filter(|(name, size, _)| {
                !fs::metadata(self.dir(repo).join(base_name(name))).is_ok_and(|m| m.len() == *size)
            })
            .map(|(_, size, _)| *size)
            .sum()
    }

    /// Downloads what is missing (each file to a `.part`, size and sha256 checked, then moved into place).
    /// `progress` reports 0...1 of the missing bytes. A canceled or failed file leaves no `.part` behind.
    pub fn install(
        &self,
        repo: &str,
        fetcher: &dyn Fetcher,
        progress: &mut dyn FnMut(f64),
        cancel: &Cancel,
    ) -> Result<(), String> {
        let (commit, files) = pin(repo).ok_or_else(|| format!("no model for {repo}"))?;
        let dir = self.dir(repo);
        fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
        let total = self.missing_bytes(repo).max(1) as f64;
        let mut done = 0u64;
        for (name, size, sha) in files {
            let target = dir.join(base_name(name));
            if fs::metadata(&target).is_ok_and(|m| m.len() == *size) {
                continue;
            }
            let part = dir.join(format!("{}.part", base_name(name)));
            fs::remove_file(&part).ok();
            let url = format!("https://huggingface.co/Xenova/opus-mt-{repo}/resolve/{commit}/{name}");
            let base = done;
            let checked = fetcher
                .fetch(&url, &part, *size, &mut |so_far| progress(((base + so_far) as f64 / total).min(0.999)), cancel)
                .and_then(|()| {
                    if fs::metadata(&part).is_ok_and(|m| m.len() == *size) {
                        Ok(())
                    } else {
                        Err(format!("{name} has the wrong size"))
                    }
                })
                .and_then(|()| match file_hex(&part) {
                    Ok(h) if h == *sha => Ok(()),
                    Ok(_) => Err(format!("{name} does not match its checksum")),
                    Err(e) => Err(e.to_string()),
                });
            if let Err(e) = checked {
                fs::remove_file(&part).ok();
                return Err(e);
            }
            fs::rename(&part, &target).map_err(|e| e.to_string())?;
            done += size;
        }
        progress(1.0);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(tag: &str) -> PathBuf {
        let p = std::env::temp_dir().join(format!("sq-translate-{tag}-{}", std::process::id()));
        fs::remove_dir_all(&p).ok();
        p
    }

    /// Writes the right number of zero bytes: the size matches, the checksum does not.
    struct Zeros;
    impl Fetcher for Zeros {
        fn fetch(&self, _u: &str, file: &Path, size: u64, p: &mut dyn FnMut(u64), _c: &Cancel) -> Result<(), String> {
            p(size / 2);
            fs::write(file, vec![0u8; size as usize]).map_err(|e| e.to_string())
        }
    }

    #[test]
    fn every_pair_has_pins_with_the_five_files() {
        for repo in [
            "en-de",
            "en-fr",
            "en-es",
            "en-it",
            "en-nl",
            "en-ROMANCE",
            "de-en",
            "fr-en",
            "es-en",
            "it-en",
            "nl-en",
            "ROMANCE-en",
        ] {
            let (commit, files) = pin(repo).unwrap();
            assert_eq!(commit.len(), 40);
            assert_eq!(files.len(), 5, "{repo}");
            assert!(files.iter().all(|f| f.2.len() == 64));
        }
    }

    #[test]
    fn folder_comes_from_the_environment_then_local_app_data() {
        let env = |k: &str| match k {
            "SQ_TRANSLATE_MODELS" => Some("/m".to_string()),
            "LOCALAPPDATA" => Some("/l".to_string()),
            _ => None,
        };
        assert_eq!(TranslateStore::default_folder(env), PathBuf::from("/m"));
        let env = |k: &str| (k == "LOCALAPPDATA").then(|| "/l".to_string());
        assert_eq!(
            TranslateStore::default_folder(env),
            PathBuf::from("/l").join("Sequence Studio").join("Translation")
        );
    }

    #[test]
    fn a_download_with_the_wrong_checksum_is_refused_and_leaves_nothing() {
        let dir = temp("sha");
        let store = TranslateStore::new(dir.clone());
        let mut last = 0.0;
        let r = store.install("en-de", &Zeros, &mut |f| last = f, &Cancel::default());
        assert!(r.is_err_and(|e| e.contains("checksum")));
        assert!(!store.is_installed("en-de"));
        let left: Vec<_> = fs::read_dir(store.dir("en-de")).unwrap().flatten().collect();
        assert!(left.is_empty(), "{left:?}");
        assert!(last <= 1.0);
        fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn present_files_with_the_right_size_are_not_fetched_again() {
        let dir = temp("have");
        let store = TranslateStore::new(dir.clone());
        let (_, files) = pin("en-de").unwrap();
        fs::create_dir_all(store.dir("en-de")).unwrap();
        for (name, size, _) in files {
            fs::write(store.dir("en-de").join(base_name(name)), vec![0u8; *size as usize]).unwrap();
        }
        assert!(store.is_installed("en-de"));
        assert_eq!(store.missing_bytes("en-de"), 0);
        assert!(store.install("en-de", &Zeros, &mut |_| {}, &Cancel::default()).is_ok());
        fs::remove_dir_all(dir).ok();
    }
}
