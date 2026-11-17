//! The user's Look file (`looks.json`): load, edit with a three-way merge, mirror the caption presets.

use std::collections::{BTreeMap, BTreeSet};
use std::fmt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};

use serde_json::{Value, json};
use sq_core_time::Id;
use sq_core_time::sha256_digest;
use sq_library::preset_store::{PresetItem, PresetKind, PresetStore, PresetStoreOrigin};
use sq_text::caption_presets::CaptionLookRegistry;
use sq_text::look::{Look, LookLibrary};
use sq_text::text_style::TextStyle;
use sq_transcribe::caption_preset::CaptionPreset;

use crate::es05_captions_titles::CaptionLookPayload;

/// Why a Look edit did not happen.
// Swift: LookStore.swift:30 (`StoreError`)
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum StoreError {
    /// The Look file cannot be written; the change stays in memory.
    ReadOnly,
    /// The Style Kit refused the Look.
    Look(String),
}

impl fmt::Display for StoreError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            StoreError::ReadOnly => f.write_str("The Look file cannot be written."),
            StoreError::Look(m) => f.write_str(m),
        }
    }
}

impl std::error::Error for StoreError {}

/// The Looks of the user, persisted as JSON (the app owns the one instance).
pub struct LookStore {
    state: Mutex<StoreState>,
    url: Option<PathBuf>,
    registry: Option<Arc<CaptionLookRegistry>>,
    /// The preset store whose `.caption` presets mirror the Looks: a Look deleted here takes its preset along.
    presets: Option<Arc<Mutex<PresetStore>>>,
    version: AtomicU64,
    write_failed: AtomicBool,
}

/// Mutable part of the store, behind the lock.
struct StoreState {
    lib: LookLibrary,
    imported: BTreeSet<String>,
    presets_seen: Option<BTreeMap<String, String>>,
    preset_looks: BTreeMap<String, String>,
    /// Looks this build cannot read, kept with their place so a write puts them back.
    unreadable: Vec<(usize, Value)>,
    unreadable_aliases: BTreeMap<String, String>,
    dirty: bool,
    writable: bool,
    failure_reported: bool,
    registered: BTreeSet<String>,
}

const TEXT_STYLES_SOURCE: &str = "text-styles";
const CAPTION_PRESETS_SOURCE: &str = "caption-presets";

impl LookStore {
    /// Name of the change message.
    // Swift: LookStore.swift:35
    pub const DID_CHANGE: &'static str = "sq.lookStore.didChange";
    /// Name of the message posted once when a write fails.
    // Swift: LookStore.swift:39
    pub const WRITE_FAILED: &'static str = "sq.lookStore.writeFailed";

    /// Opens the store at `url`; a damaged file is moved aside, an old text styles file is imported.
    // Swift: LookStore.swift:116
    // Swift: LookStore.swift:25 (the app-wide instance: the app builds one at `default_url`)
    pub fn new(
        url: Option<PathBuf>,
        legacy_text_styles: Option<PathBuf>,
        registry: Option<Arc<CaptionLookRegistry>>,
        presets: Option<Arc<Mutex<PresetStore>>>,
    ) -> LookStore {
        let mut st = StoreState {
            lib: LookLibrary::default(),
            imported: BTreeSet::new(),
            presets_seen: None,
            preset_looks: BTreeMap::new(),
            unreadable: Vec::new(),
            unreadable_aliases: BTreeMap::new(),
            dirty: false,
            writable: true,
            failure_reported: false,
            registered: BTreeSet::new(),
        };
        if let Some(u) = &url
            && let Ok(data) = std::fs::read(u)
            && !st.read(&data)
            && Self::move_aside(u).is_err()
        {
            // Damaged and not movable: leave it alone and write nothing.
            st.writable = false;
        }
        if let Some(legacy) = legacy_text_styles.filter(|_| st.writable && !st.imported.contains(TEXT_STYLES_SOURCE))
            && let Some(old) = std::fs::read(legacy).ok().and_then(|d| text_styles_in(&d))
        {
            st.merge(old);
            st.imported.insert(TEXT_STYLES_SOURCE.to_string());
            let _ = st.persist(url.as_deref());
        }
        let store = LookStore {
            state: Mutex::new(st),
            url,
            registry,
            presets,
            version: AtomicU64::new(0),
            write_failed: AtomicBool::new(false),
        };
        store.lock().sync_registry(store.registry.as_deref());
        store
    }

