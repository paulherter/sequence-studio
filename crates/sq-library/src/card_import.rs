// Swift: CardImport.swift
//! Logic behind the "import from SD card / external drive" window. No UI: the app feeds it volume facts and shows the result.

use crate::library_item_kind::LibraryItemKind;
use crate::watched_folder::{DISTANT_PAST, standardized_path};
use sq_core_project::file_walk::{self, Step, Values};
use sq_core_time::{Timestamp, text::standard_compare};
use std::cmp::Ordering;
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

/// What a card file is.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum CardMediaKind {
    /// Movie.
    Video,
    /// Still image.
    Photo,
}

impl CardMediaKind {
    /// Every case.
    pub const ALL: [CardMediaKind; 2] = [CardMediaKind::Video, CardMediaKind::Photo];
}

/// One importable file found on a volume.
#[derive(Clone, Debug, PartialEq)]
pub struct CardCandidate {
    /// Full path.
    pub url: PathBuf,
    /// Video or photo.
    pub kind: CardMediaKind,
    /// Size in bytes.
    pub size: i64,
    /// Last content change.
    pub modified: Timestamp,
}

impl CardCandidate {
    /// The path as text (list identity).
    pub fn id(&self) -> String {
        self.url.to_string_lossy().into_owned()
    }

    /// File name.
    pub fn name(&self) -> String {
        crate::watched_folder::last_component(&self.url)
    }
}

/// Order of the candidate list.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum CardSort {
    /// Latest change first.
    NewestFirst,
    /// Oldest change first.
    OldestFirst,
    /// File name, digits by value.
    Name,
    /// Biggest first.
    Size,
}

impl CardSort {
    /// Every case.
    pub const ALL: [CardSort; 4] = [CardSort::NewestFirst, CardSort::OldestFirst, CardSort::Name, CardSort::Size];

    /// Shown name.
    pub fn title(self) -> &'static str {
        match self {
            CardSort::NewestFirst => "Newest first",
            CardSort::OldestFirst => "Oldest first",
            CardSort::Name => "Name",
            CardSort::Size => "Size",
        }
    }

    /// `items` in this order. Name is the tie-breaker everywhere so the order is stable between runs.
    pub fn apply(self, items: &[CardCandidate]) -> Vec<CardCandidate> {
        let mut out = items.to_vec();
        out.sort_by(|a, b| {
            let by_name = standard_compare(&a.name(), &b.name());
            let order = match self {
                CardSort::NewestFirst => b.modified.partial_cmp(&a.modified).unwrap_or(Ordering::Equal),
                CardSort::OldestFirst => a.modified.partial_cmp(&b.modified).unwrap_or(Ordering::Equal),
                CardSort::Name => Ordering::Equal,
                CardSort::Size => b.size.cmp(&a.size),
            };
            order.then(by_name)
        });
        out
    }
}

/// Facts about a mounted volume, read by the app.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct VolumeFacts {
    /// Mount point.
    pub url: PathBuf,
    /// Built into the computer.
    pub is_internal: bool,
    /// Removable media.
    pub is_removable: bool,
    /// Can be ejected.
    pub is_ejectable: bool,
    /// Not a network share.
    pub is_local: bool,
    /// Shown in the Finder.
    pub is_browsable: bool,
    /// A mounted .dmg / sparse image (DiskArbitration model "Disk Image"), not a physical device.
    pub is_disk_image: bool,
}

impl VolumeFacts {
    /// A local, browsable physical volume with the given flags.
    pub fn new(url: PathBuf, is_internal: bool, is_removable: bool, is_ejectable: bool) -> VolumeFacts {
        VolumeFacts {
            url,
            is_internal,
            is_removable,
            is_ejectable,
            is_local: true,
            is_browsable: true,
            is_disk_image: false,
        }
    }

