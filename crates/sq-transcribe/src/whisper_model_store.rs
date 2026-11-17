// Swift: WhisperModelStore.swift (`URLSessionDownloader` needs an HTTP client and is not ported, see NOTES.md; the async
// downloader is a blocking trait)
//! Where the Whisper model lives and the download into that place.

use crate::transcription_service::{CancelToken, TranscriptionError};
use std::fs;
use std::path::{Path, PathBuf};

/// A Whisper model file (ggml format, whisper.cpp, MIT) and where it comes from.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WhisperModel {
    /// Shown name.
    pub name: String,
    /// File name in the store folder.
    pub file_name: String,
    /// Download address.
    pub url: String,
    /// Exact size of the finished file: a shorter or longer download is refused.
    pub byte_count: i64,
}

impl WhisperModel {
    /// Multilingual "small", 5-bit quantized (about 181 MB): good German and English at a speed that suits a laptop CPU.
    pub fn small() -> WhisperModel {
        WhisperModel {
            name: "Whisper small".into(),
            file_name: "ggml-small-q5_1.bin".into(),
            url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small-q5_1.bin".into(),
            byte_count: 190_085_487,
        }
    }
}

/// Fetches a file.
pub trait ModelDownloader: Send + Sync {
    /// Writes the body of `url` to `file` and reports (bytes so far, total when known). Honors `cancel`.
    fn download(
        &self,
        url: &str,
        file: &Path,
        progress: &mut dyn FnMut(i64, Option<i64>),
        cancel: &CancelToken,
    ) -> Result<(), TranscriptionError>;
}

/// Where the model lives and the download into that place (the Mac gets its models from the system; here they are ours).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WhisperModelStore {
    /// The model folder.
    pub folder: PathBuf,
    /// The model it holds.
    pub model: WhisperModel,
}

impl WhisperModelStore {
    /// A store for `model` in `folder`.
    pub fn new(folder: PathBuf, model: WhisperModel) -> WhisperModelStore {
        WhisperModelStore { folder, model }
    }

    /// The small model in the default folder.
    pub fn standard(env: impl Fn(&str) -> Option<String>) -> WhisperModelStore {
        Self::new(Self::default_folder(env), WhisperModel::small())
    }

    /// `SQ_WHISPER_MODELS`, else `%LOCALAPPDATA%\Sequence Studio\Whisper`, else `~/Library/Application Support/Sequence Studio/Whisper`
    /// (`HOME` read through `env`).
    pub fn default_folder(env: impl Fn(&str) -> Option<String>) -> PathBuf {
        sq_os::app_folders::data_subfolder(env, "SQ_WHISPER_MODELS", "Whisper")
    }

    /// The finished model file.
    pub fn model_url(&self) -> PathBuf {
        self.folder.join(&self.model.file_name)
    }

    /// The file a download writes first.
    pub fn part_url(&self) -> PathBuf {
        self.folder.join(format!("{}.part", self.model.file_name))
    }

    /// The model file exists with exactly the expected size.
    pub fn is_installed(&self) -> bool {
        fs::metadata(self.model_url()).is_ok_and(|m| i64::try_from(m.len()).ok() == Some(self.model.byte_count))
    }