    fn lock(&self) -> MutexGuard<'_, StoreState> {
        self.state.lock().unwrap_or_else(|p| p.into_inner())
    }

    /// The caption Look registry this store mirrors its Looks into (the shared one without an own).
    pub fn registry(&self) -> &CaptionLookRegistry {
        self.registry.as_deref().unwrap_or_else(|| CaptionLookRegistry::shared())
    }

    /// Bumped by every change (Swift `didChange`).
    pub fn version(&self) -> u64 {
        self.version.load(Ordering::Relaxed)
    }

    /// True once after a write failed (Swift `writeFailed`); the app shows `read_only_message`.
    pub fn take_write_failure(&self) -> bool {
        self.write_failed.swap(false, Ordering::Relaxed)
    }

    /// Keeps a damaged file under another name.
    fn move_aside(url: &Path) -> std::io::Result<()> {
        let dir = url.parent().unwrap_or_else(|| Path::new("."));
        let name = url.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        let secs = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_secs());
        let base = format!("{name}.corrupt-{secs}");
        let mut target = dir.join(&base);
        let mut n = 1;
        while target.exists() {
            n += 1;
            target = dir.join(format!("{base}-{n}"));
        }
        std::fs::rename(url, target)
    }
    // Swift: LookStore.swift:42
    pub fn file_url(&self) -> Option<&Path> {
        self.url.as_deref()
    }
    // Swift: LookStore.swift:45
    pub fn read_only_message(&self) -> String {
        let place = self.url.as_ref().map(|u| format!(" ({})", u.display())).unwrap_or_default();
        format!(
            "Your Looks cannot be saved: the Look file{place} cannot be written. The change stays until you quit Sequence Studio."
        )
    }
    // Swift: LookStore.swift:49
    pub fn default_url(library_directory: &Path) -> PathBuf {
        library_directory.join("looks.json")
    }
    // Swift: LookStore.swift:51
    pub fn legacy_text_styles_url(library_directory: &Path) -> PathBuf {
        library_directory.join("text-styles.json")
    }
    // Swift: LookStore.swift:110
    pub fn is_loaded(&self) -> bool {
        self.lock().writable
    }
    // Swift: LookStore.swift:192
    pub fn library(&self) -> LookLibrary {
        self.lock().lib.clone()
    }
    /// Edits the library under the lock and saves it.
    // Swift: LookStore.swift:198
    pub fn edit<T>(&self, body: impl FnOnce(&mut LookLibrary) -> T) -> Result<T, StoreError> {
        self.change(body)
    }
    // Swift: LookStore.swift:206
    pub fn replace(&self, edited: LookLibrary, base: &LookLibrary) -> Result<(), StoreError> {
        self.change(|lib| *lib = three_way(base, &edited, lib))
    }
    /// Takes the preset store's `.caption` presets in (first call), then follows them: a preset added or changed since
    /// the last call adds or changes the Look under its id, a preset that is gone deletes it. A Look changed here is not
    /// touched while its preset stays the same.
    ///
    /// A Look is deleted only for a preset that is gone from a store that was read as it is, and only when the Look is
    /// still as the preset left it. A stand-in store (the real `presets.json` is from a newer build) changes nothing; a
    /// store that started empty after a damaged file deletes nothing and its lost presets are followed no more. A
    /// preset this build cannot read keeps its Look.
    // Swift: LookStore.swift:241
    // shortcut: sync (the Rust PresetStore has no async API), so the Swift `mirrored()` wait has nothing to wait for and
    // is not ported (Swift: LookStore.swift:338); a preset deleted with its Look is gone when `edit` returns.
    pub fn import_caption_presets(&self, store: Option<&PresetStore>) {
        let Some(store) = store.filter(|s| s.origin() != PresetStoreOrigin::StandIn) else { return };
        let mut presets: Vec<(Look, String)> = Vec::new();
        let mut undecodable: BTreeSet<String> = BTreeSet::new();
        for item in store.presets(Some(PresetKind::Caption), "") {
            let id = item.id.to_string();
            let payload = (item.payload_version <= CaptionLookPayload::VERSION)
                .then(|| serde_json::from_slice::<CaptionLookPayload>(&item.payload).ok())
                .flatten();
            let Some(p) = payload else {
                undecodable.insert(id);
                continue;
            };
            let mut look = Look::new(&id, &item.name, p.look.style);
            look.animation = Some(p.look.animation);
            look.caption_segmentation = p.segmentation.as_ref().and_then(Self::encode);
            look.category = self.category_of(&id).or(p.category);
            presets.push((look, digest_of(item.name.as_bytes(), &item.payload)));
        }
        let removals_are_real = store.origin() == PresetStoreOrigin::File;
        let _ = self.change_state(false, |st| st.follow(presets, &undecodable, removals_are_real));
    }

    /// The category a Look of this id has now (a rebuilt Look keeps it).
    fn category_of(&self, id: &str) -> Option<String> {
        self.lock().lib.user().iter().find(|l| l.id == id).and_then(|l| l.category.clone())
    }

    // Swift: LookStore.swift:317
    pub fn record_preset(&self, item: &PresetItem) {
        let _ = self.change_state(false, |st| {
            let Some(seen) = st.presets_seen.as_mut() else { return };
            let id = item.id.to_string();
            seen.insert(id.clone(), digest_of(item.name.as_bytes(), &item.payload));
            if let Some(look) = st.lib.user().iter().find(|l| l.id == id).cloned() {
                st.preset_looks.insert(id, look_digest(&look));
            }
            st.dirty = true;
        });
    }
    // Swift: LookStore.swift:328
    pub fn forget_preset(&self, id: Id) {
        let key = id.to_string();
        let _ = self.change_state(false, |st| {
            let known =
                st.presets_seen.as_ref().is_some_and(|s| s.contains_key(&key)) || st.preset_looks.contains_key(&key);
            if !known {
                return;
            }
            if let Some(s) = st.presets_seen.as_mut() {
                s.remove(&key);
            }
            st.preset_looks.remove(&key);
            st.dirty = true;
        });
    }
    // Swift: LookStore.swift:356
    pub fn encode(segmentation: &CaptionPreset) -> Option<Vec<u8>> {
        serde_json::to_vec(segmentation).ok()
    }
    // Swift: LookStore.swift:361
    pub fn segmentation(look: &Look) -> Option<CaptionPreset> {
        serde_json::from_slice(look.caption_segmentation.as_deref()?).ok()
    }

    /// Runs `body` on the library under the lock, saves when it changed, bumps `version`.
    fn change<T>(&self, body: impl FnOnce(&mut LookLibrary) -> T) -> Result<T, StoreError> {
        self.change_state(true, |st| body(&mut st.lib))
    }

    /// Like `change`, but `body` may touch the bookkeeping too (and set `dirty`). `mirror`: a followed Look that `body`
    /// deleted takes its `.caption` preset along.
    fn change_state<T>(&self, mirror: bool, body: impl FnOnce(&mut StoreState) -> T) -> Result<T, StoreError> {
        let mut st = self.lock();
        let before = st.lib.clone();
        let result = body(&mut st);
        let changed = st.lib != before;
        if let (true, true, Some(presets), Some(seen)) = (mirror, changed, &self.presets, &st.presets_seen) {
            // The digests stay until the next follow sees the presets gone: until then they keep it from adding the
            // Looks again.
            let gone = before
                .user()
                .iter()
                .filter(|l| seen.contains_key(&l.id) && st.lib.look(&l.id).is_none())
                .filter_map(|l| Id::parse(&l.id));
            let mut presets = presets.lock().unwrap_or_else(|p| p.into_inner());
            for id in gone {
                let _ = presets.delete(id);
            }
        }
        if !changed && !st.dirty {
            return Ok(result);
        }
        st.dirty = false;
        st.sync_registry(self.registry.as_deref());
        let outcome = st.persist(self.url.as_deref());
        if changed {
            self.version.fetch_add(1, Ordering::Relaxed);
        }
        match outcome {
            Ok(()) => {
                st.failure_reported = false;
                Ok(result)
            }
            Err(e) => {
                if !st.failure_reported {
                    self.write_failed.store(true, Ordering::Relaxed);
                }
                st.failure_reported = true;
                Err(e)
            }
        }
    }
}