    /// An SD card or external drive, not the boot disk, a network share or an internal partition.
    pub fn is_import_source(&self) -> bool {
        if !self.is_local || !self.is_browsable || self.is_disk_image {
            return false;
        }
        let path = standardized_path(&self.url);
        if !path.starts_with("/Volumes/") || path.chars().count() <= "/Volumes/".len() {
            return false;
        }
        self.is_removable || self.is_ejectable || !self.is_internal
    }
}

/// What kind of drive Windows reports.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DriveKind {
    /// Card reader or stick.
    Removable,
    /// Fixed disk (also USB SSDs).
    Fixed,
    /// Network share, optical.
    Other,
}

/// The storage bus of a drive.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DriveBus {
    /// USB.
    Usb,
    /// FireWire.
    Firewire,
    /// SD.
    Sd,
    /// MMC.
    Mmc,
    /// Anything else.
    Other,
}

/// A Windows drive letter, read by the Windows app (GetDriveTypeW, the storage bus from IOCTL_STORAGE_QUERY_PROPERTY).
/// The Windows counterpart of `VolumeFacts`: USB and Thunderbolt SSDs report DRIVE_FIXED, so the bus decides.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DriveFacts {
    /// "E:\\".
    pub root: String,
    /// Drive type.
    pub kind: DriveKind,
    /// Storage bus.
    pub bus: DriveBus,
    /// The drive Windows runs from.
    pub is_system: bool,
}

impl DriveFacts {
    /// A drive on no particular bus that is not the system drive.
    pub fn new(root: &str, kind: DriveKind) -> DriveFacts {
        DriveFacts { root: root.to_string(), kind, bus: DriveBus::Other, is_system: false }
    }

    /// A card, stick or external disk on USB, FireWire, SD or MMC; never the system drive, an internal disk, a share.
    pub fn is_import_source(&self) -> bool {
        if self.is_system {
            return false;
        }
        match self.kind {
            DriveKind::Removable => true,
            DriveKind::Fixed => self.bus != DriveBus::Other,
            DriveKind::Other => false,
        }
    }
}

/// New drives since the last look (the Mac reacts to new mounts only: what is there at launch is not offered).
#[derive(Clone, Debug)]
pub struct DriveArrivals {
    known: BTreeSet<String>,
}

/// What changed between two looks at the drives.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DriveChange {
    /// New import sources.
    pub added: Vec<String>,
    /// Drives that went away.
    pub removed: Vec<String>,
}

impl DriveArrivals {
    /// Starts from the drives present now (they are not reported as added).
    pub fn new(present: &[DriveFacts]) -> DriveArrivals {
        DriveArrivals { known: present.iter().map(|d| d.root.clone()).collect() }
    }

    /// `now`: the ready drives. Added = new import sources, removed = drives that went away (sorted).
    pub fn update(&mut self, now: &[DriveFacts]) -> DriveChange {
        let roots: BTreeSet<String> = now.iter().map(|d| d.root.clone()).collect();
        let added = now
            .iter()
            .filter(|d| !self.known.contains(&d.root) && d.is_import_source())
            .map(|d| d.root.clone())
            .collect();
        let removed = self.known.difference(&roots).cloned().collect();
        self.known = roots;
        DriveChange { added, removed }
    }
}

/// Finds the photos and videos on a volume.
pub struct CardScanner;

impl CardScanner {
    /// Photos and videos below `root`, all subfolders flat. Hidden files (including the `._` copies macOS writes on
    /// FAT cards) and packages are skipped; everything that is neither photo nor video is left out.
    pub fn scan(root: &Path, kinds: &BTreeSet<CardMediaKind>) -> Vec<CardCandidate> {
        let mut out = Vec::new();
        file_walk::walk(root, &mut |url, values, _| {
            let Some(v) = values else { return Step::Descend };
            let Some(kind) = Self::kind(url).filter(|k| kinds.contains(k)) else { return Step::Descend };
            if v.is_regular_file == Some(true) {
                out.push(CardCandidate {
                    url: url.to_path_buf(),
                    kind,
                    size: v.file_size.unwrap_or(0),
                    modified: v.content_modification_date.unwrap_or(DISTANT_PAST),
                });
            }
            Step::Descend
        });
        out
    }

