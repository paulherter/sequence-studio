//! The in-app updater: one state machine from "Check for Updates" to the installed file, and the checks a downloaded
//! installer must pass (SHA-256 against the feed, ed25519 signature over that hash). The shell only draws the states
//! and runs the effects; the platform layer only downloads and applies.

use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use ed25519_dalek::{Signature, VerifyingKey};
use sha2::{Digest, Sha256};

use super::update::{UpdateInstall, UpdateOutcome, UpdateRelease};

/// The public key the update signatures are checked against, set by the release key ceremony. While it is all zeros no
/// signature can be trusted, so [`UpdateTrust::key`] is `None` and every update falls back to the download link.
pub const UPDATE_PUBLIC_KEY: [u8; 32] = [
    0x23, 0x5d, 0xaf, 0x0b, 0x96, 0x9d, 0x42, 0x09, 0xa8, 0x58, 0xf1, 0xa7, 0xbc, 0xc7, 0x7a, 0xda, 0x8c, 0x82, 0xcc,
    0x7c, 0x32, 0xc4, 0x30, 0xad, 0x51, 0xfa, 0x87, 0xd7, 0xdf, 0xe9, 0x60, 0xf7,
];

/// The trust anchor of the updater.
pub enum UpdateTrust {}

impl UpdateTrust {
    /// The built-in key, or `None` while none is set.
    pub fn key() -> Option<[u8; 32]> {
        (UPDATE_PUBLIC_KEY != [0; 32]).then_some(UPDATE_PUBLIC_KEY)
    }

    /// The SHA-256 of a file, streamed.
    pub fn sha256_file(path: &Path) -> std::io::Result<[u8; 32]> {
        let mut f = std::fs::File::open(path)?;
        let mut hasher = Sha256::new();
        let mut buf = vec![0u8; 1 << 20];
        loop {
            let n = f.read(&mut buf)?;
            if n == 0 {
                break;
            }
            hasher.update(&buf[..n]);
        }
        Ok(hasher.finalize().into())
    }

    /// Lowercase hex of bytes.
    pub fn hex(bytes: &[u8]) -> String {
        bytes.iter().map(|b| format!("{b:02x}")).collect()
    }

    fn unhex(text: &str) -> Option<Vec<u8>> {
        let t = text.trim();
        if !t.len().is_multiple_of(2) || !t.is_ascii() {
            return None;
        }
        (0..t.len()).step_by(2).map(|i| u8::from_str_radix(&t[i..i + 2], 16).ok()).collect()
    }

    /// The file's hash must equal the feed's.
    pub fn check_digest(actual: &[u8; 32], published_hex: &str) -> Result<(), UpdateFailure> {
        if Self::hex(actual) == published_hex.trim().to_lowercase() { Ok(()) } else { Err(UpdateFailure::BadDigest) }
    }

    /// The signature (64 raw bytes or their hex text) must be valid for the file's hash under `key`.
    pub fn check_signature(sha256: &[u8; 32], signature: &[u8], key: &[u8; 32]) -> Result<(), UpdateFailure> {
        let raw = if signature.len() == 64 {
            signature.to_vec()
        } else {
            std::str::from_utf8(signature).ok().and_then(Self::unhex).ok_or(UpdateFailure::BadSignature)?
        };
        let sig = Signature::from_slice(&raw).map_err(|_| UpdateFailure::BadSignature)?;
        let key = VerifyingKey::from_bytes(key).map_err(|_| UpdateFailure::BadSignature)?;
        key.verify_strict(sha256, &sig).map_err(|_| UpdateFailure::BadSignature)
    }

    /// Both checks on a downloaded file.
    pub fn verify_file(
        file: &Path,
        install: &UpdateInstall,
        signature: Option<&[u8]>,
        key: &[u8; 32],
    ) -> Result<(), UpdateFailure> {
        let sha = Self::sha256_file(file).map_err(|e| UpdateFailure::Unreadable(e.to_string()))?;
        Self::check_digest(&sha, &install.sha256)?;
        Self::check_signature(&sha, signature.ok_or(UpdateFailure::SignatureMissing)?, key)
    }