impl StoreState {
    /// The Look under the preset's own id is now as the preset made it.
    fn note(&mut self, id: &str) {
        match self.lib.user().iter().find(|l| l.id == id).map(look_digest) {
            Some(d) => self.preset_looks.insert(id.to_string(), d),
            None => self.preset_looks.remove(id),
        };
    }

    /// The follow of `import_caption_presets`: `presets` are the decodable `.caption` presets as Looks with their digests.
    fn follow(&mut self, presets: Vec<(Look, String)>, undecodable: &BTreeSet<String>, removals_are_real: bool) {
        let mut now: BTreeMap<String, String> = BTreeMap::new();
        for (l, d) in &presets {
            now.entry(l.id.clone()).or_insert_with(|| d.clone());
        }
        if !self.imported.contains(CAPTION_PRESETS_SOURCE) {
            self.merge(presets.iter().map(|(l, _)| l.clone()).collect());
            self.imported.insert(CAPTION_PRESETS_SOURCE.to_string());
            for (l, _) in &presets {
                self.note(&l.id);
            }
            self.dirty = true;
        } else if let Some(seen) = self.presets_seen.clone() {
            for (look, digest) in &presets {
                if seen.get(&look.id) == Some(digest) {
                    continue;
                }
                if let Some(have) = self.lib.look(&look.id).filter(|h| !h.is_built_in) {
                    let untouched = self.preset_looks.get(&have.id) == Some(&look_digest(&have));
                    // The digest is "<name>.<payload>": only the part that changed is taken over. A preset that was
                    // merged into another Look (an alias) never renames that Look.
                    let was: Vec<&str> = seen.get(&look.id).map(|d| d.split('.').collect()).unwrap_or_default();
                    let new: Vec<&str> = digest.split('.').collect();
                    if was.len() != 2 || was[1] != new[1] {
                        self.lib.update(&have.id, |l| {
                            l.style = look.style.clone();
                            l.animation = look.animation.clone();
                            if let Some(s) = &look.caption_segmentation {
                                l.caption_segmentation = Some(s.clone());
                            }
                        });
                    }
                    if was.len() == 2 && was[0] != new[0] && have.id == look.id {
                        self.lib.rename(&have.id, &look.name);
                    }
                    // A Look edited here stays "edited" although part of it was just taken from the preset.
                    if untouched && have.id == look.id {
                        self.note(&have.id);
                    }
                } else if !seen.contains_key(&look.id) {
                    self.merge(vec![look.clone()]);
                    self.note(&look.id);
                }
                // Else the Look was deleted here: a later change of its preset does not bring it back.
            }
            for (id, digest) in &seen {
                if now.contains_key(id) {
                    continue;
                }
                if undecodable.contains(id) {
                    now.insert(id.clone(), digest.clone());
                } else if removals_are_real {
                    match self.lib.user().iter().find(|l| l.id == *id) {
                        Some(look) => {
                            if self.preset_looks.get(id) == Some(&look_digest(look)) {
                                self.lib.delete(id);
                            }
                        }
                        // Merged into another Look: only the old id stops resolving.
                        None => {
                            self.lib.delete(id);
                        }
                    }
                }
            }
        }
        if self.presets_seen.as_ref() != Some(&now) {
            self.presets_seen = Some(now.clone());
            self.dirty = true;
        }
        let followed: BTreeMap<String, String> = self
            .preset_looks
            .iter()
            .filter(|(k, _)| now.contains_key(*k))
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect();
        if followed != self.preset_looks {
            self.preset_looks = followed;
            self.dirty = true;
        }
    }

