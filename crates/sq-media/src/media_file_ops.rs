//! Port of `SQMedia/Sources/SQMedia/MediaFileOps.swift`.
//!
//! Copies or moves media into the project's `Files/` folder. Data safety rules:
//! - a copy is written under a temporary name and renamed only after it verified identical (size + sampled hash);
//! - an original is removed only after that verification, and by moving it to the Trash (recoverable);
//! - an existing file is never overwritten: a name clash gets a new name, or reuses the file if it is identical.
//!
//! Portable (Mac, Windows, Linux): the Trash and the Finder alias check are in `sq-trash`.
//! The `MediaManagement` helpers this file needs (`is_inside`, `unique_name`, `collect_plan`) are in `management` below:
//! `MediaManagement.swift` is not ported to any crate yet.

use std::collections::BTreeSet;
use std::fmt;
use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::SystemTime;

use sq_core_model::{ImportMode, MediaRef};
use sq_core_time::sha256_digest::Sha256;

pub use management::{CollectItem, MediaManagement};

/// Why a file operation was refused or failed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Failure {
    /// The source file is not there (its name).
    SourceMissing(String),
    /// The copy did not match the original (the file name).
    VerificationFailed(String),
    /// This system has no Trash the app can use (kept for callers that pass their own remover).
    NoTrash,
    /// Any other file system error (kind and system message).
    Io(std::io::ErrorKind, String),
}

impl fmt::Display for Failure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Failure::SourceMissing(n) => write!(f, "\u{201C}{n}\u{201D} was not found."),
            Failure::VerificationFailed(n) => {
                write!(f, "The copy of \u{201C}{n}\u{201D} did not match the original. The original was kept.")
            }
            Failure::NoTrash => {
                f.write_str("This system has no Trash that Sequence Studio can use. The original was kept.")
            }
            Failure::Io(_, why) => f.write_str(why),
        }
    }
}

impl std::error::Error for Failure {}

impl From<std::io::Error> for Failure {
    fn from(e: std::io::Error) -> Self {
        Failure::Io(e.kind(), e.to_string())
    }
}

/// What `MediaFileOps::ingest` did (Swift: `MediaFileOps.Result`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IngestResult {
    /// Where the media is now (the source for `Leave` or a file already in the folder).
    pub url: PathBuf,
    /// An identical file was already in the folder and is used instead of a new copy.
    pub reused: bool,
    /// The original was removed (moved to the Trash) after a verified copy.
    pub original_removed: bool,
    /// A new file was written into the folder (not reused, not the source itself).
    pub created: bool,
}

impl IngestResult {
    fn at(url: &Path) -> Self {
        IngestResult { url: url.to_path_buf(), reused: false, original_removed: false, created: false }
    }
}

/// What `collect` did: `done` is every planned clip's final copy (clips of one source share it), `failed` the file names
/// that could not be copied (they stay where they are).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CollectOutcome {
    pub done: Vec<CollectItem>,
    pub failed: Vec<String>,
}

/// Removes an original after a verified copy.
pub type Remover<'a> = &'a dyn Fn(&Path) -> Result<(), Failure>;

/// Ingests run one at a time: two files with the same name in one batch must not both see a free name.
static LOCK: Mutex<()> = Mutex::new(());
/// Own lock for LUT collection: a long media ingest never delays it, and it is never taken on the main actor.
static LUT_LOCK: Mutex<()> = Mutex::new(());
/// Paths a later ingest reused (or found identical) since they were created. A pending `discard_unlinked` of such a file is
/// dropped: somebody else's clip may point at it now. Its own lock, so a LUT collect can mark a reused file without waiting
/// for a media ingest.
static REUSED_PATHS: Mutex<BTreeSet<String>> = Mutex::new(BTreeSet::new());
static TEMP_COUNTER: AtomicU64 = AtomicU64::new(0);

fn hold<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// `resolvingSymlinksInPath`: the real path when it exists, else the path unchanged.
fn resolving_symlinks(p: &Path) -> PathBuf {
    sq_os::paths::canonical(p).unwrap_or_else(|_| p.to_path_buf())
}

fn last_component(p: &Path) -> String {
    p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()
}

/// Reads until `count` bytes or the end of the file (`FileHandle.read(upToCount:)`).
fn read_up_to(h: &mut File, count: usize) -> std::io::Result<Vec<u8>> {
    let mut out = Vec::new();
    h.take(count as u64).read_to_end(&mut out)?;
    Ok(out)
}

/// Copies or moves media into the project's `Files/` folder; see the module docs.
pub struct MediaFileOps;

impl MediaFileOps {
    /// Default original remover: Trash, never a hard delete.
    /// Mac `NSFileManager.trashItem`, Windows Recycle Bin, Linux freedesktop Trash (all in `sq-trash`).
    pub fn trash(path: &Path) -> Result<(), Failure> {
        sq_trash::trash(path).map_err(Failure::from)
    }

    /// Brings `source` into `folder` according to `mode`. `Leave` and files already inside `folder` (by any spelling,
    /// symlinks included) return the source untouched. A symlink source is resolved to the real file first.
    pub fn ingest(
        source: &Path,
        folder: &Path,
        mode: ImportMode,
        remove_original: Remover,
    ) -> Result<IngestResult, Failure> {
        if mode == ImportMode::Leave {
            return Ok(IngestResult::at(source));
        }
        let real = resolving_symlinks(source);
        if MediaManagement::is_inside(&real.to_string_lossy(), folder) {
            return Ok(IngestResult::at(source));
        }
        if !real.exists() {
            return Err(Failure::SourceMissing(last_component(source)));
        }
        let _lock = hold(&LOCK);
        Self::ingest_locked(&real, source, folder, mode, remove_original)
    }

