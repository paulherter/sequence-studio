//! Where the Whisper ONNX model lives, the pinned download (size and sha256 checked) and a `curl` downloader.

use crate::onnx_whisper_pins::{OnnxWhisperPin, legacy_pin, pin};
use crate::transcription_service::{CancelToken, TranscriptionError};
use crate::whisper_model_store::{ModelDownloader, WhisperModelStore};
use sq_core_time::sha256_digest::Sha256;
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;

/// The folder of one pinned model size.
#[derive(Clone, Debug)]
pub struct OnnxWhisperStore {
    /// The folder holding the model's files.
    pub folder: PathBuf,
    /// The model and its hashes.
    pub pin: &'static OnnxWhisperPin,
}

fn base_name(file: &str) -> &str {
    file.rsplit('/').next().unwrap_or(file)
}

impl OnnxWhisperStore {
    /// The store of `size` ("tiny", "base", "small") under `root`: `root/onnx-aligned-<size>` (the timestamped export, word
    /// timing). A model that is only there under the earlier pin (`root/onnx-<size>`, no attentions) keeps being used as it
    /// is: it works with interpolated word times, and no new download starts behind the user's back.
    pub fn new(root: &Path, size: &str) -> Option<OnnxWhisperStore> {
        let pin = pin(size)?;
        let current = OnnxWhisperStore { folder: root.join(format!("onnx-aligned-{size}")), pin };
        if !current.is_installed()
            && let Some(old) = legacy_pin(size)
        {
            let legacy = OnnxWhisperStore { folder: root.join(format!("onnx-{size}")), pin: old };
            if legacy.is_installed() {
                return Some(legacy);
            }
        }
        Some(current)
    }

    /// The size the app uses: `SQ_WHISPER_ONNX_SIZE`, else "small" (the Mac's Whisper default is small as well).
    pub fn standard(env: impl Fn(&str) -> Option<String>) -> OnnxWhisperStore {
        let root = WhisperModelStore::default_folder(&env);
        let size = env("SQ_WHISPER_ONNX_SIZE").filter(|s| pin(s).is_some()).unwrap_or_else(|| "small".into());
        OnnxWhisperStore::new(&root, &size)
            .unwrap_or_else(|| OnnxWhisperStore { folder: root, pin: &crate::onnx_whisper_pins::PINS[2] })
    }

    /// Path of a pinned file inside the folder.
    pub fn file(&self, name: &str) -> PathBuf {
        self.folder.join(base_name(name))
    }

    fn present(&self, name: &str, size: u64) -> bool {
        fs::metadata(self.file(name)).is_ok_and(|m| m.len() == size)
    }

    /// Bytes of the files that are missing or have the wrong size.
    pub fn missing_bytes(&self) -> u64 {
        self.pin.files.iter().filter(|(n, s, _)| !self.present(n, *s)).map(|(_, s, _)| *s).sum()
    }

    /// Every file is there with its exact size.
    pub fn is_installed(&self) -> bool {
        self.pin.files.iter().all(|(n, s, _)| self.present(n, *s))
    }