    /// Parses a Look file; false when it is damaged. A file in the old Text panel format is imported.
    fn read(&mut self, data: &[u8]) -> bool {
        let Ok(Value::Object(obj)) = serde_json::from_slice::<Value>(data) else { return false };
        if let Some(old) = text_styles_in(data) {
            // The file itself is in the old Text panel format (it has `styles`, a Look file has `looks`).
            self.merge(old);
            self.imported.insert(TEXT_STYLES_SOURCE.to_string());
            return true;
        }
        if obj.get("formatVersion").and_then(Value::as_i64).is_some_and(|v| v > LookLibrary::FORMAT_VERSION) {
            self.writable = false;
            return true;
        }
        let Some(raw) = obj.get("looks").and_then(Value::as_array) else { return false };
        let mut looks = Vec::new();
        let mut lost: BTreeSet<String> = BTreeSet::new();
        for (i, item) in raw.iter().enumerate() {
            match serde_json::from_value::<Look>(item.clone()) {
                Ok(l) => looks.push(l),
                Err(_) => {
                    self.unreadable.push((i, item.clone()));
                    if let Some(id) = item.get("id").and_then(Value::as_str) {
                        lost.insert(id.to_string());
                    }
                }
            }
        }
        let strings = |key: &str| -> BTreeMap<String, String> {
            obj.get(key)
                .and_then(Value::as_object)
                .map(|m| m.iter().filter_map(|(k, v)| v.as_str().map(|s| (k.clone(), s.to_string()))).collect())
                .unwrap_or_default()
        };
        let aliases = strings("aliases");
        self.lib = LookLibrary::new(looks, aliases.clone());
        self.unreadable_aliases = aliases.into_iter().filter(|(_, kept)| lost.contains(kept)).collect();
        self.imported = obj
            .get("imported")
            .and_then(Value::as_array)
            .map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_string)).collect())
            .unwrap_or_default();
        self.presets_seen = obj.get("captionPresets").and_then(Value::as_object).map(|_| strings("captionPresets"));
        self.preset_looks = strings("captionPresetLooks");
        true
    }

    /// Adds `incoming` Looks whose ids are not there yet (Swift `lib.merge`; the id source is not needed for ids that
    /// are already unique).
    fn merge(&mut self, incoming: Vec<Look>) {
        let mut ids = sq_core_time::SequentialIds::default();
        self.lib.merge(incoming, &mut ids);
    }

    fn persist(&self, url: Option<&Path>) -> Result<(), StoreError> {
        let Some(url) = url else { return Ok(()) };
        if !self.writable {
            return Err(StoreError::ReadOnly);
        }
        let mut obj = match sq_core_time::json_sorted::to_value(&self.lib) {
            Ok(Value::Object(o)) => o,
            _ => return Err(StoreError::ReadOnly),
        };
        obj.insert("imported".to_string(), json!(self.imported.iter().collect::<Vec<_>>()));
        if let Some(seen) = &self.presets_seen {
            obj.insert("captionPresets".to_string(), json!(seen));
        }
        if !self.preset_looks.is_empty() {
            obj.insert("captionPresetLooks".to_string(), json!(self.preset_looks));
        }
        if !self.unreadable.is_empty() {
            // Each one back where it stood (as far as the list still reaches), with the aliases that point at it.
            let mut looks = obj.get("looks").and_then(Value::as_array).cloned().unwrap_or_default();
            for (index, entry) in &self.unreadable {
                looks.insert((*index).min(looks.len()), entry.clone());
            }
            obj.insert("looks".to_string(), Value::Array(looks));
            if !self.unreadable_aliases.is_empty() {
                let mut aliases = obj.get("aliases").and_then(Value::as_object).cloned().unwrap_or_default();
                for (old, kept) in &self.unreadable_aliases {
                    if !aliases.contains_key(old) && self.lib.look(old).is_none() {
                        aliases.insert(old.clone(), json!(kept));
                    }
                }
                obj.insert("aliases".to_string(), Value::Object(aliases));
            }
        }
        let data = serde_json::to_vec_pretty(&Value::Object(obj)).map_err(|_| StoreError::ReadOnly)?;
        if let Some(dir) = url.parent() {
            std::fs::create_dir_all(dir).map_err(|_| StoreError::ReadOnly)?;
        }
        let tmp = url.with_extension("json.tmp");
        std::fs::write(&tmp, data).and_then(|()| std::fs::rename(&tmp, url)).map_err(|_| StoreError::ReadOnly)
    }

    fn sync_registry(&mut self, registry: Option<&CaptionLookRegistry>) {
        let Some(registry) = registry else { return };
        let mut want: BTreeMap<String, sq_text::caption_presets::CaptionLook> = BTreeMap::new();
        for l in self.lib.user() {
            want.insert(l.id.clone(), l.caption_look());
        }
        for (old, kept) in self.lib.aliases() {
            if let Some(l) = want.get(kept).cloned() {
                want.insert(old.clone(), l);
            }
        }
        for id in self.registered.iter().filter(|id| !want.contains_key(*id)) {
            registry.unregister(id);
        }
        for (id, look) in &want {
            registry.register(look.clone(), id);
        }
        self.registered = want.keys().cloned().collect();
    }
}