    /// Where a release's installer is staged: a folder per version, then the file name from the feed, never a path. A
    /// new download of another version never touches the file of an earlier one.
    pub fn staged_path(cache: &Path, version: &str, install: &UpdateInstall) -> Option<PathBuf> {
        let name = Path::new(&install.name).file_name()?.to_str()?;
        let folder: String = version
            .chars()
            .map(|c| if c.is_ascii_alphanumeric() || matches!(c, '.' | '-') { c } else { '_' })
            .collect();
        let folder = folder.trim_start_matches('.');
        (!name.is_empty() && name != ".." && !folder.is_empty()).then(|| cache.join(folder).join(name))
    }
}

/// A verified update waiting to be applied (now or on quit), with what is needed to check the file once more right
/// before it is used.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PendingUpdate {
    pub file: PathBuf,
    pub version: String,
    pub install: UpdateInstall,
    /// The signature file's bytes.
    pub signature: Vec<u8>,
}

impl PendingUpdate {
    /// The hash and signature checks again, against the built-in key. Nothing is applied without this passing.
    pub fn verify(&self) -> Result<(), UpdateFailure> {
        self.verify_with(&UpdateTrust::key().ok_or(UpdateFailure::BadSignature)?)
    }

    /// [`Self::verify`] under a given key.
    pub fn verify_with(&self, key: &[u8; 32]) -> Result<(), UpdateFailure> {
        UpdateTrust::verify_file(&self.file, &self.install, Some(&self.signature), key)
    }
}

/// A download running on a platform thread: the bytes so far, the cancel request and the end result. The shell reads it
/// on every tick; the platform's downloader writes it.
#[derive(Default)]
pub struct DownloadProgress {
    done: AtomicU64,
    total: AtomicU64,
    canceled: AtomicBool,
    result: Mutex<Option<Result<(), String>>>,
}

impl DownloadProgress {
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }

    /// The downloader reports the bytes so far (`total` 0 = unknown).
    pub fn report(&self, done: u64, total: u64) {
        self.done.store(done, Ordering::Relaxed);
        self.total.store(total, Ordering::Relaxed);
    }

    /// The bytes so far and the total (0 = unknown).
    pub fn snapshot(&self) -> (u64, u64) {
        (self.done.load(Ordering::Relaxed), self.total.load(Ordering::Relaxed))
    }

    /// The user cancels; the downloader stops at its next look.
    pub fn cancel(&self) {
        self.canceled.store(true, Ordering::SeqCst);
    }

    pub fn is_canceled(&self) -> bool {
        self.canceled.load(Ordering::SeqCst)
    }

    /// The downloader ends, with its error text on failure.
    pub fn finish(&self, result: Result<(), String>) {
        if let Ok(mut slot) = self.result.lock() {
            *slot = Some(result);
        }
    }

    /// The end result once, `None` while it runs.
    pub fn take_result(&self) -> Option<Result<(), String>> {
        self.result.lock().ok()?.take()
    }
}

/// "12.4 of 98.0 MB", or just the amount when the total is unknown.
pub fn progress_line(done: u64, total: u64) -> String {
    let mb = |b: u64| format!("{:.1}", b as f64 / 1_000_000.0);
    if total == 0 { format!("{} MB", mb(done)) } else { format!("{} of {} MB", mb(done.min(total)), mb(total)) }
}

/// Why an update stopped.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum UpdateFailure {
    /// The update information could not be read.
    CheckFailed,
    /// The download failed.
    Download(String),
    /// The file does not match the hash the feed published.
    BadDigest,
    /// The signature file is missing or could not be downloaded.
    SignatureMissing,
    /// The signature does not match the file.
    BadSignature,
    /// The downloaded file could not be read.
    Unreadable(String),
    /// The platform could not put the new version in place.
    Apply(String),
}

