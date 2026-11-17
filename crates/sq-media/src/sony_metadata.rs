//! Port of `SQMedia/Sources/SQMedia/SonyMetadata.swift`.
//!
//! Sony NonRealTimeMeta (sidecar `<clip>M01.XML` or the `xml ` box embedded in the MP4). The XML is read with
//! `sq_prproj_reader::fastxml` (UTF-8 only; Foundation's `XMLParser` read other encodings too).

use std::collections::{BTreeMap, HashMap};
use std::fmt;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::SystemTime;

use sq_prproj_reader::container::Node;
use sq_prproj_reader::fastxml;

use crate::canon_metadata::{BOX_UUID, CameraMetadata};

/// Why Sony metadata could not be read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SonyMetadataError {
    /// The XML is not well formed.
    CorruptXml,
    /// The clip file could not be read (message of the system error).
    Io(String),
}

impl fmt::Display for SonyMetadataError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            SonyMetadataError::CorruptXml => f.write_str("The Sony metadata is not well formed."),
            SonyMetadataError::Io(why) => write!(f, "The clip could not be read: {why}"),
        }
    }
}

impl std::error::Error for SonyMetadataError {}

impl From<std::io::Error> for SonyMetadataError {
    fn from(e: std::io::Error) -> Self {
        SonyMetadataError::Io(e.to_string())
    }
}

/// Sony NonRealTimeMeta (sidecar `<clip>M01.XML` or the `xml ` box embedded in the MP4).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Default)]
pub struct SonyMetadata {
    pub capture_gamma: Option<String>,
    pub capture_color_primaries: Option<String>,
    pub coding_equations: Option<String>,
    pub model_name: Option<String>,
    pub related_lut_file: Option<String>,
}

/// What one walk over the MP4 boxes (top level, `moov`, `meta`) finds: Sony's `xml ` box, or Canon's maker notes
/// (`CMT3` inside Canon's `uuid` box in `moov`). The walk ends at the first of the two.
#[doc(hidden)]
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct EmbeddedBoxes {
    pub xml: Option<Vec<u8>>,
    pub canon_maker_notes: Option<Vec<u8>>,
}

struct Listing {
    modified: Option<SystemTime>,
    names: HashMap<String, String>,
}

static LISTINGS: Mutex<BTreeMap<String, Listing>> = Mutex::new(BTreeMap::new());
static LISTING_COUNT: AtomicUsize = AtomicUsize::new(0);

const MAX_PAYLOAD_BYTES: u64 = 1_048_576;

impl SonyMetadata {
    pub fn is_slog3_sgamut3_cine(&self) -> bool {
        self.capture_gamma.as_deref().is_some_and(|g| g.to_lowercase().starts_with("s-log3"))
            && self.capture_color_primaries.as_deref().map(str::to_lowercase).as_deref() == Some("s-gamut3-cine")
    }

    /// Parses the XML; Sony pads the embedded box with NUL bytes.
    pub fn from_xml(xml: &[u8]) -> Result<Self, SonyMetadataError> {
        let end = xml.iter().rposition(|&b| b != 0).map_or(0, |i| i + 1);
        let parsed = fastxml::parse(&xml[..end]).ok_or(SonyMetadataError::CorruptXml)?;
        let mut result = SonyMetadata::default();
        result.visit(&parsed.root);
        Ok(result)
    }

    fn visit(&mut self, node: &Node) {
        let local = node.name.rsplit(':').next().unwrap_or(&node.name);
        let a = &node.attributes;
        match local {
            "Item" => {
                let v = a.get("value").cloned();
                match a.get("name").map(String::as_str) {
                    Some("CaptureGammaEquation") => self.capture_gamma = v,
                    Some("CaptureColorPrimaries") => self.capture_color_primaries = v,
                    Some("CodingEquations") => self.coding_equations = v,
                    _ => {}
                }
            }
            "Device" => {
                if let Some(m) = a.get("modelName") {
                    self.model_name = Some(m.clone());
                }
            }
            "RelatedTo" if a.get("rel").map(String::as_str) == Some("LUT") && self.related_lut_file.is_none() => {
                self.related_lut_file = a.get("file").cloned();
            }
            _ => {}
        }
        for child in &node.children {
            self.visit(child);
        }
    }