    /// Downloads what is missing: each file to a `.part`, size and sha256 checked, then moved into place. `progress` is
    /// 0...1 of the missing bytes; a failed or canceled file leaves no `.part`.
    pub fn install(
        &self,
        downloader: &dyn ModelDownloader,
        progress: &mut dyn FnMut(f64),
        cancel: &CancelToken,
    ) -> Result<(), TranscriptionError> {
        let fail = |why: String| TranscriptionError::ModelDownloadFailed(why);
        fs::create_dir_all(&self.folder).map_err(|e| fail(e.to_string()))?;
        let total: u64 = self.pin.files.iter().filter(|(n, s, _)| !self.present(n, *s)).map(|f| f.1).sum();
        let total = total.max(1) as f64;
        let mut done = 0u64;
        for (name, size, sha) in self.pin.files {
            if self.present(name, *size) {
                continue;
            }
            cancel.check()?;
            let part = self.folder.join(format!("{}.part", base_name(name)));
            fs::remove_file(&part).ok();
            let url = format!("https://huggingface.co/{}/resolve/{}/{name}", self.pin.repo, self.pin.commit);
            let base = done;
            let got = downloader.download(
                &url,
                &part,
                &mut |so_far, _| progress(((base as f64 + so_far as f64) / total).min(0.999)),
                cancel,
            );
            let checked = got.and_then(|()| {
                if fs::metadata(&part).is_ok_and(|m| m.len() == *size) {
                    Ok(())
                } else {
                    Err(fail(format!("{name} has the wrong size")))
                }
            });
            let checked = checked.and_then(|()| match file_hex(&part) {
                Ok(h) if h == *sha => Ok(()),
                Ok(_) => Err(fail(format!("{name} does not match its checksum"))),
                Err(e) => Err(fail(e.to_string())),
            });
            if let Err(e) = checked {
                fs::remove_file(&part).ok();
                return Err(e);
            }
            fs::rename(&part, self.file(name)).map_err(|e| fail(e.to_string()))?;
            done += size;
        }
        progress(1.0);
        Ok(())
    }
}