    /// Body of `ingest`; the caller holds `LOCK` and has checked that `real` exists and is outside `folder`.
    fn ingest_locked(
        real: &Path,
        source: &Path,
        folder: &Path,
        mode: ImportMode,
        remove_original: Remover,
    ) -> Result<IngestResult, Failure> {
        // A folder is no media file: copying it whole would differ per platform (Windows copies it, the Mac fails verification).
        if real.is_dir() {
            return Err(Failure::VerificationFailed(last_component(real)));
        }
        fs::create_dir_all(folder)?;

        let name = last_component(real);
        let mut final_path = folder.join(&name);
        let mut reused = false;
        let mut copied = false;
        for _ in 0..50 {
            if copied || reused {
                break;
            }
            if final_path.exists() {
                if Self::same_file(real, &final_path) {
                    return Ok(IngestResult::at(source)); // the file itself, reached another way
                }
                if Self::fully_identical(real, &final_path) == Ok(true) {
                    reused = true;
                    break;
                }
                let free = MediaManagement::unique_name(&name, |n| folder.join(n).exists());
                final_path = folder.join(free);
                continue;
            }
            match Self::verified_copy(real, &final_path) {
                Ok(()) => copied = true,
                Err(Failure::Io(std::io::ErrorKind::AlreadyExists, _)) => continue, // taken meanwhile: look again
                Err(e) => return Err(e),
            }
        }
        if !(copied || reused) {
            return Err(Failure::VerificationFailed(name));
        }
        if reused {
            Self::note_reused(&final_path);
        } else {
            Self::take_mark(&final_path);
        }

        let mut removed = false;
        if mode == ImportMode::Move && !Self::is_link_or_alias(source) {
            // A link is copied, never trashed. Full content comparison right before the original goes away; never on the
            // sampled hash alone.
            if Self::fully_identical(real, &final_path) != Ok(true) || Self::same_file(real, &final_path) {
                return Err(Failure::VerificationFailed(name));
            }
            removed = remove_original(real).is_ok(); // keep the original on any failure
        }
        Ok(IngestResult { url: final_path, reused, original_removed: removed, created: copied })
    }

    /// Collect Files into Project Folder: copies the media outside `folder` into it (`MediaManagement::collect_plan` names
    /// the copies, `ingest` verifies each one). Originals stay. Blocking: call it off the main thread.
    pub fn collect(media: &[MediaRef], folder: &Path) -> CollectOutcome {
        let existing: BTreeSet<String> = fs::read_dir(folder)
            .map(|rd| rd.flatten().map(|e| e.file_name().to_string_lossy().to_lowercase()).collect())
            .unwrap_or_default();
        let plan = MediaManagement::collect_plan(media, folder, &existing, |p| Path::new(p).exists());
        let mut out = CollectOutcome::default();
        let mut copied: std::collections::HashMap<String, String> = std::collections::HashMap::new();
        for item in plan {
            if let Some(d) = copied.get(&item.source) {
                let mut i = item.clone();
                i.destination = d.clone();
                out.done.push(i);
                continue;
            }
            match Self::ingest(Path::new(&item.source), folder, ImportMode::Copy, &Self::trash) {
                Ok(r) => {
                    let dest = r.url.to_string_lossy().into_owned();
                    let mut i = item.clone();
                    i.destination = dest.clone();
                    out.done.push(i);
                    copied.insert(item.source.clone(), dest);
                }
                Err(_) => out.failed.push(last_component(Path::new(&item.source))),
            }
        }
        out
    }

    /// Brings a library item into `folder` (`Files/Library/`), deduplicated by content: if any file there already has the
    /// same content (same size and SHA-256 over the whole file) that file is used, whatever its name; otherwise the item
    /// is copied (name clash = " 2"). The source is never touched.
    pub fn ingest_library_item(source: &Path, folder: &Path) -> Result<IngestResult, Failure> {
        let real = resolving_symlinks(source);
        if MediaManagement::is_inside(&real.to_string_lossy(), folder) {
            return Ok(IngestResult::at(source));
        }
        if !real.exists() {
            return Err(Failure::SourceMissing(last_component(source)));
        }
        let _lock = hold(&LOCK);
        if let Some(same) = Self::identical_file(&real, folder)? {
            Self::note_reused(&same);
            return Ok(IngestResult { reused: true, ..IngestResult::at(&same) });
        }
        Self::ingest_locked(&real, source, folder, ImportMode::Copy, &Self::trash)
    }

    /// A file directly in `folder` with exactly the content of `file`, if there is one.
    pub fn identical_file(file: &Path, folder: &Path) -> Result<Option<PathBuf>, Failure> {
        let Ok(rd) = fs::read_dir(folder) else { return Ok(None) };
        let mut names: Vec<String> = rd.flatten().map(|e| e.file_name().to_string_lossy().into_owned()).collect();
        names.sort();
        let want = Self::size(file)?;
        let mut hash: Option<String> = None;
        for n in names.iter().filter(|n| !n.starts_with('.')) {
            let c = folder.join(n);
            if Self::size(&c).ok() != Some(want) {
                continue;
            }
            if hash.is_none() {
                hash = Some(Self::content_hash(file)?);
            }
            if Some(Self::content_hash(&c)?) == hash {
                return Ok(Some(c));
            }
        }
        Ok(None)
    }

    /// SHA-256 of the whole file, streamed.
    pub fn content_hash(url: &Path) -> Result<String, Failure> {
        let mut h = File::open(url)?;
        let mut hasher = Sha256::new();
        loop {
            let d = read_up_to(&mut h, 4 << 20)?;
            if d.is_empty() {
                break;
            }
            hasher.update(&d);
        }
        Ok(hasher.finalize_hex())
    }

    /// The "Move" half after the clips already point at `copy`: removes `original` only when `copy` is a different file
    /// with byte-identical content. Returns true when the original was removed (to the Trash by default).
    pub fn remove_original(original: &Path, copy: &Path, remover: Remover) -> bool {
        if Self::is_link_or_alias(original) {
            return false; // a link's target is somebody else's file: never trashed
        }
        let real = resolving_symlinks(original);
        if !real.exists() || Self::same_file(&real, copy) || Self::fully_identical(&real, copy) != Ok(true) {
            return false;
        }
        remover(&real).is_ok()
    }

    /// True when `url` itself is a symbolic link.
    /// or, on the Mac, a Finder alias file (`isAliasFileKey`).
    pub fn is_link_or_alias(url: &Path) -> bool {
        fs::symlink_metadata(url).is_ok_and(|m| m.file_type().is_symlink()) || sq_trash::is_finder_alias(url)
    }