    /// Downloads the model into the folder (`.part` file first, moved into place once the size is right).
    /// `progress` reports 0...1. A canceled or failed download leaves nothing behind.
    // Same as Swift (no resume, no checksum there either): only the exact size is checked; upgrade when users report broken files.
    pub fn install(
        &self,
        downloader: &dyn ModelDownloader,
        progress: &mut dyn FnMut(f64),
        cancel: &CancelToken,
    ) -> Result<(), TranscriptionError> {
        let failed = |e: std::io::Error| TranscriptionError::ModelDownloadFailed(e.to_string());
        fs::create_dir_all(&self.folder).map_err(failed)?;
        let part = self.part_url();
        fs::remove_file(&part).ok();
        let expected = self.model.byte_count;
        let result = (|| {
            downloader.download(
                &self.model.url,
                &part,
                &mut |done, total| progress((done as f64 / total.unwrap_or(expected).max(1) as f64).clamp(0.0, 1.0)),
                cancel,
            )?;
            let size = fs::metadata(&part).ok().and_then(|m| i64::try_from(m.len()).ok());
            if size != Some(expected) {
                return Err(TranscriptionError::ModelDownloadFailed("the file has the wrong size".into()));
            }
            fs::remove_file(self.model_url()).ok();
            fs::rename(&part, self.model_url()).map_err(failed)?;
            progress(1.0);
            Ok(())
        })();
        if result.is_err() {
            fs::remove_file(&part).ok();
        }
        result
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    /// A fresh folder path (not created), removed on drop.
    pub struct TempFolder(pub PathBuf);

    impl TempFolder {
        pub fn new() -> TempFolder {
            static NEXT: AtomicU64 = AtomicU64::new(0);
            let n = NEXT.fetch_add(1, Ordering::Relaxed);
            TempFolder(std::env::temp_dir().join(format!("sq-whisper-{}-{n}", std::process::id())))
        }
    }

    impl Drop for TempFolder {
        fn drop(&mut self) {
            fs::remove_dir_all(&self.0).ok();
        }
    }

    pub fn model(bytes: i64) -> WhisperModel {
        WhisperModel {
            name: "test".into(),
            file_name: "ggml-test.bin".into(),
            url: "https://example.com/ggml-test.bin".into(),
            byte_count: bytes,
        }
    }

    /// Writes half the bytes, optionally fails, then writes all.
    pub struct Fake {
        pub bytes: usize,
        pub fail: bool,
    }

    impl ModelDownloader for Fake {
        fn download(
            &self,
            _url: &str,
            file: &Path,
            progress: &mut dyn FnMut(i64, Option<i64>),
            _cancel: &CancelToken,
        ) -> Result<(), TranscriptionError> {
            let io = |e: std::io::Error| TranscriptionError::ModelDownloadFailed(e.to_string());
            fs::write(file, vec![0u8; self.bytes / 2]).map_err(io)?;
            progress((self.bytes / 2) as i64, Some(self.bytes as i64));
            if self.fail {
                return Err(TranscriptionError::ModelDownloadFailed("not connected".into()));
            }
            fs::write(file, vec![0u8; self.bytes]).map_err(io)?;
            progress(self.bytes as i64, Some(self.bytes as i64));
            Ok(())
        }
    }

    #[test]
    fn folder_comes_from_the_environment_then_local_app_data() {
        let env = |pairs: &'static [(&'static str, &'static str)]| {
            move |k: &str| pairs.iter().find(|(key, _)| *key == k).map(|(_, v)| v.to_string())
        };
        assert_eq!(WhisperModelStore::default_folder(env(&[("SQ_WHISPER_MODELS", "/m")])), PathBuf::from("/m"));
        let win = WhisperModelStore::default_folder(env(&[("LOCALAPPDATA", "/L")]));
        assert!(win.ends_with("Sequence Studio/Whisper") && win.starts_with("/L"));
        let mac = WhisperModelStore::default_folder(env(&[("HOME", "/h"), ("SQ_WHISPER_MODELS", "")]));
        if cfg!(target_os = "macos") {
            assert!(mac.starts_with("/h/Library/Application Support"));
        } else {
            assert_eq!(mac, PathBuf::from("/h/.local/share/Sequence Studio/Whisper"), "Linux: the XDG data folder");
        }
    }

    #[test]
    fn install_downloads_to_a_part_file_checks_the_size_and_moves_it_into_place() {
        let dir = TempFolder::new();
        let store = WhisperModelStore::new(dir.0.clone(), model(1000));
        assert!(!store.is_installed());
        let mut seen: Vec<f64> = Vec::new();
        store.install(&Fake { bytes: 1000, fail: false }, &mut |p| seen.push(p), &CancelToken::new()).unwrap();
        assert!(store.is_installed());
        assert!(!store.part_url().exists());
        assert!(
            seen.last() == Some(&1.0)
                && seen.windows(2).all(|w| w[0] <= w[1])
                && seen.iter().all(|v| (0.0..=1.0).contains(v))
        );
    }

    #[test]
    fn a_failed_or_short_download_leaves_no_model_and_no_part_file() {
        let dir = TempFolder::new();
        let store = WhisperModelStore::new(dir.0.clone(), model(1000));
        assert!(store.install(&Fake { bytes: 1000, fail: true }, &mut |_| {}, &CancelToken::new()).is_err());
        assert!(!store.is_installed() && !store.part_url().exists());
        let e = store.install(&Fake { bytes: 900, fail: false }, &mut |_| {}, &CancelToken::new());
        assert!(matches!(e, Err(TranscriptionError::ModelDownloadFailed(_))));
        assert!(!store.is_installed() && !store.part_url().exists());
    }

    #[test]
    fn a_wrong_sized_file_is_not_installed() {
        let dir = TempFolder::new();
        let store = WhisperModelStore::new(dir.0.clone(), model(1000));
        fs::create_dir_all(&dir.0).unwrap();
        fs::write(store.model_url(), [0u8; 10]).unwrap();
        assert!(!store.is_installed());
    }
}