/// SHA-256 of a file, read in chunks.
fn file_hex(path: &Path) -> std::io::Result<String> {
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

/// Downloads with the system `curl` (Windows 10+ and macOS ship it; no HTTP library in the app), progress by file size.
pub struct CurlDownloader;

impl ModelDownloader for CurlDownloader {
    fn download(
        &self,
        url: &str,
        file: &Path,
        progress: &mut dyn FnMut(i64, Option<i64>),
        cancel: &CancelToken,
    ) -> Result<(), TranscriptionError> {
        let fail = |why: String| TranscriptionError::ModelDownloadFailed(why);
        let mut cmd = Command::new("curl");
        cmd.args(["-fsSL", "--retry", "2", "-o"]).arg(file).arg(url).stdout(Stdio::null()).stderr(Stdio::piped());
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            cmd.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
        }
        let mut child = cmd.spawn().map_err(|e| fail(format!("cannot start curl: {e}")))?;
        loop {
            if cancel.is_cancelled() {
                child.kill().ok();
                child.wait().ok();
                return Err(TranscriptionError::Cancelled);
            }
            match child.try_wait() {
                Ok(Some(status)) if status.success() => return Ok(()),
                Ok(Some(status)) => {
                    let mut why = String::new();
                    if let Some(mut e) = child.stderr.take() {
                        e.read_to_string(&mut why).ok();
                    }
                    return Err(fail(format!("the download failed ({status}): {}", why.trim())));
                }
                Ok(None) => {
                    progress(fs::metadata(file).map_or(0, |m| i64::try_from(m.len()).unwrap_or(i64::MAX)), None);
                    std::thread::sleep(Duration::from_millis(120));
                }
                Err(e) => return Err(fail(e.to_string())),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Zeros;
    impl ModelDownloader for Zeros {
        fn download(
            &self,
            _url: &str,
            file: &Path,
            progress: &mut dyn FnMut(i64, Option<i64>),
            _cancel: &CancelToken,
        ) -> Result<(), TranscriptionError> {
            // The right size for config.json, wrong content.
            progress(1, None);
            fs::write(file, vec![0u8; 2243]).map_err(|e| TranscriptionError::ModelDownloadFailed(e.to_string()))
        }
    }

    fn temp(tag: &str) -> PathBuf {
        let p = std::env::temp_dir().join(format!("sq-onnx-whisper-{tag}-{}", std::process::id()));
        fs::remove_dir_all(&p).ok();
        p
    }

    #[test]
    fn every_size_pins_four_files_with_full_hashes() {
        for p in crate::onnx_whisper_pins::PINS {
            assert_eq!(p.commit.len(), 40);
            assert_eq!(p.files.len(), 5, "{}", p.size);
            assert!(p.aligned && p.files.iter().any(|f| f.0 == "generation_config.json"));
            assert!(p.files.iter().all(|f| f.2.len() == 64 && f.1 > 0));
        }
        for p in crate::onnx_whisper_pins::LEGACY_PINS {
            assert_eq!((p.commit.len(), p.files.len(), p.aligned), (40, 4, false), "{}", p.size);
        }
        assert!(OnnxWhisperStore::new(Path::new("/m"), "huge").is_none());
    }

    fn place_all(store: &OnnxWhisperStore) {
        fs::create_dir_all(&store.folder).unwrap();
        for (n, s, _) in store.pin.files {
            fs::File::create(store.file(n)).unwrap().set_len(*s).unwrap();
        }
    }

    #[test]
    fn a_model_installed_under_the_earlier_pin_keeps_working_without_a_new_download() {
        let dir = temp("legacy");
        let old = OnnxWhisperStore { folder: dir.join("onnx-tiny"), pin: legacy_pin("tiny").unwrap() };
        place_all(&old);
        let s = OnnxWhisperStore::new(&dir, "tiny").unwrap();
        assert!(s.is_installed() && !s.pin.aligned);
        assert_eq!(s.folder, dir.join("onnx-tiny"));
        // Once the timestamped model is there it wins.
        let new = OnnxWhisperStore { folder: dir.join("onnx-aligned-tiny"), pin: pin("tiny").unwrap() };
        place_all(&new);
        let s = OnnxWhisperStore::new(&dir, "tiny").unwrap();
        assert!(s.pin.aligned && s.is_installed());
        // Nothing installed: the timestamped model is the one to fetch.
        let s = OnnxWhisperStore::new(&dir, "base").unwrap();
        assert!(s.pin.aligned && !s.is_installed());
        fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn the_size_comes_from_the_environment_and_defaults_to_small() {
        let env = |k: &str| match k {
            "SQ_WHISPER_MODELS" => Some("/m".to_string()),
            "SQ_WHISPER_ONNX_SIZE" => Some("base".to_string()),
            _ => None,
        };
        let s = OnnxWhisperStore::standard(env);
        assert_eq!((s.pin.size, s.folder), ("base", PathBuf::from("/m").join("onnx-aligned-base")));
        let s = OnnxWhisperStore::standard(|k| (k == "SQ_WHISPER_MODELS").then(|| "/m".to_string()));
        assert_eq!(s.pin.size, "small");
    }

    #[test]
    fn a_download_with_the_wrong_checksum_is_refused_and_leaves_nothing() {
        let dir = temp("sha");
        // "tiny" lists the encoder first: its wrong size is refused before any checksum. Use a pin whose first file the
        // fake can match: pre-place the big files with the right size so only config.json is fetched.
        let store = OnnxWhisperStore::new(&dir, "tiny").unwrap();
        fs::create_dir_all(&store.folder).unwrap();
        for (n, s, _) in store.pin.files.iter().filter(|f| f.0 != "config.json") {
            let f = fs::File::create(store.file(n)).unwrap();
            f.set_len(*s).unwrap();
        }
        assert!(!store.is_installed());
        let r = store.install(&Zeros, &mut |_| {}, &CancelToken::new());
        assert!(matches!(r, Err(TranscriptionError::ModelDownloadFailed(m)) if m.contains("checksum")));
        assert!(!store.is_installed());
        assert!(!store.folder.join("config.json.part").exists());
        fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn a_canceled_install_stops_before_downloading() {
        let dir = temp("cancel");
        let store = OnnxWhisperStore::new(&dir, "tiny").unwrap();
        let c = CancelToken::new();
        c.cancel();
        assert_eq!(store.install(&Zeros, &mut |_| {}, &c), Err(TranscriptionError::Cancelled));
        fs::remove_dir_all(dir).ok();
    }
}