    /// Deletes copies that a canceled batch created but never linked a clip to. Reused and untouched files stay.
    /// Runs under the ingest lock: a file that a later ingest reused meanwhile (a re-drop after a Revert) is kept.
    pub fn discard_unlinked(results: &[IngestResult]) {
        let _lock = hold(&LOCK);
        for r in results.iter().filter(|r| r.created) {
            if Self::take_mark(&r.url) {
                continue; // entry resolved: kept
            }
            let _ = fs::remove_file(&r.url);
        }
    }

    fn note_reused(url: &Path) {
        let k = Self::identity_key(url);
        hold(&REUSED_PATHS).insert(k);
    }

    fn take_mark(url: &Path) -> bool {
        let k = Self::identity_key(url);
        hold(&REUSED_PATHS).remove(&k)
    }

    /// A key for "this very file on disk". On Unix an existing file is named by device and inode, so `IMG.MOV` and `img.mov`
    /// on a case-insensitive volume agree and symlinks are followed; a file that does not exist keeps its path.
    /// Elsewhere the key is the resolved path, lowercased.
    // shortcut: Windows paths are case-insensitive on the usual volumes, so the key is lowercased; a case-sensitive NTFS
    // folder would merge two names; upgrade with GetFinalPathNameByHandle when that matters.
    pub fn identity_key(url: &Path) -> String {
        #[cfg(unix)]
        if let Some(id) = Self::unix_identity(url) {
            return id;
        }
        resolving_symlinks(url).to_string_lossy().to_lowercase()
    }

    /// `identity_key` of a path given as text.
    pub fn identity_key_path(path: &str) -> String {
        Self::identity_key(Path::new(path))
    }

    #[cfg(unix)]
    fn unix_identity(url: &Path) -> Option<String> {
        use std::os::unix::fs::MetadataExt;
        let m = fs::metadata(url).ok()?;
        Some(format!("{}:{}", m.dev(), m.ino()))
    }

    /// True when both paths are the very same file (hard link, symlink, other spelling, case).
    pub fn same_file(a: &Path, b: &Path) -> bool {
        #[cfg(unix)]
        {
            matches!((Self::unix_identity(a), Self::unix_identity(b)), (Some(x), Some(y)) if x == y)
        }
        #[cfg(not(unix))]
        {
            Self::identity_key(a) == Self::identity_key(b)
        }
    }

    /// What names the file itself (volume and file number): equal for a hard link, a symlink, another spelling of the path
    /// or a different letter case on a case-insensitive volume. None when the file cannot be reached.
    pub fn file_identity(url: &Path) -> Option<String> {
        if !url.exists() {
            return None;
        }
        Some(Self::identity_key(url))
    }

    /// Byte-for-byte comparison, streamed.
    pub fn fully_identical(a: &Path, b: &Path) -> Result<bool, Failure> {
        if Self::size(a)? != Self::size(b)? {
            return Ok(false);
        }
        let (mut ha, mut hb) = (File::open(a)?, File::open(b)?);
        loop {
            let da = read_up_to(&mut ha, 4 << 20)?;
            let db = read_up_to(&mut hb, 4 << 20)?;
            if da != db {
                return Ok(false);
            }
            if da.is_empty() {
                return Ok(true);
            }
        }
    }

    /// Removes copy leftovers (`.name.sqpart-...`, from a crash or a quit during a copy) in `folder` that are older than
    /// `age` seconds. Newer ones may belong to a copy that is still running. Returns how many were removed.
    pub fn remove_stale_temporaries(folder: &Path, older_than_seconds: f64, now: SystemTime) -> usize {
        let Ok(rd) = fs::read_dir(folder) else { return 0 };
        let mut removed = 0;
        for entry in rd.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if !(name.starts_with('.') && name.contains(".sqpart-")) {
                continue;
            }
            let Ok(modified) = fs::metadata(entry.path()).and_then(|m| m.modified()) else { continue };
            let age = match now.duration_since(modified) {
                Ok(d) => d.as_secs_f64(),
                Err(e) => -e.duration().as_secs_f64(),
            };
            if age > older_than_seconds && fs::remove_file(entry.path()).is_ok() {
                removed += 1;
            }
        }
        removed
    }

    /// Copies via a temporary sibling and renames it into place after verification. `destination` must not exist.
    // shortcut: no cancellation check between the copy and the verification (Swift: Task.checkCancellation); upgrade when a
    // CancelToken exists (docs/rust/PORTING.md section 9).
    pub fn verified_copy(source: &Path, destination: &Path) -> Result<(), Failure> {
        let dir = destination.parent().unwrap_or(Path::new(""));
        let token =
            format!("{:x}-{:x}-{:x}", std::process::id(), TEMP_COUNTER.fetch_add(1, Ordering::Relaxed), nanos());
        let tmp = dir.join(format!(".{}.sqpart-{token}", last_component(destination)));
        let step = || -> Result<(), Failure> {
            fs::copy(source, &tmp)?;
            if !Self::identical(source, &tmp)? {
                return Err(Failure::VerificationFailed(last_component(source)));
            }
            Ok(move_without_replacing(&tmp, destination)?)
        };
        step().inspect_err(|_| {
            let _ = fs::remove_file(&tmp);
        })
    }

    /// Same size and same hash over the first and last megabyte plus samples spread through the file.
    pub fn identical(a: &Path, b: &Path) -> Result<bool, Failure> {
        let (size_a, size_b) = (Self::size(a)?, Self::size(b)?);
        if size_a != size_b {
            return Ok(false);
        }
        Ok(Self::sample_hash(a, size_a)? == Self::sample_hash(b, size_b)?)
    }

    fn size(url: &Path) -> Result<i64, Failure> {
        Ok(i64::try_from(fs::metadata(url)?.len()).unwrap_or(-1))
    }

    fn sample_hash(url: &Path, size: i64) -> Result<String, Failure> {
        let mut h = File::open(url)?;
        let mut hasher = Sha256::new();
        let head: i64 = 1 << 20;
        let chunk: i64 = 64 << 10;
        let mut read = |offset: i64, count: i64| -> Result<(), Failure> {
            h.seek(SeekFrom::Start(offset.max(0) as u64))?;
            hasher.update(&read_up_to(&mut h, count as usize)?);
            Ok(())
        };
        if size <= head * 2 + chunk * 8 {
            // Small file: hash everything.
            read(0, size)?;
        } else {
            read(0, head)?;
            read(size - head, head)?;
            for i in 1..=6 {
                read(size * i / 7, chunk)?;
            }
        }
        Ok(hasher.finalize_hex())
    }

    /// Copies a LUT file into `folder` (`Files/Library/`) unless a file with the same content is already there; returns the
    /// file to use. Small files only (hashes the candidates of equal size). The source is never touched.
    pub fn collect_lut(source: &Path, folder: &Path) -> Result<IngestResult, Failure> {
        let real = resolving_symlinks(source);
        if !real.exists() {
            return Err(Failure::SourceMissing(last_component(source)));
        }
        let _lock = hold(&LUT_LOCK); // not `LOCK`: a long media ingest must not stall a save
        fs::create_dir_all(folder)?;
        if let Some(same) = Self::identical_file(&real, folder)? {
            Self::note_reused(&same);
            // A discard may have removed the file between the match and the mark: then copy it again below.
            if same.exists() {
                return Ok(IngestResult { reused: true, ..IngestResult::at(&same) });
            }
        }
        let name = last_component(&real);
        let mut final_path = folder.join(&name);
        for _ in 0..50 {
            if final_path.exists() {
                // other content under that name: next free name
                let free = MediaManagement::unique_name(&name, |n| folder.join(n).exists());
                final_path = folder.join(free);
                continue;
            }
            match Self::verified_copy(&real, &final_path) {
                Ok(()) => return Ok(IngestResult { created: true, ..IngestResult::at(&final_path) }),
                Err(Failure::Io(std::io::ErrorKind::AlreadyExists, _)) => continue,
                Err(e) => return Err(e),
            }
        }
        Err(Failure::VerificationFailed(name))
    }
}