    /// Photo or video by extension; `None` for anything else.
    pub fn kind(path: &Path) -> Option<CardMediaKind> {
        match LibraryItemKind::classify_if_visible(path, false) {
            Some(LibraryItemKind::Video) => Some(CardMediaKind::Video),
            Some(LibraryItemKind::Image) => Some(CardMediaKind::Photo),
            _ => None,
        }
    }

    /// Destination for a copied file: `folder/name`, or `name 2.ext`, `name 3.ext` when taken.
    pub fn unique_destination(name: &str, folder: &Path, taken: &dyn Fn(&Path) -> bool) -> PathBuf {
        let first = folder.join(name);
        if !taken(&first) {
            return first;
        }
        let path = Path::new(name);
        let ext = path.extension().map(|e| e.to_string_lossy().into_owned()).unwrap_or_default();
        let stem = path.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
        let mut n = 2;
        loop {
            let file = if ext.is_empty() { format!("{stem} {n}") } else { format!("{stem} {n}.{ext}") };
            let candidate = folder.join(file);
            if !taken(&candidate) {
                return candidate;
            }
            n += 1;
        }
    }
}

/// Multi-selection over an ordered list: click, Command/checkbox toggle, Shift range.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct CardSelection {
    ids: BTreeSet<String>,
    anchor: Option<String>,
}

impl CardSelection {
    /// Nothing selected.
    pub fn new() -> CardSelection {
        CardSelection::default()
    }

    /// The selected ids.
    pub fn ids(&self) -> &BTreeSet<String> {
        &self.ids
    }

    /// The id a Shift range starts from.
    pub fn anchor(&self) -> Option<&str> {
        self.anchor.as_deref()
    }

    /// A click on `id`; `shift` extends from the anchor, `toggle` adds or removes.
    pub fn click(&mut self, id: &str, order: &[String], shift: bool, toggle: bool) {
        let position = |x: &str| order.iter().position(|o| o == x);
        let range = self.anchor.as_deref().and_then(position).zip(position(id));
        if let (true, Some((i, j))) = (shift, range) {
            let span = order[i.min(j)..=i.max(j)].iter().cloned();
            if toggle {
                self.ids.extend(span);
            } else {
                self.ids = span.collect();
            }
        } else if toggle {
            if !self.ids.insert(id.to_string()) {
                self.ids.remove(id);
            }
            self.anchor = Some(id.to_string());
        } else {
            self.ids = BTreeSet::from([id.to_string()]);
            self.anchor = Some(id.to_string());
        }
    }

    /// Selects everything.
    pub fn select_all(&mut self, order: &[String]) {
        self.ids = order.iter().cloned().collect();
        self.anchor = order.last().cloned();
    }

    /// Selects nothing.
    pub fn clear(&mut self) {
        self.ids.clear();
        self.anchor = None;
    }

    /// Removes `remove` from the selection.
    pub fn deselect(&mut self, remove: &BTreeSet<String>) {
        self.ids = self.ids.difference(remove).cloned().collect();
        if self.anchor.as_ref().is_some_and(|a| remove.contains(a)) {
            self.anchor = self.ids.iter().next().cloned();
        }
    }

    /// Drops ids no longer listed (after a kind switch or rescan).
    pub fn prune(&mut self, order: &[String]) {
        self.ids.retain(|i| order.contains(i));
        if self.anchor.as_ref().is_some_and(|a| !self.ids.contains(a)) {
            self.anchor = self.ids.iter().next().cloned();
        }
    }
}

/// What a copy run did.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct CardCopyResult {
    /// Destination files.
    pub copied: Vec<PathBuf>,
    /// File names that failed.
    pub failed: Vec<String>,
    /// Sources whose copy failed or was incomplete.
    pub failed_sources: Vec<PathBuf>,
    /// Sources that were copied completely, in the order of `copied`.
    pub copied_sources: Vec<PathBuf>,
}