impl UpdateFailure {
    /// The line the dialog shows.
    pub fn message(&self) -> String {
        match self {
            Self::CheckFailed => {
                "The update information could not be read. Check your connection and try again later.".into()
            }
            Self::Download(why) if why.is_empty() => "The download failed. Check your connection and try again.".into(),
            Self::Download(why) => format!("The download failed: {why}"),
            Self::BadDigest => "The downloaded file does not match what was published, so it was not installed.".into(),
            Self::SignatureMissing => "The update has no signature, so it was not installed.".into(),
            Self::BadSignature => "The update's signature is not valid, so it was not installed.".into(),
            Self::Unreadable(why) => format!("The downloaded file could not be read: {why}"),
            Self::Apply(why) => format!("The update could not be installed: {why}"),
        }
    }
}

/// Where the updater is.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub enum UpdateFlow {
    #[default]
    Idle,
    Checking,
    /// A newer version is published.
    Available(UpdateRelease),
    Downloading {
        release: UpdateRelease,
        done: u64,
        total: u64,
    },
    Verifying {
        release: UpdateRelease,
        file: PathBuf,
    },
    /// Downloaded and verified: "Restart to Update" or "Later".
    ReadyToInstall {
        release: UpdateRelease,
        file: PathBuf,
    },
    Installing {
        release: UpdateRelease,
        file: PathBuf,
    },
    Failed(UpdateFailure),
}

/// What happened.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum UpdateEvent {
    Check,
    Checked(UpdateOutcome),
    /// The Download button. `can_apply`: this system installs in place and a trusted key is built in.
    Download {
        can_apply: bool,
    },
    Progress {
        done: u64,
        total: u64,
    },
    Downloaded(PathBuf),
    DownloadFailed(String),
    /// The signature file could not be fetched.
    SignatureUnavailable,
    Verified(Result<(), UpdateFailure>),
    /// The user stopped the download.
    Cancel,
    /// "Restart to Update"; `unsaved`: the project has changes.
    Install {
        unsaved: bool,
    },
    /// The answer to the save question: true = go on.
    SaveAnswered(bool),
    /// The platform's answer to [`UpdateEffect::Apply`].
    Applied(Result<(), String>),
    /// "Later": install on the next quit.
    Later,
    /// The dialog was closed.
    Dismiss,
}

/// What the shell must do after a transition.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum UpdateEffect {
    /// The platform cannot install in place (or the feed has nothing verifiable): open the link as before.
    OpenUrl(String),
    StartDownload(UpdateInstall),
    /// Check the file; the signature comes from `install.sig_url`.
    Verify {
        file: PathBuf,
        install: UpdateInstall,
    },
    /// Delete a staged file that must not be used.
    Discard(PathBuf),
    /// Ask to save the project before the restart.
    AskToSave,
    /// Put the file in place and restart.
    Apply {
        file: PathBuf,
        version: String,
    },
    /// Put the file in place when the app quits.
    ApplyOnQuit {
        file: PathBuf,
        version: String,
    },
    CancelDownload,
}