fn nanos() -> u128 {
    SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).map_or(0, |d| d.as_nanos())
}

/// Moves `from` to `to` and fails with `AlreadyExists` when `to` is there (a plain rename would replace it).
// shortcut: a file system without hard links falls back to an exists check before the rename, so another process could
// still slip a file in between; upgrade with renameat2(RENAME_NOREPLACE) / MoveFileEx without REPLACE_EXISTING.
fn move_without_replacing(from: &Path, to: &Path) -> std::io::Result<()> {
    match fs::hard_link(from, to) {
        Ok(()) => fs::remove_file(from),
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => Err(e),
        Err(_) if to.exists() => Err(std::io::ErrorKind::AlreadyExists.into()),
        Err(_) => fs::rename(from, to),
    }
}

/// The part of `MediaManagement.swift` (SQCore) that `MediaFileOps` calls. The rest of that file (project folder layout,
/// import mode, stored path resolving) is not ported yet; move this module to its home when it is.
mod management {
    use std::collections::{BTreeSet, HashMap};
    use std::path::{Component, Path, PathBuf};

    use sq_core_model::MediaRef;
    use sq_core_time::Id;

    /// One file to bring into the project's `Files/` folder.
    #[derive(Debug, Clone, PartialEq, Eq, Hash)]
    pub struct CollectItem {
        pub id: Id,
        pub source: String,
        pub destination: String,
    }

    /// Pure planning for the project folder and for collecting media into it (the used part).
    pub struct MediaManagement;

    impl MediaManagement {
        /// True when `path` lies inside `folder` (component-wise, so `/a/Files2/x` is not inside `/a/Files`).
        /// Symlinks are resolved on both sides (`/var` = `/private/var`) and names compare case-insensitively: a wrong
        /// "inside" only skips a copy, a wrong "outside" could lose data.
        // shortcut: always case-insensitive (Swift asks the volume and falls back to this); upgrade when a volume query exists.
        pub fn is_inside(path: &str, folder: &Path) -> bool {
            let norm = |p: &Path| -> Vec<String> {
                p.components()
                    .filter(|c| !matches!(c, Component::CurDir))
                    .map(|c| c.as_os_str().to_string_lossy().to_lowercase())
                    .collect()
            };
            let fc = norm(&resolved(folder));
            let pc = norm(&resolved(Path::new(path)));
            pc.len() > fc.len() && pc[..fc.len()] == fc[..]
        }

        /// `name`, or `name 2.ext`, `name 3.ext` ... the first that `taken` does not claim (called with the real-case
        /// candidate; callers fold case themselves).
        pub fn unique_name(name: &str, taken: impl Fn(&str) -> bool) -> String {
            if !taken(name) {
                return name.to_string();
            }
            let p = Path::new(name);
            let ext = p.extension().map(|e| e.to_string_lossy().into_owned()).unwrap_or_default();
            let stem = if ext.is_empty() {
                name.to_string()
            } else {
                p.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default()
            };
            let mut n = 2;
            loop {
                let c = if ext.is_empty() { format!("{stem} {n}") } else { format!("{stem} {n}.{ext}") };
                if !taken(&c) {
                    return c;
                }
                n += 1;
            }
        }

        /// Media that must be copied to bring the project into `files`: skips media already inside it and media whose source
        /// is gone (`exists` false). Destination names are unique among each other and against `existing` (lowercased names
        /// already in `files`). Media sharing one source path share one destination.
        pub fn collect_plan(
            media: &[MediaRef],
            files: &Path,
            existing: &BTreeSet<String>,
            exists: impl Fn(&str) -> bool,
        ) -> Vec<CollectItem> {
            let mut used = existing.clone();
            let mut by_source: HashMap<String, String> = HashMap::new();
            let mut out = Vec::new();
            for m in media {
                if Self::is_inside(&m.path, files) || !exists(&m.path) {
                    continue;
                }
                let dest = match by_source.get(&m.path) {
                    Some(d) => d.clone(),
                    None => {
                        let last = Path::new(&m.path)
                            .file_name()
                            .map(|n| n.to_string_lossy().into_owned())
                            .unwrap_or_default();
                        let name = Self::unique_name(&last, |n| used.contains(&n.to_lowercase()));
                        used.insert(name.to_lowercase());
                        let dest = files.join(&name).to_string_lossy().into_owned();
                        by_source.insert(m.path.clone(), dest.clone());
                        dest
                    }
                };
                out.push(CollectItem { id: m.id, source: m.path.clone(), destination: dest });
            }
            out
        }
    }