/// The Looks of an old text styles file (`formatVersion` 1), `None` for any other file.
fn text_styles_in(data: &[u8]) -> Option<Vec<Look>> {
    #[derive(serde::Deserialize)]
    struct Entry {
        id: String,
        name: String,
        style: TextStyle,
    }
    #[derive(serde::Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Legacy {
        format_version: i64,
        styles: Vec<Entry>,
    }
    let file: Legacy = serde_json::from_slice(data).ok()?;
    (file.format_version == 1)
        .then(|| file.styles.into_iter().map(|e| Look::new(&stable_id(&e.id), &e.name, e.style)).collect())
}

/// The id a Look made from an old text style gets: the first 16 bytes of the digest of `sq.text-style:<id>`.
pub(crate) fn stable_id(old_id: &str) -> String {
    let h = sha256_digest::hash(format!("sq.text-style:{old_id}").as_bytes());
    let mut v = [0u8; 16];
    v.copy_from_slice(&h[..16]);
    Id::from_u128(u128::from_be_bytes(v)).to_string()
}

fn hex8(data: &[u8]) -> String {
    sha256_digest::hash(data).iter().take(8).map(|b| format!("{b:02x}")).collect()
}

/// `<name digest>.<payload digest>` of a caption preset.
fn digest_of(name: &[u8], payload: &[u8]) -> String {
    format!("{}.{}", hex8(name), hex8(payload))
}