/// Copies card files into a folder.
pub struct CardCopier;

impl CardCopier {
    /// `copy_with` that copies through the file system.
    pub fn copy(sources: &[PathBuf], folder: &Path, progress: &mut dyn FnMut(usize, usize)) -> CardCopyResult {
        Self::copy_with(sources, folder, progress, &mut |from, to| std::fs::copy(from, to).map(|_| ()))
    }

    /// Copies each source into `folder` (created if missing) under a unique name. Never fails: failures are listed.
    /// `progress(done, total)` is called before each file.
    pub fn copy_with(
        sources: &[PathBuf],
        folder: &Path,
        progress: &mut dyn FnMut(usize, usize),
        copy_item: &mut dyn FnMut(&Path, &Path) -> std::io::Result<()>,
    ) -> CardCopyResult {
        let mut result = CardCopyResult::default();
        if std::fs::create_dir_all(folder).is_err() {
            result.failed = sources.iter().map(|s| crate::watched_folder::last_component(s)).collect();
            result.failed_sources = sources.to_vec();
            return result;
        }
        for (i, src) in sources.iter().enumerate() {
            progress(i, sources.len());
            let name = crate::watched_folder::last_component(src);
            let target = CardScanner::unique_destination(&name, folder, &|p| p.exists());
            let size = |p: &Path| Values::read(p).and_then(|v| v.file_size);
            let copied = copy_item(src, &target).is_ok() && {
                // A card pulled mid-copy can leave a short file without an error: verify the size.
                let (want, got) = (size(src).unwrap_or(-1), size(&target).unwrap_or(-2));
                let same = want == got;
                if !same {
                    let _ = std::fs::remove_file(&target);
                }
                same
            };
            if copied {
                result.copied.push(target);
                result.copied_sources.push(src.clone());
            } else {
                result.failed.push(name);
                result.failed_sources.push(src.clone());
            }
        }
        progress(sources.len(), sources.len());
        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::folder_scanner::test_dir::TempDir;
    use sq_core_time::Timestamp;

    fn all() -> BTreeSet<CardMediaKind> {
        CardMediaKind::ALL.into_iter().collect()
    }

    fn names(list: &[CardCandidate]) -> Vec<String> {
        list.iter().map(CardCandidate::name).collect()
    }

    fn strings(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| (*s).to_string()).collect()
    }

    #[test]
    fn scan_is_recursive_flat_and_filters_kinds() {
        let t = TempDir::new();
        for f in
            ["DCIM/100/a.MOV", "DCIM/101/deep/b.jpg", "c.mp4", "notes.txt", "song.wav", "DCIM/.hidden.mov", "._d.mov"]
        {
            t.write(f, 4);
        }
        let found: BTreeSet<String> = names(&CardScanner::scan(t.path(), &all())).into_iter().collect();
        assert_eq!(found, strings(&["a.MOV", "b.jpg", "c.mp4"]).into_iter().collect());
        assert_eq!(names(&CardScanner::scan(t.path(), &BTreeSet::from([CardMediaKind::Photo]))), ["b.jpg"]);
        let videos: BTreeSet<String> =
            names(&CardScanner::scan(t.path(), &BTreeSet::from([CardMediaKind::Video]))).into_iter().collect();
        assert_eq!(videos, strings(&["a.MOV", "c.mp4"]).into_iter().collect());
    }

    #[test]
    fn scan_lists_a_3_gib_clip_with_its_size() {
        let t = TempDir::new();
        let clip = t.write("DCIM/100OPPO/C2171.MP4", 0);
        if let Ok(f) = std::fs::OpenOptions::new().write(true).open(&clip) {
            let _ = f.set_len(3_288_967_572); // sparse where the file system allows it
        }
        let found = CardScanner::scan(t.path(), &all());
        assert_eq!(names(&found), ["C2171.MP4"]);
        assert_eq!(found.first().map(|c| c.size), Some(3_288_967_572));
        assert_eq!(found.first().map(|c| c.modified > DISTANT_PAST), Some(true));
    }