    /// Lexical `standardizedFileURL`: drops `.` and folds `..` where a normal component precedes it.
    fn standardized(p: &Path) -> PathBuf {
        let mut out = PathBuf::new();
        for c in p.components() {
            match c {
                Component::CurDir => {}
                Component::ParentDir if matches!(out.components().next_back(), Some(Component::Normal(_))) => {
                    out.pop();
                }
                other => out.push(other.as_os_str()),
            }
        }
        out
    }

    /// Symlinks resolved for the part that exists; a missing tail is appended unchanged.
    fn resolved(p: &Path) -> PathBuf {
        let std = standardized(p);
        let mut base = std.clone();
        while !base.exists() && base.parent().is_some_and(|b| !b.as_os_str().is_empty()) {
            base.pop();
        }
        let mut out = super::resolving_symlinks(&base);
        if let Ok(tail) = std.strip_prefix(&base) {
            out.push(tail);
        }
        standardized(&out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    struct Dirs {
        src: PathBuf,
        files: PathBuf,
        root: PathBuf,
    }

    impl Dirs {
        fn new() -> Dirs {
            let root = std::env::temp_dir().join(format!(
                "sqmfo-{}-{}",
                std::process::id(),
                TEMP_COUNTER.fetch_add(1, Ordering::Relaxed)
            ));
            let (src, files) = (root.join("Desktop"), root.join("Proj/Files"));
            assert!(fs::create_dir_all(&src).is_ok());
            Dirs { src, files, root }
        }
    }

    impl Drop for Dirs {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }

    fn write(path: &Path, bytes: usize, seed: u8) {
        let data: Vec<u8> = (0..bytes).map(|i| (i as u8).wrapping_mul(31).wrapping_add(seed)).collect();
        assert!(fs::write(path, data).is_ok(), "{}", path.display());
    }

    fn remove_hard(p: &Path) -> Result<(), Failure> {
        fs::remove_file(p).map_err(Failure::from)
    }

    fn names(dir: &Path) -> Vec<String> {
        let mut n: Vec<String> = fs::read_dir(dir)
            .map(|rd| rd.flatten().map(|e| e.file_name().to_string_lossy().into_owned()).collect())
            .unwrap_or_default();
        n.sort();
        n
    }

    fn ingest(s: &Path, d: &Dirs, mode: ImportMode) -> IngestResult {
        MediaFileOps::ingest(s, &d.files, mode, &remove_hard).unwrap_or_else(|e| panic!("{e}"))
    }

    #[test]
    fn copy_keeps_original_and_creates_folder() {
        let d = Dirs::new();
        let s = d.src.join("shot.png");
        write(&s, 5000, 1);
        let r = MediaFileOps::ingest(&s, &d.files, ImportMode::Copy, &MediaFileOps::trash)
            .unwrap_or_else(|e| panic!("{e}"));
        assert!(s.exists());
        assert_eq!(r.url, d.files.join("shot.png"));
        assert_eq!(MediaFileOps::identical(&s, &r.url), Ok(true));
        assert!(!r.original_removed);
        assert_eq!(names(&d.files), ["shot.png"]); // no temp leftovers
    }

    #[test]
    fn move_removes_original_only_after_verified_copy() {
        let d = Dirs::new();
        let s = d.src.join("shot.png");
        write(&s, 5000, 1);
        let r = ingest(&s, &d, ImportMode::Move);
        assert!(!s.exists());
        assert!(r.url.exists() && r.original_removed);
    }

    #[test]
    fn move_keeps_original_when_removal_fails() {
        let d = Dirs::new();
        let s = d.src.join("a.mov");
        write(&s, 100, 1);
        let r = MediaFileOps::ingest(&s, &d.files, ImportMode::Move, &|_| Err(Failure::NoTrash))
            .unwrap_or_else(|e| panic!("{e}"));
        assert!(s.exists() && r.url.exists() && !r.original_removed);
        // A remover that fails for another reason keeps the original too.
        let t = d.src.join("b.mov");
        write(&t, 100, 2);
        let r = MediaFileOps::ingest(&t, &d.files, ImportMode::Move, &|_| {
            Err(Failure::Io(std::io::ErrorKind::Other, "x".into()))
        })
        .unwrap_or_else(|e| panic!("{e}"));
        assert!(t.exists() && !r.original_removed);
    }

    #[test]
    fn leave_and_inside_return_source_untouched() {
        let d = Dirs::new();
        let s = d.src.join("a.mov");
        write(&s, 100, 1);
        assert_eq!(ingest(&s, &d, ImportMode::Leave).url, s);
        assert!(!d.files.exists());
        assert!(fs::create_dir_all(&d.files).is_ok());
        let inside = d.files.join("b.mov");
        write(&inside, 100, 1);
        let r = ingest(&inside, &d, ImportMode::Move);
        assert!(r.url == inside && inside.exists());
    }

    #[test]
    fn name_clash_with_different_content_gets_new_name() {
        let d = Dirs::new();
        assert!(fs::create_dir_all(&d.files).is_ok());
        let existing = d.files.join("a.mov");
        write(&existing, 100, 9);
        let s = d.src.join("a.mov");
        write(&s, 100, 1);
        let r = ingest(&s, &d, ImportMode::Copy);
        assert!(last_component(&r.url) == "a 2.mov" && !r.reused);
        assert_eq!(MediaFileOps::identical(&s, &r.url), Ok(true));
        assert_eq!(fs::metadata(&existing).map(|m| m.len()).ok(), Some(100));
        assert_eq!(MediaFileOps::identical(&existing, &s), Ok(false)); // existing untouched
    }

    #[test]
    fn identical_file_in_folder_is_reused() {
        let d = Dirs::new();
        let s = d.src.join("a.mov");
        write(&s, 100, 1);
        ingest(&s, &d, ImportMode::Copy);
        let r = ingest(&s, &d, ImportMode::Copy);
        assert!(r.reused && last_component(&r.url) == "a.mov");
        assert_eq!(names(&d.files).len(), 1);
    }

    #[test]
    fn missing_source_throws_and_writes_nothing() {
        let d = Dirs::new();
        let r = MediaFileOps::ingest(&d.src.join("x.mov"), &d.files, ImportMode::Move, &remove_hard);
        assert_eq!(r, Err(Failure::SourceMissing("x.mov".into())));
        assert!(!d.files.exists());
    }

    #[test]
    fn large_file_sampled_hash_detects_middle_change() {
        let d = Dirs::new();
        let (a, b) = (d.src.join("a.bin"), d.src.join("b.bin"));
        write(&a, 6 << 20, 1);
        let mut data = fs::read(&a).unwrap_or_default();
        assert_eq!(MediaFileOps::identical(&a, &a), Ok(true));
        let at = data.len() * 3 / 7 + 10; // inside a sampled chunk
        data[at] ^= 0xFF;
        assert!(fs::write(&b, &data).is_ok());
        assert_eq!(MediaFileOps::identical(&a, &b), Ok(false));
    }

    #[cfg(unix)]
    #[test]
    fn move_of_a_file_already_in_files_via_symlink_never_removes_it() {
        let d = Dirs::new();
        assert!(fs::create_dir_all(&d.files).is_ok());
        let real = d.files.join("a.mov");
        write(&real, 100, 1);
        let alias = d.root.join("alias");
        assert!(std::os::unix::fs::symlink(&d.files, &alias).is_ok());
        let via_alias = alias.join("a.mov");
        let r = ingest(&via_alias, &d, ImportMode::Move);
        assert!(real.exists() && !r.original_removed && r.url == via_alias);
        // A symlink elsewhere pointing into Files is the same.
        let link = d.src.join("link.mov");
        assert!(std::os::unix::fs::symlink(&real, &link).is_ok());
        let r2 = ingest(&link, &d, ImportMode::Move);
        assert!(real.exists() && !r2.original_removed);
    }

    #[cfg(unix)]
    #[test]
    fn symlink_source_copies_the_real_file() {
        let d = Dirs::new();
        let real = d.src.join("real.mov");
        write(&real, 300, 1);
        let link = d.src.join("link.mov");
        assert!(std::os::unix::fs::symlink(&real, &link).is_ok());
        let r = ingest(&link, &d, ImportMode::Copy);
        assert!(fs::symlink_metadata(&r.url).is_ok_and(|m| m.file_type().is_file()));
        assert_eq!(MediaFileOps::identical(&real, &r.url), Ok(true));
    }

    #[test]
    fn same_named_files_ingested_in_parallel_get_distinct_names() {
        let d = Dirs::new();
        let mut urls = Vec::new();
        for i in 0..6u8 {
            let dir = d.src.join(format!("card{i}"));
            assert!(fs::create_dir_all(&dir).is_ok());
            let u = dir.join("C0001.MP4");
            write(&u, 500, i + 1);
            urls.push(u);
        }
        let results: Vec<PathBuf> = std::thread::scope(|scope| {
            let handles: Vec<_> = urls.iter().map(|u| scope.spawn(|| ingest(u, &d, ImportMode::Copy).url)).collect();
            handles.into_iter().filter_map(|h| h.join().ok()).collect()
        });
        let distinct: BTreeSet<String> = results.iter().map(|r| last_component(r).to_lowercase()).collect();
        assert_eq!(distinct.len(), 6);
        for u in &urls {
            assert!(results.iter().any(|r| MediaFileOps::identical(u, r) == Ok(true)));
        }
    }

    #[test]
    fn sampled_equal_but_different_file_is_never_reused_or_trashed() {
        let d = Dirs::new();
        assert!(fs::create_dir_all(&d.files).is_ok());
        let s = d.src.join("a.bin");
        write(&s, 6 << 20, 1);
        let mut data = fs::read(&s).unwrap_or_default();
        data[1_500_000] ^= 0xFF; // between the samples
        let existing = d.files.join("a.bin");
        assert!(fs::write(&existing, &data).is_ok());
        assert_eq!(MediaFileOps::identical(&s, &existing), Ok(true)); // the sampled check is fooled
        let r = ingest(&s, &d, ImportMode::Move);
        assert!(!r.reused && last_component(&r.url) == "a 2.bin");
        assert_eq!(MediaFileOps::fully_identical(&r.url, &existing), Ok(false)); // own copy, not the stand-in
        assert_eq!(fs::read(&existing).ok(), Some(data));
    }

    #[test]
    fn existing_uppercase_numbered_name_is_not_overwritten() {
        let d = Dirs::new();
        assert!(fs::create_dir_all(&d.files).is_ok());
        let (a, b) = (d.files.join("Clip.MOV"), d.files.join("Clip 2.MOV"));
        write(&a, 50, 3);
        write(&b, 50, 4);
        let s = d.src.join("Clip.MOV");
        write(&s, 50, 5);
        let r = ingest(&s, &d, ImportMode::Copy);
        assert_eq!(last_component(&r.url), "Clip 3.MOV");
        assert_eq!(MediaFileOps::identical(&b, &s), Ok(false));
    }

    #[test]
    fn library_items_are_deduplicated_by_content_not_name() {
        let d = Dirs::new();
        let lib = d.root.join("Proj/Files/Library");
        let (a, copy_of_a, other) = (d.src.join("boom.wav"), d.src.join("boom copy.wav"), d.src.join("boom2.wav"));
        write(&a, 3000, 2);
        write(&copy_of_a, 3000, 2);
        write(&other, 3000, 3);
        assert!(!lib.exists());
        let first = MediaFileOps::ingest_library_item(&a, &lib).unwrap_or_else(|e| panic!("{e}"));
        assert!(last_component(&first.url) == "boom.wav" && !first.reused);
        let again = MediaFileOps::ingest_library_item(&copy_of_a, &lib).unwrap_or_else(|e| panic!("{e}")); // other name, same content
        assert!(again.reused && again.url == first.url);
        let different = MediaFileOps::ingest_library_item(&other, &lib).unwrap_or_else(|e| panic!("{e}"));
        assert!(!different.reused && last_component(&different.url) == "boom2.wav");
        assert_eq!(names(&lib), ["boom.wav", "boom2.wav"]);
        assert!(a.exists() && copy_of_a.exists()); // sources untouched
    }

    #[test]
    fn same_size_but_different_content_is_not_merged() {
        let d = Dirs::new();
        let lib = d.root.join("Proj/Files/Library");
        let (a, b) = (d.src.join("a.wav"), d.src.join("b.wav"));
        write(&a, 3 << 20, 1);
        let mut data = fs::read(&a).unwrap_or_default();
        data[1_500_000] ^= 0xFF;
        assert!(fs::write(&b, &data).is_ok()); // between the samples
        assert!(MediaFileOps::ingest_library_item(&a, &lib).is_ok());
        let r = MediaFileOps::ingest_library_item(&b, &lib).unwrap_or_else(|e| panic!("{e}"));
        assert!(!r.reused && last_component(&r.url) == "b.wav");
    }

    #[test]
    fn move_after_copy_removes_original_only_when_verified() {
        let d = Dirs::new();
        let s = d.src.join("a.mov");
        write(&s, 400, 1);
        let copy = d.root.join("copy.mov");
        write(&copy, 400, 9); // same size, other content
        assert!(!MediaFileOps::remove_original(&s, &copy, &remove_hard) && s.exists());
        assert!(fs::remove_file(&copy).is_ok() && fs::copy(&s, &copy).is_ok());
        assert!(!MediaFileOps::remove_original(&s, &s, &remove_hard) && s.exists()); // same file
        assert!(MediaFileOps::remove_original(&s, &copy, &remove_hard));
        assert!(!s.exists() && copy.exists());
        assert!(!MediaFileOps::remove_original(&s, &copy, &remove_hard)); // already gone: nothing happens
    }

    #[cfg(unix)]
    #[test]
    fn a_symlink_move_copies_the_content_and_trashes_nothing() {
        let d = Dirs::new();
        let target = d.src.join("real.mov");
        write(&target, 400, 1);
        let link = d.src.join("link.mov");
        assert!(std::os::unix::fs::symlink(&target, &link).is_ok());
        assert!(MediaFileOps::is_link_or_alias(&link) && !MediaFileOps::is_link_or_alias(&target));
        let r = ingest(&link, &d, ImportMode::Move);
        assert!(!r.original_removed && target.exists() && r.url.exists());
        let copy = d.root.join("copy.mov");
        assert!(fs::copy(&target, &copy).is_ok());
        assert!(!MediaFileOps::remove_original(&link, &copy, &remove_hard) && target.exists());
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn move_with_the_default_trash_removes_the_original() {
        let d = Dirs::new();
        let s = d.src.join("sq-w137-trash-test.mov");
        write(&s, 300, 9);
        let r = MediaFileOps::ingest(&s, &d.files, ImportMode::Move, &MediaFileOps::trash)
            .unwrap_or_else(|e| panic!("{e}"));
        assert!(!s.exists() && r.url.exists() && r.original_removed);
    }

    #[test]
    fn canceled_batch_deletes_only_copies_it_created() {
        let d = Dirs::new();
        let (a, b) = (d.src.join("a.mov"), d.src.join("b.mov"));
        write(&a, 300, 1);
        write(&b, 300, 4);
        let ra = ingest(&a, &d, ImportMode::Copy);
        let rb = ingest(&b, &d, ImportMode::Copy);
        let again = ingest(&a, &d, ImportMode::Copy); // reuses the identical file
        assert!(ra.created && rb.created && !again.created);
        MediaFileOps::discard_unlinked(&[rb.clone(), again]);
        assert!(ra.url.exists() && !rb.url.exists());
        assert!(a.exists() && b.exists());
    }

    #[test]
    fn a_stale_discard_keeps_a_file_a_re_drop_reused() {
        let d = Dirs::new();
        let a = d.src.join("a.mov");
        write(&a, 300, 1);
        let first = ingest(&a, &d, ImportMode::Copy); // the canceled batch's copy
        let re_drop = ingest(&a, &d, ImportMode::Copy); // after Revert: same file, reused
        assert!(first.created && re_drop.reused && re_drop.url == first.url);
        MediaFileOps::discard_unlinked(std::slice::from_ref(&first)); // the stale delete lands late
        assert!(first.url.exists());
        MediaFileOps::discard_unlinked(std::slice::from_ref(&first)); // nothing reused it since: removed
        assert!(!first.url.exists());
    }

    #[test]
    fn a_collected_lut_is_copied_once_by_content_and_the_source_stays() {
        let d = Dirs::new();
        let library = d.root.join("Proj/Files/Library");
        let lut = d.src.join("look.cube");
        write(&lut, 200, 1);
        let first = MediaFileOps::collect_lut(&lut, &library).unwrap_or_else(|e| panic!("{e}"));
        assert!(first.created && last_component(&first.url) == "look.cube");
        assert_eq!(MediaFileOps::fully_identical(&lut, &first.url), Ok(true));
        let twin = d.src.join("twin.cube");
        assert!(fs::copy(&lut, &twin).is_ok());
        assert_eq!(MediaFileOps::collect_lut(&twin, &library).map(|r| r.url), Ok(first.url.clone())); // same content: reused
        let other = d.src.join("sub");
        assert!(fs::create_dir_all(&other).is_ok());
        let clash = other.join("look.cube");
        write(&clash, 200, 9);
        let second = MediaFileOps::collect_lut(&clash, &library).unwrap_or_else(|e| panic!("{e}")); // same name, other content
        assert!(second.created && second.url != first.url);
        assert_eq!(names(&library).len(), 2);
        assert!(lut.exists() && clash.exists());
        assert!(matches!(
            MediaFileOps::collect_lut(&d.src.join("none.cube"), &library),
            Err(Failure::SourceMissing(_))
        ));
    }

    #[test]
    fn a_case_variant_redrop_keeps_the_file_a_stale_discard_would_delete() {
        let d = Dirs::new();
        let upper = d.src.join("IMG.MOV");
        write(&upper, 300, 1);
        let first = ingest(&upper, &d, ImportMode::Copy); // batch A creates IMG.MOV
        if !d.files.join("img.mov").exists() {
            return; // case-sensitive volume: n/a
        }
        let lower_dir = d.root.join("Other");
        assert!(fs::create_dir_all(&lower_dir).is_ok());
        let lower = lower_dir.join("img.mov");
        write(&lower, 300, 1); // identical, other spelling
        let again = ingest(&lower, &d, ImportMode::Copy);
        assert!(first.created && again.reused);
        MediaFileOps::discard_unlinked(std::slice::from_ref(&first)); // A's late discard
        assert!(first.url.exists(), "the re-drop's clips use this file");
        assert_eq!(MediaFileOps::identity_key(&first.url), MediaFileOps::identity_key(&d.files.join("img.mov")));
        MediaFileOps::discard_unlinked(std::slice::from_ref(&first));
        assert!(!first.url.exists());
    }

    #[test]
    fn a_library_file_a_collected_lut_reused_survives_the_batch_discard() {
        let d = Dirs::new();
        let library = d.root.join("Proj/Files/Library");
        let lut = d.src.join("look.cube");
        write(&lut, 200, 1);
        let batch = MediaFileOps::ingest_library_item(&lut, &library).unwrap_or_else(|e| panic!("{e}")); // a canceled batch's copy
        let twin = d.src.join("twin.cube");
        assert!(fs::copy(&lut, &twin).is_ok());
        assert_eq!(MediaFileOps::collect_lut(&twin, &library).map(|r| r.url), Ok(batch.url.clone())); // a grade now points at it
        MediaFileOps::discard_unlinked(std::slice::from_ref(&batch));
        assert!(batch.url.exists());
    }

    #[test]
    fn many_reused_marks_are_not_forgotten_at_once() {
        let d = Dirs::new();
        let a = d.src.join("a.mov");
        write(&a, 300, 1);
        let first = ingest(&a, &d, ImportMode::Copy);
        ingest(&a, &d, ImportMode::Copy); // marks `first`
        for i in 0..40u8 {
            // other files are reused too
            let f = d.src.join(format!("f{i}.mov"));
            write(&f, 50, i + 10);
            let r = ingest(&f, &d, ImportMode::Copy);
            ingest(&f, &d, ImportMode::Copy);
            MediaFileOps::discard_unlinked(std::slice::from_ref(&r)); // resolved: mark dropped
            assert!(r.url.exists());
        }
        MediaFileOps::discard_unlinked(std::slice::from_ref(&first));
        assert!(first.url.exists(), "its mark is still there");
    }

    #[test]
    fn failed_copy_leaves_the_original_and_no_folder_litter() {
        let d = Dirs::new();
        let r = MediaFileOps::ingest_library_item(&d.src.join("gone.mov"), &d.files);
        assert_eq!(r, Err(Failure::SourceMissing("gone.mov".into())));
        assert!(!d.files.exists());
    }

    #[test]
    fn stale_temporaries_older_than_an_hour_are_removed() {
        let d = Dirs::new();
        assert!(fs::create_dir_all(&d.files).is_ok());
        let (old, fresh, real) =
            (d.files.join(".a.mov.sqpart-1"), d.files.join(".b.mov.sqpart-2"), d.files.join("c.mov"));
        for u in [&old, &fresh, &real] {
            write(u, 10, 1);
        }
        let two_hours_ago = SystemTime::now() - Duration::from_secs(7200);
        for u in [&old, &real] {
            assert!(fs::OpenOptions::new().write(true).open(u).and_then(|f| f.set_modified(two_hours_ago)).is_ok());
        }
        assert_eq!(MediaFileOps::remove_stale_temporaries(&d.files, 3600.0, SystemTime::now()), 1);
        assert!(!old.exists() && fresh.exists() && real.exists());
    }

    #[test]
    fn a_failing_verification_leaves_no_temporary() {
        let d = Dirs::new();
        assert!(fs::create_dir_all(&d.files).is_ok());
        let s = d.src.join("a.mov");
        write(&s, 100, 1);
        let dest = d.files.join("a.mov");
        write(&dest, 100, 2);
        // The destination is taken: the copy is refused and its temporary file is gone.
        assert!(matches!(
            MediaFileOps::verified_copy(&s, &dest),
            Err(Failure::Io(std::io::ErrorKind::AlreadyExists, _))
        ));
        assert_eq!(names(&d.files), ["a.mov"]);
    }

    #[test]
    fn collect_copies_media_once_per_source_and_reports_failures() {
        let d = Dirs::new();
        let (a, b) = (d.src.join("a.mov"), d.src.join("b.mov"));
        write(&a, 100, 1);
        write(&b, 100, 2);
        let id = |n: u128| sq_core_time::Id::parse(&format!("{n:08X}-0000-0000-0000-000000000000"));
        let media: Vec<MediaRef> = [(1, &a), (2, &a), (3, &b)]
            .iter()
            .filter_map(|(n, p)| {
                Some(MediaRef::new(id(*n)?, "m", &p.to_string_lossy(), sq_core_model::MediaFingerprint::new(100)))
            })
            .collect();
        assert_eq!(media.len(), 3);
        let out = MediaFileOps::collect(&media, &d.files);
        assert!(out.failed.is_empty());
        assert_eq!(out.done.len(), 3);
        assert_eq!(out.done[0].destination, out.done[1].destination);
        assert_ne!(out.done[0].destination, out.done[2].destination);
        assert_eq!(names(&d.files), ["a.mov", "b.mov"]);
    }

    #[test]
    fn unique_name_counts_up_and_keeps_the_extension() {
        let taken: BTreeSet<&str> = ["a.mov", "a 2.mov", "b", "b 2"].into_iter().collect();
        assert_eq!(MediaManagement::unique_name("a.mov", |n| taken.contains(n)), "a 3.mov");
        assert_eq!(MediaManagement::unique_name("b", |n| taken.contains(n)), "b 3");
        assert_eq!(MediaManagement::unique_name("free.wav", |n| taken.contains(n)), "free.wav");
    }

    #[test]
    fn inside_is_component_wise_and_follows_dot_dot() {
        let d = Dirs::new();
        assert!(fs::create_dir_all(&d.files).is_ok());
        let p = |s: &str| d.files.join(s).to_string_lossy().into_owned();
        assert!(MediaManagement::is_inside(&p("x.mov"), &d.files));
        assert!(MediaManagement::is_inside(&p("sub/../x.mov"), &d.files));
        assert!(!MediaManagement::is_inside(&d.files.to_string_lossy(), &d.files));
        assert!(!MediaManagement::is_inside(&format!("{}2/x.mov", d.files.to_string_lossy()), &d.files));
        assert!(!MediaManagement::is_inside(&d.src.join("x.mov").to_string_lossy(), &d.files));
    }
}