    /// Sidecar first, then the XML embedded in the MP4. None if neither exists.
    pub fn read_for_clip(url: &Path) -> Result<Option<SonyMetadata>, SonyMetadataError> {
        if let Some(sidecar) = Self::sidecar_url(url) {
            // Bounded: a huge file named like the sidecar is not loaded.
            return CameraMetadata::sidecar_data(&sidecar).map(|d| Self::from_xml(&d)).transpose();
        }
        match Self::embedded_boxes(url)?.xml {
            Some(xml) => Self::from_xml(&xml).map(Some),
            None => Ok(None),
        }
    }

    #[doc(hidden)]
    pub fn sidecar_url(clip: &Path) -> Option<PathBuf> {
        let dir = clip.parent().unwrap_or(Path::new(""));
        let stem = clip.file_stem()?.to_string_lossy();
        let wanted = format!("{stem}M01.xml").to_lowercase();
        Self::listing(dir).get(&wanted).map(|name| dir.join(name))
    }

    /// Number of folder listings read so far (tests).
    #[doc(hidden)]
    pub fn directory_listings() -> usize {
        LISTING_COUNT.load(Ordering::Relaxed)
    }

    /// Lowercased name -> name of the files in `dir`. An import of a folder of N clips used to list the folder N times
    /// (O(N^2) names; 300 clips: a quarter of the probe time). Cached per folder and checked against the folder's
    /// modification date, so a sidecar copied in later is seen.
    #[doc(hidden)]
    pub fn listing(dir: &Path) -> HashMap<String, String> {
        let path = dir.to_string_lossy().into_owned();
        let modified = std::fs::metadata(dir).and_then(|m| m.modified()).ok();
        if let Ok(cache) = LISTINGS.lock()
            && let Some(hit) = cache.get(&path)
            && modified.is_some()
            && hit.modified == modified
        {
            return hit.names.clone();
        }
        LISTING_COUNT.fetch_add(1, Ordering::Relaxed);
        let mut names = HashMap::new();
        if let Ok(entries) = std::fs::read_dir(dir) {
            for entry in entries.flatten() {
                let n = entry.file_name().to_string_lossy().into_owned();
                names.entry(n.to_lowercase()).or_insert(n);
            }
        }
        if let Ok(mut cache) = LISTINGS.lock() {
            if cache.len() >= 32 {
                cache.clear();
            }
            cache.insert(path, Listing { modified, names: names.clone() });
        }
        names
    }

    // MARK: Box walking

    /// One walk over the MP4 boxes for Sony's embedded XML or Canon's maker notes.
    #[doc(hidden)]
    pub fn embedded_boxes(url: &Path) -> Result<EmbeddedBoxes, SonyMetadataError> {
        let mut fh = File::open(url)?;
        let end = fh.seek(SeekFrom::End(0))?;
        let mut found = EmbeddedBoxes::default();
        find(&mut fh, 0, end, 0, &mut found)?;
        Ok(found)
    }
}

struct MP4Box {
    kind: String,
    body: u64,
    end: u64,
}

/// Up to `n` bytes at `pos`; shorter at the end of the file.
fn read_at(fh: &mut File, pos: u64, n: u64) -> std::io::Result<Vec<u8>> {
    fh.seek(SeekFrom::Start(pos))?;
    let mut out = Vec::new();
    fh.take(n).read_to_end(&mut out)?;
    Ok(out)
}

fn mp4_box(fh: &mut File, pos: u64, end: u64) -> std::io::Result<Option<MP4Box>> {
    let h = read_at(fh, pos, 8)?;
    if h.len() != 8 {
        return Ok(None);
    }
    let mut size = u64::from(u32::from_be_bytes([h[0], h[1], h[2], h[3]]));
    let mut header = 8;
    if size == 1 {
        let l = read_at(fh, pos + 8, 8)?;
        if l.len() != 8 {
            return Ok(None);
        }
        size = l.iter().fold(0u64, |v, &b| v << 8 | u64::from(b));
        header = 16;
    } else if size == 0 {
        size = end - pos;
    }
    if size < header || size > end - pos {
        return Ok(None);
    }
    Ok(Some(MP4Box { kind: String::from_utf8_lossy(&h[4..8]).into_owned(), body: pos + header, end: pos + size }))
}