    #[test]
    fn sort_orders() {
        let c = |n: &str, s: i64, off: f64| CardCandidate {
            url: PathBuf::from(format!("/x/{n}")),
            kind: CardMediaKind::Video,
            size: s,
            modified: Timestamp::from_unix_seconds(1000.0 + off),
        };
        let items = [c("b.mov", 5, 10.0), c("a.mov", 9, 30.0), c("c10.mov", 1, 20.0), c("c9.mov", 1, 20.0)];
        assert_eq!(names(&CardSort::NewestFirst.apply(&items)), ["a.mov", "c9.mov", "c10.mov", "b.mov"]);
        assert_eq!(names(&CardSort::OldestFirst.apply(&items)), ["b.mov", "c9.mov", "c10.mov", "a.mov"]);
        assert_eq!(names(&CardSort::Name.apply(&items)), ["a.mov", "b.mov", "c9.mov", "c10.mov"]);
        assert_eq!(names(&CardSort::Size.apply(&items)), ["a.mov", "b.mov", "c9.mov", "c10.mov"]);
    }

    #[test]
    fn volume_detection() {
        let v = |p: &str, int: bool, rem: bool, ej: bool, local: bool| VolumeFacts {
            is_local: local,
            ..VolumeFacts::new(PathBuf::from(p), int, rem, ej)
        };
        assert!(v("/Volumes/SD", false, true, true, true).is_import_source());
        assert!(v("/Volumes/SSD", false, false, false, true).is_import_source());
        assert!(v("/Volumes/Cam", true, true, false, true).is_import_source());
        assert!(!v("/", true, false, false, true).is_import_source());
        assert!(!v("/Volumes/Macintosh HD", true, false, false, true).is_import_source());
        assert!(!v("/Volumes/NAS", false, false, false, false).is_import_source());
        assert!(!v("/System/Volumes/Data", false, false, false, true).is_import_source());
        let image = VolumeFacts {
            is_disk_image: true,
            ..VolumeFacts::new(PathBuf::from("/Volumes/Installer"), false, false, true)
        };
        assert!(!image.is_import_source());
    }

    #[test]
    fn selection() {
        let order = strings(&["a", "b", "c", "d", "e"]);
        let set = |l: &[&str]| l.iter().map(|s| (*s).to_string()).collect::<BTreeSet<_>>();
        let mut s = CardSelection::new();
        s.click("b", &order, false, false);
        assert_eq!(s.ids(), &set(&["b"]));
        s.click("d", &order, true, false);
        assert_eq!(s.ids(), &set(&["b", "c", "d"]));
        s.click("a", &order, false, true);
        assert_eq!(s.ids(), &set(&["a", "b", "c", "d"]));
        s.click("b", &order, false, true);
        assert_eq!(s.ids(), &set(&["a", "c", "d"]));
        s.prune(&strings(&["a", "c"]));
        assert_eq!(s.ids(), &set(&["a", "c"]));
        s.select_all(&order);
        assert_eq!(s.ids().len(), 5);
        s.deselect(&set(&["a"]));
        assert_eq!(s.ids(), &set(&["b", "c", "d", "e"]));
        s.clear();
        assert!(s.ids().is_empty());
    }

    #[test]
    fn unique_destination() {
        let f = Path::new("/dest");
        let taken = |p: &Path| {
            ["/dest/a.mov", "/dest/a 2.mov", "/dest/raw"].contains(&p.to_string_lossy().replace('\\', "/").as_str())
        };
        let file = |n: &str| crate::watched_folder::last_component(&CardScanner::unique_destination(n, f, &taken));
        assert_eq!(file("a.mov"), "a 3.mov");
        assert_eq!(file("b.mov"), "b.mov");
        assert_eq!(file("raw"), "raw 2");
    }