fn look_digest(look: &Look) -> String {
    serde_json::to_vec(look).map(|d| hex8(&d)).unwrap_or_default()
}

/// Merges the store's Looks (`theirs`) with an edited copy (`mine`) made from `base`: what the copy did not touch stays as
/// the store has it, what it added or changed is applied.
pub(crate) fn three_way(base: &LookLibrary, mine: &LookLibrary, theirs: &LookLibrary) -> LookLibrary {
    let before: BTreeMap<&str, &Look> = base.user().iter().map(|l| (l.id.as_str(), l)).collect();
    let current: BTreeMap<&str, &Look> = theirs.user().iter().map(|l| (l.id.as_str(), l)).collect();
    let mut out: Vec<Look> = Vec::new();
    let mut seen: BTreeSet<&str> = BTreeSet::new();
    for l in mine.user() {
        seen.insert(&l.id);
        if before.get(l.id.as_str()).is_some_and(|b| *b == l) {
            // Untouched in the copy: the store's Look wins (also when it was deleted there).
            if let Some(now) = current.get(l.id.as_str()) {
                out.push((*now).clone());
            }
        } else {
            out.push(l.clone());
        }
    }
    // Not in the copy: deleted by it when it had the Look, else new in the store.
    for l in theirs.user() {
        if !seen.contains(l.id.as_str()) && !before.contains_key(l.id.as_str()) {
            out.push(l.clone());
        }
    }
    // Aliases the same way: what the copy added, changed or removed against its base is applied to the store's.
    let mut aliases = theirs.aliases().clone();
    for (old, kept) in mine.aliases() {
        if base.aliases().get(old) != Some(kept) {
            aliases.insert(old.clone(), kept.clone());
        }
    }
    for old in base.aliases().keys() {
        if !mine.aliases().contains_key(old) {
            aliases.remove(old);
        }
    }
    LookLibrary::new(out, aliases)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn look(id: &str, name: &str) -> Look {
        Look::new(id, name, TextStyle::default())
    }

    #[test]
    fn the_store_writes_and_reads_its_looks_and_keeps_unreadable_ones() {
        let dir = std::env::temp_dir().join(format!("sq-looks-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let url = dir.join("looks.json");
        let store = LookStore::new(Some(url.clone()), None, None, None);
        let made = store
            .edit(|lib| lib.add("Warm", look("x", "Warm").values(), None, &mut sq_core_time::SequentialIds::default()));
        assert!(matches!(made, Ok(Some(_))));
        let again = LookStore::new(Some(url.clone()), None, None, None);
        assert_eq!(again.library().user().len(), 1);
        assert!(again.is_loaded());
        // A Look this build cannot read goes back into the file on the next write.
        let mut v: Value = serde_json::from_slice(&std::fs::read(&url).unwrap_or_default()).unwrap_or(Value::Null);
        if let Some(a) = v.get_mut("looks").and_then(Value::as_array_mut) {
            a.insert(0, json!({"id": "future", "name": "F", "style": 7}));
        }
        let _ = std::fs::write(&url, serde_json::to_vec(&v).unwrap_or_default());
        let third = LookStore::new(Some(url.clone()), None, None, None);
        assert_eq!(third.library().user().len(), 1);
        let _ = third.edit(|lib| lib.rename(&lib.user()[0].id.clone(), "Cool"));
        let text = std::fs::read_to_string(&url).unwrap_or_default();
        assert!(text.contains("future") && text.contains("Cool"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_newer_file_is_read_only() {
        let dir = std::env::temp_dir().join(format!("sq-looks-new-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let url = dir.join("looks.json");
        let _ = std::fs::write(&url, br#"{"formatVersion": 99, "looks": []}"#);
        let store = LookStore::new(Some(url), None, None, None);
        assert!(!store.is_loaded());
        assert!(matches!(
            store.edit(|lib| lib.add("A", look("a", "A").values(), None, &mut sq_core_time::SequentialIds::default())),
            Err(StoreError::ReadOnly)
        ));
        assert!(store.take_write_failure());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn three_way_keeps_store_changes_the_copy_did_not_touch() {
        let a = look("a", "A");
        let b = look("b", "B");
        let base = LookLibrary::new(vec![a.clone(), b.clone()], BTreeMap::new());
        // The copy renames A and deletes B; the store meanwhile renamed B and added C.
        let mut mine = base.clone();
        mine.rename("a", "A2");
        mine.delete("b");
        let theirs = LookLibrary::new(vec![a.clone(), look("b", "B2"), look("c", "C")], BTreeMap::new());
        let merged = three_way(&base, &mine, &theirs);
        let names: Vec<&str> = merged.user().iter().map(|l| l.name.as_str()).collect();
        assert_eq!(names, vec!["A2", "C"]);
    }

    use sq_core_model::anchored_animation::KeyframeTemplate;
    use sq_core_time::Timestamp;
    use sq_text::caption_presets::CaptionLook;

    fn sized(size: f64) -> TextStyle {
        TextStyle { size, ..TextStyle::default() }
    }

    fn temp(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("sq-looks-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let _ = std::fs::create_dir_all(&dir);
        dir
    }

    fn open(dir: &Path, stand_in: bool) -> PresetStore {
        match PresetStore::open(dir, stand_in, Timestamp::from_unix_seconds(5.0)) {
            Ok(s) => s,
            Err(e) => panic!("preset store: {e:?}"),
        }
    }

    fn item(n: u128, name: &str, style: TextStyle) -> PresetItem {
        let look = CaptionLook { style, animation: KeyframeTemplate::none() };
        let payload = CaptionLookPayload::new(look, Some(CaptionPreset::short_video()), None);
        PresetItem::new(
            Id::from_u128(n),
            PresetKind::Caption,
            name,
            Timestamp::from_unix_seconds(n as f64),
            serde_json::to_vec(&payload).unwrap_or_default(),
            CaptionLookPayload::VERSION,
        )
    }

    fn names(store: &LookStore) -> Vec<String> {
        store.library().user().iter().map(|l| l.name.clone()).collect()
    }

    #[test]
    fn caption_presets_are_followed_after_the_first_import() {
        let dir = temp("follow");
        let mut presets = open(&dir, false);
        let (a, b, c) = (Id::from_u128(1), Id::from_u128(2), Id::from_u128(3));
        let _ = presets.add(item(1, "A", sized(50.0)));
        let url = dir.join("looks.json");
        let store = LookStore::new(Some(url.clone()), None, None, None);
        store.import_caption_presets(Some(&presets));
        assert_eq!(names(&store), ["A"]);

        // A Look renamed here stays as it is while its preset does not change.
        let _ = store.edit(|lib| lib.rename(&a.to_string(), "Mine"));
        let _ = presets.add(item(2, "B", sized(90.0)));
        store.import_caption_presets(Some(&presets));
        assert_eq!(names(&store), ["Mine", "B"]);

        let _ = presets.update_payload(b, item(2, "B", sized(120.0)).payload, CaptionLookPayload::VERSION);
        store.import_caption_presets(Some(&presets));
        let look_b = store.library().look(&b.to_string());
        assert!(look_b.is_some_and(|l| l.style == sized(120.0) && l.name == "B"));
        let _ = presets.rename(b, "B2");
        store.import_caption_presets(Some(&presets));
        let look_b = store.library().look(&b.to_string());
        assert!(look_b.is_some_and(|l| l.style == sized(120.0) && l.name == "B2"));

        // A deleted preset takes its Look along unless the Look was edited here ("Mine").
        let _ = presets.add(item(3, "C", sized(50.0)));
        store.import_caption_presets(Some(&presets));
        let _ = presets.delete(a);
        let _ = presets.delete(c);
        store.import_caption_presets(Some(&presets));
        assert_eq!(names(&store), ["Mine", "B2"]);
        let _ = store.edit(|lib| lib.delete(&a.to_string()));
        // A Look the user deleted does not come back while its preset stays; a reopened store agrees.
        let _ = store.edit(|lib| lib.delete(&b.to_string()));
        store.import_caption_presets(Some(&presets));
        assert!(names(&store).is_empty());
        let reopened = LookStore::new(Some(url), None, None, None);
        reopened.import_caption_presets(Some(&presets));
        assert!(names(&reopened).is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn an_unreadable_preset_or_preset_store_deletes_no_look() {
        let dir = temp("unreadable");
        let mut presets = open(&dir, false);
        assert_eq!(presets.origin(), PresetStoreOrigin::File);
        let (b, c) = (Id::from_u128(2), Id::from_u128(3));
        for (n, name, size) in [(1, "A", 50.0), (2, "B", 90.0), (3, "C", 120.0)] {
            let _ = presets.add(item(n, name, sized(size)));
        }
        let url = dir.join("looks.json");
        let store = LookStore::new(Some(url.clone()), None, None, None);
        store.import_caption_presets(Some(&presets));
        assert_eq!(names(&store), ["A", "B", "C"]);

        // A preset from a newer build: its Look stays, here and after a restart.
        let _ = presets.update_payload(c, b"{\"future\":1}".to_vec(), CaptionLookPayload::VERSION + 1);
        store.import_caption_presets(Some(&presets));
        assert_eq!(names(&store), ["A", "B", "C"]);
        let again = LookStore::new(Some(url.clone()), None, None, None);
        again.import_caption_presets(Some(&presets));
        assert_eq!(names(&again), ["A", "B", "C"]);

        // The stand-in for a newer `presets.json` is empty: nothing changes, and the Looks are still followed afterwards.
        let other = temp("unreadable-other");
        let stand_in = open(&other, true);
        let before = std::fs::read(&url).unwrap_or_default();
        let third = LookStore::new(Some(url.clone()), None, None, None);
        third.import_caption_presets(Some(&stand_in));
        assert_eq!(names(&third), ["A", "B", "C"]);
        assert_eq!(std::fs::read(&url).unwrap_or_default(), before);
        let _ = presets.delete(b);
        let fourth = LookStore::new(Some(url.clone()), None, None, None);
        fourth.import_caption_presets(Some(&presets));
        assert_eq!(names(&fourth), ["A", "C"]);

        // A damaged `presets.json`: the store starts empty, the Looks stay; a later clean start agrees.
        let _ = std::fs::write(presets.file_url(), b"nope");
        let recovered = open(&dir, false);
        assert_eq!(recovered.origin(), PresetStoreOrigin::Recovered);
        let fifth = LookStore::new(Some(url.clone()), None, None, None);
        fifth.import_caption_presets(Some(&recovered));
        assert_eq!(names(&fifth), ["A", "C"]);
        let sixth = LookStore::new(Some(url), None, None, None);
        sixth.import_caption_presets(Some(&open(&dir, false)));
        assert_eq!(names(&sixth), ["A", "C"]);
        let _ = std::fs::remove_dir_all(&dir);
        let _ = std::fs::remove_dir_all(&other);
    }

    #[test]
    fn a_look_deleted_here_takes_its_followed_preset_along() {
        let dir = temp("mirror");
        let mut seeded = open(&dir, false);
        let _ = seeded.add(item(1, "A", sized(50.0)));
        let shared = Arc::new(Mutex::new(seeded));
        let store = LookStore::new(Some(dir.join("looks.json")), None, None, Some(Arc::clone(&shared)));
        store.import_caption_presets(Some(&shared.lock().unwrap_or_else(|p| p.into_inner())));
        assert_eq!(names(&store), ["A"]);
        let _ = store.edit(|lib| lib.delete(&Id::from_u128(1).to_string()));
        assert!(shared.lock().unwrap_or_else(|p| p.into_inner()).all().is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