/// true = the walk is over (found, or the one box that could hold it is unusable).
fn find(fh: &mut File, start: u64, end: u64, depth: u32, found: &mut EmbeddedBoxes) -> std::io::Result<bool> {
    let mut pos = start;
    while pos + 8 <= end {
        let Some(b) = mp4_box(fh, pos, end)? else { return Ok(false) };
        if b.kind == "meta" && depth < 2 {
            // FullBox: skip 4 bytes version/flags.
            if find(fh, b.body + 4, b.end, depth + 1, found)? {
                return Ok(true);
            }
        } else if b.kind == "moov" && depth == 0 {
            if find(fh, b.body, b.end, depth + 1, found)? {
                return Ok(true);
            }
        } else if b.kind == "xml " && depth > 0 {
            if b.end <= b.body + 4 || b.end - b.body - 4 > MAX_PAYLOAD_BYTES {
                return Ok(true);
            }
            found.xml = Some(read_at(fh, b.body + 4, b.end - b.body - 4)?);
            return Ok(true);
        } else if b.kind == "uuid" && depth == 1 && b.end >= b.body + 16 && read_at(fh, b.body, 16)? == BOX_UUID {
            let mut p = b.body + 16;
            while p + 8 <= b.end {
                let Some(c) = mp4_box(fh, p, b.end)? else { break };
                if c.kind == "CMT3" {
                    if c.end <= c.body || c.end - c.body > MAX_PAYLOAD_BYTES {
                        return Ok(true);
                    }
                    found.canon_maker_notes = Some(read_at(fh, c.body, c.end - c.body)?);
                    return Ok(true);
                }
                p = c.end;
            }
            return Ok(true); // Canon's box without maker notes: nothing more to find in this file
        }
        pos = b.end;
    }
    Ok(false)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::MutexGuard;

    const FIXTURE_XML: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<NonRealTimeMeta xmlns="urn:schemas-professionalDisc:nonRealTimeMeta:ver.2.20" lastUpdate="2026-01-01T00:00:00+01:00">
<Device manufacturer="Sony" modelName="ZV-E1"/>
<AcquisitionRecord><Group name="CameraUnitMetadataSet">
<Item name="CaptureGammaEquation" value="s-log3-cine"/>
<Item name="CaptureColorPrimaries" value="s-gamut3-cine"/>
<Item name="CodingEquations" value="rec709"/>
</Group></AcquisitionRecord>
<RelevantFiles><RelatedTo file="Look.cube" rel="LUT"/></RelevantFiles>
</NonRealTimeMeta>"#;

    /// Tests that list folders run one at a time: the listing counter is global.
    static SERIAL: Mutex<()> = Mutex::new(());

    /// A fresh temp folder that goes away with the guard, plus the serial lock.
    struct TempDir {
        path: PathBuf,
        _lock: MutexGuard<'static, ()>,
    }

    impl TempDir {
        fn new() -> TempDir {
            static NEXT: AtomicUsize = AtomicUsize::new(0);
            let lock = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
            let path = std::env::temp_dir().join(format!(
                "sony-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            assert!(std::fs::create_dir_all(&path).is_ok());
            TempDir { path, _lock: lock }
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.path);
        }
    }

    fn mp4_box_bytes(kind: &str, payload: &[u8], large: bool) -> Vec<u8> {
        let mut d = Vec::new();
        if large {
            d.extend(1u32.to_be_bytes());
            d.extend(kind.as_bytes());
            d.extend((16 + payload.len() as u64).to_be_bytes());
        } else {
            d.extend((8 + payload.len() as u32).to_be_bytes());
            d.extend(kind.as_bytes());
        }
        d.extend(payload);
        d
    }

    fn fake_mp4(xml: Option<&str>, large: bool) -> Vec<u8> {
        let mut d = mp4_box_bytes("ftyp", b"isom0000", false);
        d.extend(mp4_box_bytes("mdat", &[0u8; 64], large));
        if let Some(xml) = xml {
            let xml_box = mp4_box_bytes("xml ", &[&[0u8; 4][..], xml.as_bytes()].concat(), large);
            let meta = [&[0u8; 4][..], &mp4_box_bytes("hdlr", &[0u8; 8], false), &xml_box].concat();
            d.extend(mp4_box_bytes("meta", &meta, large));
        }
        d
    }

    fn write(path: &Path, data: &[u8]) {
        assert!(std::fs::write(path, data).is_ok());
    }

    #[test]
    fn parses_fixture() {
        let m = SonyMetadata::from_xml(FIXTURE_XML.as_bytes()).unwrap_or_default();
        assert_eq!(m.capture_gamma.as_deref(), Some("s-log3-cine"));
        assert_eq!(m.capture_color_primaries.as_deref(), Some("s-gamut3-cine"));
        assert_eq!(m.coding_equations.as_deref(), Some("rec709"));
        assert_eq!(m.model_name.as_deref(), Some("ZV-E1"));
        assert_eq!(m.related_lut_file.as_deref(), Some("Look.cube"));
        assert!(m.is_slog3_sgamut3_cine());
    }

    #[test]
    fn missing_items() {
        let m = SonyMetadata::from_xml(b"<NonRealTimeMeta/>")
            .unwrap_or_else(|_| SonyMetadata { model_name: Some("err".into()), ..Default::default() });
        assert!(m.capture_gamma.is_none() && m.model_name.is_none() && m.related_lut_file.is_none());
        assert!(!m.is_slog3_sgamut3_cine());
    }

    #[test]
    fn malformed_throws() {
        assert_eq!(SonyMetadata::from_xml(b"<a><b></a>"), Err(SonyMetadataError::CorruptXml));
    }

    #[test]
    fn embedded_nul_padding_is_ignored() {
        let mut padded = FIXTURE_XML.as_bytes().to_vec();
        padded.extend([0, 0, 0]);
        assert!(SonyMetadata::from_xml(&padded).is_ok_and(|m| m.is_slog3_sgamut3_cine()));
    }

    #[test]
    fn embedded_read() {
        let dir = TempDir::new();
        for large in [false, true] {
            let f = dir.path.join(format!("A{large}.MP4"));
            write(&f, &fake_mp4(Some(FIXTURE_XML), large));
            assert_eq!(SonyMetadata::read_for_clip(&f).ok().flatten().map(|m| m.is_slog3_sgamut3_cine()), Some(true));
        }
    }

    #[test]
    fn no_meta_is_nil() {
        let dir = TempDir::new();
        let f = dir.path.join("B.MP4");
        write(&f, &fake_mp4(None, false));
        assert_eq!(SonyMetadata::read_for_clip(&f), Ok(None));
    }

    #[test]
    fn sidecar_wins() {
        let dir = TempDir::new();
        let f = dir.path.join("C0001.MP4");
        write(&f, &fake_mp4(Some(FIXTURE_XML), false));
        write(&dir.path.join("C0001M01.xml"), FIXTURE_XML.replace("s-log3-cine", "rec709").as_bytes());
        let m = SonyMetadata::read_for_clip(&f).ok().flatten();
        assert_eq!(m.and_then(|m| m.capture_gamma).as_deref(), Some("rec709"));
    }

    /// Import of a big folder: the folder is listed once, not once per clip; a sidecar written later is still seen.
    #[test]
    fn sidecar_lookup_lists_the_folder_once_and_sees_new_files() {
        let dir = TempDir::new();
        for i in 0..20 {
            write(&dir.path.join(format!("C{i}.MP4")), &fake_mp4(None, false));
        }
        let before = SonyMetadata::directory_listings();
        for i in 0..20 {
            assert_eq!(SonyMetadata::read_for_clip(&dir.path.join(format!("C{i}.MP4"))), Ok(None));
        }
        assert_eq!(SonyMetadata::directory_listings() - before, 1);
        // The folder's modification date must move for the cache to notice (coarse clocks): wait for a new timestamp.
        std::thread::sleep(std::time::Duration::from_millis(30));
        write(&dir.path.join("C3M01.XML"), FIXTURE_XML.as_bytes());
        for name in ["C3.MP4", "c3.mp4"] {
            let m = SonyMetadata::read_for_clip(&dir.path.join(name)).ok().flatten();
            assert_eq!(m.and_then(|m| m.capture_gamma).as_deref(), Some("s-log3-cine"));
        }
    }
}