    #[test]
    fn copier_copies_with_unique_names_and_reports_failures() {
        let (src, dst) = (TempDir::new(), TempDir::new());
        let a = src.write("100/clip.mov", 10);
        let b = src.write("101/clip.mov", 20);
        let missing = src.path().join("gone.mov");
        let mut ticks = Vec::new();
        let r =
            CardCopier::copy(&[a.clone(), b.clone(), missing.clone()], &dst.path().join("Media"), &mut |done, _| {
                ticks.push(done)
            });
        assert_eq!(names_of(&r.copied), ["clip.mov", "clip 2.mov"]);
        assert_eq!(r.failed, ["gone.mov"]);
        assert_eq!(ticks, [0, 1, 2, 3]);
        assert_eq!(std::fs::metadata(&r.copied[1]).map(|m| m.len()).ok(), Some(20));
        assert_eq!(r.copied_sources, [a, b]);
        assert_eq!(r.failed_sources, [missing]);
    }

    fn names_of(paths: &[PathBuf]) -> Vec<String> {
        paths.iter().map(|p| crate::watched_folder::last_component(p)).collect()
    }

    #[test]
    fn copier_rejects_short_copy_and_removes_it() {
        let (src, dst) = (TempDir::new(), TempDir::new());
        let a = src.write("a.mov", 100);
        let b = src.write("b.mov", 100);
        // Simulates the card being pulled during a.mov: only half arrives, no error.
        let mut half = |from: &Path, to: &Path| {
            let data = std::fs::read(from)?;
            let cut = if from.ends_with("a.mov") { 50 } else { data.len() };
            std::fs::write(to, &data[..cut])
        };
        let r = CardCopier::copy_with(&[a.clone(), b.clone()], dst.path(), &mut |_, _| {}, &mut half);
        assert_eq!(r.failed_sources, [a]);
        assert_eq!(r.copied_sources, [b]);
        assert!(!dst.path().join("a.mov").exists());
    }

    #[test]
    fn windows_drives_offer_cards_and_usb_disks_but_not_the_system_or_internal_disks() {
        let d = |root: &str, kind, bus, system| DriveFacts { root: root.into(), kind, bus, is_system: system };
        use DriveBus as B;
        use DriveKind as K;
        assert!(d("E:\\", K::Removable, B::Other, false).is_import_source());
        assert!(d("F:\\", K::Fixed, B::Usb, false).is_import_source());
        assert!(
            d("G:\\", K::Fixed, B::Sd, false).is_import_source()
                && d("G:\\", K::Fixed, B::Mmc, false).is_import_source()
        );
        assert!(d("H:\\", K::Fixed, B::Firewire, false).is_import_source());
        assert!(!d("D:\\", K::Fixed, B::Other, false).is_import_source());
        assert!(!d("C:\\", K::Fixed, B::Usb, true).is_import_source());
        assert!(!d("Z:\\", K::Other, B::Other, false).is_import_source());
    }

    #[test]
    fn drive_arrivals_offer_only_new_import_sources_and_report_removals() {
        let c = DriveFacts { is_system: true, ..DriveFacts::new("C:\\", DriveKind::Fixed) };
        let ssd = DriveFacts { bus: DriveBus::Usb, ..DriveFacts::new("F:\\", DriveKind::Fixed) };
        let card = DriveFacts::new("E:\\", DriveKind::Removable);
        let disk = DriveFacts::new("D:\\", DriveKind::Fixed);
        let change =
            |added: &[&str], removed: &[&str]| DriveChange { added: strings(added), removed: strings(removed) };
        let mut w = DriveArrivals::new(&[c.clone(), card.clone()]);
        assert_eq!(w.update(&[c.clone(), card.clone()]), change(&[], &[]));
        assert_eq!(w.update(&[c.clone(), card.clone(), ssd.clone(), disk.clone()]), change(&["F:\\"], &[]));
        assert_eq!(w.update(&[c.clone(), ssd.clone(), disk.clone()]), change(&[], &["E:\\"]));
        assert_eq!(w.update(&[c, ssd, disk, card]), change(&["E:\\"], &[]));
    }
}