impl UpdateFlow {
    /// The one transition function. An event that does not fit the current state changes nothing.
    pub fn step(self, event: UpdateEvent) -> (UpdateFlow, Option<UpdateEffect>) {
        use UpdateEffect as E;
        use UpdateEvent as V;
        use UpdateFlow as S;
        match (self, event) {
            (S::Idle | S::Failed(_), V::Check) => (S::Checking, None),
            (S::Checking, V::Checked(outcome)) => match outcome {
                UpdateOutcome::Available(r) => (S::Available(r), None),
                UpdateOutcome::Failed => (S::Failed(UpdateFailure::CheckFailed), None),
                UpdateOutcome::UpToDate | UpdateOutcome::NotConfigured => (S::Idle, None),
            },
            (S::Available(r), V::Download { can_apply }) => match r.install.clone() {
                Some(install) if can_apply => {
                    let total = install.size.unwrap_or(0);
                    (S::Downloading { release: r, done: 0, total }, Some(E::StartDownload(install)))
                }
                _ => {
                    let url = r.url.clone();
                    (S::Idle, Some(E::OpenUrl(url)))
                }
            },
            (S::Downloading { release, total, .. }, V::Progress { done, total: t }) => {
                (S::Downloading { release, done, total: if t > 0 { t } else { total } }, None)
            }
            (S::Downloading { release, .. }, V::Downloaded(file)) => match release.install.clone() {
                Some(install) => (S::Verifying { release, file: file.clone() }, Some(E::Verify { file, install })),
                None => (S::Failed(UpdateFailure::SignatureMissing), Some(E::Discard(file))),
            },
            (S::Downloading { .. }, V::DownloadFailed(why)) => (S::Failed(UpdateFailure::Download(why)), None),
            (S::Downloading { release, .. }, V::Cancel) => (S::Available(release), Some(E::CancelDownload)),
            (S::Verifying { file, .. }, V::SignatureUnavailable) => {
                (S::Failed(UpdateFailure::SignatureMissing), Some(E::Discard(file)))
            }
            (S::Verifying { release, file }, V::Verified(Ok(()))) => (S::ReadyToInstall { release, file }, None),
            (S::Verifying { file, .. }, V::Verified(Err(why))) => (S::Failed(why), Some(E::Discard(file))),
            (S::ReadyToInstall { release, file }, V::Install { unsaved: true }) => {
                (S::ReadyToInstall { release, file }, Some(E::AskToSave))
            }
            (S::ReadyToInstall { release, file }, V::Install { unsaved: false } | V::SaveAnswered(true)) => {
                let effect = E::Apply { file: file.clone(), version: release.version.clone() };
                (S::Installing { release, file }, Some(effect))
            }
            (s @ S::ReadyToInstall { .. }, V::SaveAnswered(false)) => (s, None),
            (S::ReadyToInstall { release, file }, V::Later) => {
                (S::Idle, Some(E::ApplyOnQuit { file, version: release.version }))
            }
            (S::Installing { .. }, V::Applied(Err(why))) => (S::Failed(UpdateFailure::Apply(why)), None),
            (s @ S::Installing { .. }, V::Applied(Ok(()))) => (s, None),
            (S::Available(_) | S::Failed(_), V::Dismiss) => (S::Idle, None),
            (s, _) => (s, None),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ed25519_dalek::{Signer, SigningKey};

    /// The built-in key matches the release signing key: the fixture was signed by `cargo xtask sign-update`.
    #[test]
    fn the_built_in_key_accepts_a_file_signed_by_the_release_key() {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/update");
        let sha = UpdateTrust::sha256_file(&dir.join("fixture.bin")).expect("fixture");
        let sig = std::fs::read(dir.join("fixture.bin.sig")).expect("signature");
        assert_eq!(UpdateTrust::check_signature(&sha, &sig, &UPDATE_PUBLIC_KEY), Ok(()));
        let mut other = sha;
        other[0] ^= 1;
        assert!(UpdateTrust::check_signature(&other, &sig, &UPDATE_PUBLIC_KEY).is_err());
    }

    fn key_pair() -> (SigningKey, [u8; 32]) {
        let sk = SigningKey::from_bytes(&[7u8; 32]);
        let pk = sk.verifying_key().to_bytes();
        (sk, pk)
    }

    fn scratch(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("sq-update-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).expect("dir");
        d
    }

    fn install_for(bytes: &[u8]) -> UpdateInstall {
        let sha: [u8; 32] = Sha256::digest(bytes).into();
        UpdateInstall {
            name: "SequenceStudio.AppImage".into(),
            url: "https://example.org/a".into(),
            sha256: UpdateTrust::hex(&sha),
            sig_url: "https://example.org/a.sig".into(),
            size: Some(10),
        }
    }

    fn release(install: Option<UpdateInstall>) -> UpdateRelease {
        UpdateRelease { version: "0.3.0".into(), url: "https://example.org/page".into(), notes: None, install }
    }

    fn sign(sk: &SigningKey, bytes: &[u8]) -> Vec<u8> {
        let sha: [u8; 32] = Sha256::digest(bytes).into();
        sk.sign(&sha).to_bytes().to_vec()
    }

    #[test]
    fn a_good_file_and_signature_verify() {
        let (sk, pk) = key_pair();
        let dir = scratch("good");
        let file = dir.join("a");
        std::fs::write(&file, b"installer").expect("write");
        let install = install_for(b"installer");
        let sig = sign(&sk, b"installer");
        assert_eq!(UpdateTrust::verify_file(&file, &install, Some(&sig), &pk), Ok(()));
        // The hex text of the signature is accepted too.
        let hexed = UpdateTrust::hex(&sig);
        assert_eq!(UpdateTrust::verify_file(&file, &install, Some(hexed.as_bytes()), &pk), Ok(()));
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn a_wrong_hash_a_wrong_signature_and_a_missing_signature_fail() {
        let (sk, pk) = key_pair();
        let dir = scratch("bad");
        let file = dir.join("a");
        std::fs::write(&file, b"installer").expect("write");
        let sig = sign(&sk, b"installer");
        let other = install_for(b"another file");
        assert_eq!(UpdateTrust::verify_file(&file, &other, Some(&sig), &pk), Err(UpdateFailure::BadDigest));
        let install = install_for(b"installer");
        let forged = sign(&SigningKey::from_bytes(&[9u8; 32]), b"installer");
        assert_eq!(UpdateTrust::verify_file(&file, &install, Some(&forged), &pk), Err(UpdateFailure::BadSignature));
        assert_eq!(UpdateTrust::verify_file(&file, &install, Some(b"junk"), &pk), Err(UpdateFailure::BadSignature));
        assert_eq!(UpdateTrust::verify_file(&file, &install, None, &pk), Err(UpdateFailure::SignatureMissing));
        // A signature over other bytes does not carry over to this file.
        let other_sig = sign(&sk, b"another file");
        assert_eq!(UpdateTrust::verify_file(&file, &install, Some(&other_sig), &pk), Err(UpdateFailure::BadSignature));
        assert!(matches!(
            UpdateTrust::verify_file(&dir.join("missing"), &install, Some(&sig), &pk),
            Err(UpdateFailure::Unreadable(_))
        ));
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn digest_text_is_compared_case_blind() {
        let sha: [u8; 32] = Sha256::digest(b"x").into();
        assert_eq!(UpdateTrust::check_digest(&sha, &UpdateTrust::hex(&sha).to_uppercase()), Ok(()));
    }

    #[test]
    fn no_key_is_built_in_until_the_ceremony() {
        assert_eq!(UpdateTrust::key().is_some(), UPDATE_PUBLIC_KEY != [0; 32]);
    }

    #[test]
    fn staged_names_never_leave_the_cache() {
        let mut i = install_for(b"x");
        i.name = "../../etc/passwd".into();
        let at = |i: &UpdateInstall, v: &str| UpdateTrust::staged_path(Path::new("/c"), v, i);
        assert_eq!(at(&i, "0.3.0"), Some(PathBuf::from("/c/0.3.0/passwd")));
        assert_ne!(at(&i, "0.3.0"), at(&i, "0.3.1"), "one folder per version");
        assert!(!at(&i, "../x/y").is_some_and(|p| p.components().any(|c| c.as_os_str() == "..")));
        assert_eq!(at(&i, ".."), None);
        i.name = "..".into();
        assert_eq!(at(&i, "0.3.0"), None);
    }

    #[test]
    fn a_pending_update_is_checked_again_before_use() {
        let (sk, pk) = key_pair();
        let dir = scratch("pending");
        let file = dir.join("a");
        std::fs::write(&file, b"installer").expect("write");
        let pending = PendingUpdate {
            file: file.clone(),
            version: "0.3.0".into(),
            install: install_for(b"installer"),
            signature: sign(&sk, b"installer"),
        };
        assert_eq!(pending.verify_with(&pk), Ok(()));
        // A partial or replaced file fails.
        std::fs::write(&file, b"install").expect("write");
        assert_eq!(pending.verify_with(&pk), Err(UpdateFailure::BadDigest));
        let _ = std::fs::remove_file(&file);
        assert!(matches!(pending.verify_with(&pk), Err(UpdateFailure::Unreadable(_))));
        let _ = std::fs::remove_dir_all(dir);
    }

    fn run(mut s: UpdateFlow, events: Vec<UpdateEvent>) -> (UpdateFlow, Vec<UpdateEffect>) {
        let mut effects = Vec::new();
        for e in events {
            let (n, fx) = s.step(e);
            s = n;
            effects.extend(fx);
        }
        (s, effects)
    }

    fn ready() -> UpdateFlow {
        UpdateFlow::ReadyToInstall { release: release(Some(install_for(b"x"))), file: "/c/a".into() }
    }

    #[test]
    fn the_happy_path_ends_in_install() {
        let i = install_for(b"x");
        let (s, fx) = run(
            UpdateFlow::Idle,
            vec![
                UpdateEvent::Check,
                UpdateEvent::Checked(UpdateOutcome::Available(release(Some(i.clone())))),
                UpdateEvent::Download { can_apply: true },
                UpdateEvent::Progress { done: 5, total: 10 },
                UpdateEvent::Downloaded("/c/a".into()),
                UpdateEvent::Verified(Ok(())),
                UpdateEvent::Install { unsaved: false },
                UpdateEvent::Applied(Ok(())),
            ],
        );
        assert!(matches!(s, UpdateFlow::Installing { .. }));
        assert_eq!(
            fx,
            vec![
                UpdateEffect::StartDownload(i.clone()),
                UpdateEffect::Verify { file: "/c/a".into(), install: i },
                UpdateEffect::Apply { file: "/c/a".into(), version: "0.3.0".into() },
            ]
        );
    }

    #[test]
    fn check_outcomes() {
        let (s, _) = run(UpdateFlow::Idle, vec![UpdateEvent::Check, UpdateEvent::Checked(UpdateOutcome::UpToDate)]);
        assert_eq!(s, UpdateFlow::Idle);
        let (s, _) =
            run(UpdateFlow::Idle, vec![UpdateEvent::Check, UpdateEvent::Checked(UpdateOutcome::NotConfigured)]);
        assert_eq!(s, UpdateFlow::Idle);
        let (s, _) = run(UpdateFlow::Idle, vec![UpdateEvent::Check, UpdateEvent::Checked(UpdateOutcome::Failed)]);
        assert_eq!(s, UpdateFlow::Failed(UpdateFailure::CheckFailed));
        let (s, _) = run(s, vec![UpdateEvent::Dismiss]);
        assert_eq!(s, UpdateFlow::Idle);
    }

    #[test]
    fn download_falls_back_to_the_link_without_install_data_or_platform_support() {
        let page = "https://example.org/page";
        // A missing asset, digest or signature leaves no install data.
        let (s, fx) = release(None).pipe_available(UpdateEvent::Download { can_apply: true });
        assert_eq!((s, fx), (UpdateFlow::Idle, Some(UpdateEffect::OpenUrl(page.into()))));
        // Mac and Windows today: the platform answers "not yet".
        let (s, fx) = release(Some(install_for(b"x"))).pipe_available(UpdateEvent::Download { can_apply: false });
        assert_eq!((s, fx), (UpdateFlow::Idle, Some(UpdateEffect::OpenUrl(page.into()))));
    }

    trait PipeAvailable {
        fn pipe_available(self, e: UpdateEvent) -> (UpdateFlow, Option<UpdateEffect>);
    }
    impl PipeAvailable for UpdateRelease {
        fn pipe_available(self, e: UpdateEvent) -> (UpdateFlow, Option<UpdateEffect>) {
            UpdateFlow::Available(self).step(e)
        }
    }

    #[test]
    fn download_problems_fail_and_cancel_goes_back() {
        let r = release(Some(install_for(b"x")));
        let downloading = UpdateFlow::Downloading { release: r.clone(), done: 1, total: 10 };
        let (s, _) = downloading.clone().step(UpdateEvent::DownloadFailed("offline".into()));
        assert_eq!(s, UpdateFlow::Failed(UpdateFailure::Download("offline".into())));
        let (s, fx) = downloading.clone().step(UpdateEvent::Cancel);
        assert_eq!((s, fx), (UpdateFlow::Available(r.clone()), Some(UpdateEffect::CancelDownload)));
        // The feed's size is kept when progress reports none.
        let (s, _) = downloading.step(UpdateEvent::Progress { done: 4, total: 0 });
        assert_eq!(s, UpdateFlow::Downloading { release: r, done: 4, total: 10 });
    }

    #[test]
    fn a_failed_verification_discards_the_file() {
        let r = release(Some(install_for(b"x")));
        for why in [UpdateFailure::BadDigest, UpdateFailure::BadSignature] {
            let v = UpdateFlow::Verifying { release: r.clone(), file: "/c/a".into() };
            let (s, fx) = v.step(UpdateEvent::Verified(Err(why.clone())));
            assert_eq!((s, fx), (UpdateFlow::Failed(why), Some(UpdateEffect::Discard("/c/a".into()))));
        }
        let v = UpdateFlow::Verifying { release: r, file: "/c/a".into() };
        let (s, fx) = v.step(UpdateEvent::SignatureUnavailable);
        assert_eq!(
            (s, fx),
            (UpdateFlow::Failed(UpdateFailure::SignatureMissing), Some(UpdateEffect::Discard("/c/a".into())))
        );
    }

    #[test]
    fn unsaved_work_asks_first() {
        let (s, fx) = ready().step(UpdateEvent::Install { unsaved: true });
        assert_eq!((s.clone(), fx), (ready(), Some(UpdateEffect::AskToSave)));
        let (s2, fx) = s.clone().step(UpdateEvent::SaveAnswered(false));
        assert_eq!((s2, fx), (ready(), None));
        let (s3, fx) = s.step(UpdateEvent::SaveAnswered(true));
        assert!(matches!(s3, UpdateFlow::Installing { .. }));
        assert!(matches!(fx, Some(UpdateEffect::Apply { .. })));
    }

    #[test]
    fn later_installs_on_quit_and_an_apply_error_fails() {
        let (s, fx) = ready().step(UpdateEvent::Later);
        assert_eq!(s, UpdateFlow::Idle);
        assert_eq!(fx, Some(UpdateEffect::ApplyOnQuit { file: "/c/a".into(), version: "0.3.0".into() }));
        let (s, _) = ready().step(UpdateEvent::Install { unsaved: false });
        let (s, _) = s.step(UpdateEvent::Applied(Err("disk full".into())));
        assert_eq!(s, UpdateFlow::Failed(UpdateFailure::Apply("disk full".into())));
    }

    #[test]
    fn events_that_do_not_fit_change_nothing() {
        for s in [UpdateFlow::Idle, UpdateFlow::Checking, ready()] {
            let (n, fx) = s.clone().step(UpdateEvent::Progress { done: 1, total: 2 });
            assert_eq!((n, fx), (s.clone(), None));
            let (n, fx) = s.clone().step(UpdateEvent::Verified(Ok(())));
            assert_eq!((n, fx), (s, None));
        }
        // No install without a verified file.
        let (n, fx) = UpdateFlow::Available(release(None)).step(UpdateEvent::Install { unsaved: false });
        assert_eq!((n, fx), (UpdateFlow::Available(release(None)), None));
    }

    #[test]
    fn progress_text_and_download_progress() {
        assert_eq!(progress_line(12_400_000, 98_000_000), "12.4 of 98.0 MB");
        assert_eq!(progress_line(5_000_000, 0), "5.0 MB");
        let p = DownloadProgress::new();
        p.report(3, 9);
        assert_eq!(p.snapshot(), (3, 9));
        assert!(!p.is_canceled() && p.take_result().is_none());
        p.cancel();
        p.finish(Err("x".into()));
        assert!(p.is_canceled());
        assert_eq!(p.take_result(), Some(Err("x".into())));
        assert_eq!(p.take_result(), None);
    }

    #[test]
    fn failures_have_text() {
        for f in [
            UpdateFailure::CheckFailed,
            UpdateFailure::Download(String::new()),
            UpdateFailure::Download("x".into()),
            UpdateFailure::BadDigest,
            UpdateFailure::SignatureMissing,
            UpdateFailure::BadSignature,
            UpdateFailure::Unreadable("x".into()),
            UpdateFailure::Apply("x".into()),
        ] {
            assert!(!f.message().is_empty());
        }
    }
}
