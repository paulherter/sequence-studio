//! When and with what a file was shot (Swift `ShootMetadata`): the container creation date and the camera model. Feeds
//! the Project panel's camera / day filters. Best-effort: `None` on any error.
//! The date comes from the MP4/MOV `mvhd` box, the model from Sony's metadata, else the QuickTime `model` / `make` keys
//! (`moov/meta` keys + ilst, `moov/udta` atoms "(c)mod" and "(c)mak"), else the make. Stills: `exif`.

use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

/// Seconds between 1904-01-01 (QuickTime epoch) and 1970-01-01.
const QUICKTIME_TO_UNIX: u64 = 2_082_844_800;

/// What one file says about its shoot.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ShootResult {
    /// Creation time, seconds since 1970-01-01 UTC.
    pub created_unix: Option<f64>,
    /// Camera model, trimmed; `None` when blank.
    pub camera_model: Option<String>,
}

/// Reader namespace.
pub struct ShootMetadata;

impl ShootMetadata {
    /// `sony_model`: the model the import already got from Sony's metadata.
    pub fn read(path: &Path, sony_model: Option<&str>) -> ShootResult {
        if crate::still_image::is_still(path) {
            let e = crate::exif::read_exif(path);
            return ShootResult { created_unix: e.created_unix, camera_model: clean(e.camera_model.as_deref()) };
        }
        let model = clean(sony_model).or_else(|| {
            let (model, make) = quicktime_make_model(path);
            model.or(make)
        });
        ShootResult { created_unix: creation_unix(path), camera_model: model }
    }
}

/// The boxes of one level: (kind, body).
fn boxes(mut b: &[u8]) -> Vec<([u8; 4], &[u8])> {
    let mut out = Vec::new();
    while b.len() >= 8 {
        let size = u32::from_be_bytes([b[0], b[1], b[2], b[3]]) as usize;
        let kind = [b[4], b[5], b[6], b[7]];
        let size = if size == 0 { b.len() } else { size };
        if size < 8 || size > b.len() {
            break;
        }
        out.push((kind, &b[8..size]));
        b = &b[size..];
    }
    out
}

/// A `meta` body: a FullBox (4 bytes of version and flags) in MP4 and in Apple's `moov/meta`; QuickTime's `udta/meta`
/// can start with its `hdlr` child directly.
fn meta_children(body: &[u8]) -> &[u8] {
    if body.get(4..8) == Some(b"hdlr") { body } else { body.get(4..).unwrap_or_default() }
}

fn text_of(b: &[u8]) -> Option<String> {
    Some(String::from_utf8_lossy(b).into_owned())
}

/// (model, make) of the QuickTime metadata of a MOV / MP4 (what AVFoundation lists as common keys `model` and `make`).
fn quicktime_make_model(path: &Path) -> (Option<String>, Option<String>) {
    let Some(moov) = read_moov(path) else { return (None, None) };
    let (mut model, mut make) = (None, None);
    let mut keyed = |name: &str, value: Option<String>| {
        let n = name.to_lowercase();
        if n.ends_with("model") && model.is_none() {
            model = clean(value.as_deref());
        } else if n.ends_with("make") && make.is_none() {
            make = clean(value.as_deref());
        }
    };
    for (kind, body) in boxes(&moov) {
        match &kind {
            b"meta" => keyed_items(meta_children(body), &mut keyed),
            b"udta" => {
                for (k, b) in boxes(body) {
                    match &k {
                        b"meta" => keyed_items(meta_children(b), &mut keyed),
                        // The old atoms: 2 bytes of length, 2 of language, then the text.
                        [0xA9, b'm', b'a', b'k'] => keyed("make", b.get(4..).and_then(text_of)),
                        [0xA9, b'm', b'o', b'd'] => keyed("model", b.get(4..).and_then(text_of)),
                        _ => {}
                    }
                }
            }
            _ => {}
        }
    }
    (model, make)
}

/// The `keys` names and the `ilst` values of one `meta` (item N holds the value of key N, 1-based).
fn keyed_items(meta: &[u8], keyed: &mut dyn FnMut(&str, Option<String>)) {
    let all = boxes(meta);
    let Some((_, keys)) = all.iter().find(|(k, _)| k == b"keys") else { return };
    let Some((_, ilst)) = all.iter().find(|(k, _)| k == b"ilst") else { return };
    let mut names: Vec<String> = Vec::new();
    // keys: version/flags, count, then entries (size, namespace, name).
    let mut rest = keys.get(8..).unwrap_or_default();
    while rest.len() >= 8 {
        let size = u32::from_be_bytes([rest[0], rest[1], rest[2], rest[3]]) as usize;
        if size < 8 || size > rest.len() {
            break;
        }
        names.push(String::from_utf8_lossy(&rest[8..size]).into_owned());
        rest = &rest[size..];
    }
    for (kind, item) in boxes(ilst) {
        let index = u32::from_be_bytes(kind) as usize;
        let Some(name) = index.checked_sub(1).and_then(|i| names.get(i)) else { continue };
        // data: type (4), locale (4), value.
        let value = boxes(item).into_iter().find(|(k, _)| k == b"data").and_then(|(_, d)| d.get(8..).and_then(text_of));
        keyed(name, value);
    }
}

/// The body of the first `moov` box (at most 32 MB).
fn read_moov(path: &Path) -> Option<Vec<u8>> {
    let mut fh = File::open(path).ok()?;
    let end = fh.seek(SeekFrom::End(0)).ok()?;
    let mut pos = 0u64;
    while pos + 8 <= end {
        let h = read_at(&mut fh, pos, 8)?;
        let size = u64::from(u32::from_be_bytes([h[0], h[1], h[2], h[3]]));
        if size < 8 || size > end - pos {
            return None;
        }
        if &h[4..8] == b"moov" {
            return (size - 8 <= 32 << 20).then(|| read_at(&mut fh, pos + 8, size - 8)).flatten();
        }
        pos += size;
    }
    None
}

fn clean(s: Option<&str>) -> Option<String> {
    let t = s?.trim_matches(|c: char| c.is_whitespace() || c.is_control());
    (!t.is_empty()).then(|| t.to_string())
}

fn read_at(fh: &mut File, pos: u64, n: u64) -> Option<Vec<u8>> {
    fh.seek(SeekFrom::Start(pos)).ok()?;
    let mut out = Vec::new();
    fh.take(n).read_to_end(&mut out).ok()?;
    Some(out)
}

/// The `mvhd` creation time inside `moov`; 0 (unset) reads as `None`.
fn creation_unix(path: &Path) -> Option<f64> {
    let mut fh = File::open(path).ok()?;
    let end = fh.seek(SeekFrom::End(0)).ok()?;
    let (mut pos, mut moov) = (0u64, None);
    while pos + 8 <= end {
        let h = read_at(&mut fh, pos, 8)?;
        let size = u64::from(u32::from_be_bytes([h[0], h[1], h[2], h[3]]));
        if size < 8 || size > end - pos {
            return None;
        }
        if &h[4..8] == b"moov" {
            moov = Some((pos + 8, pos + size));
            break;
        }
        pos += size;
    }
    let (mut pos, end) = moov?;
    while pos + 8 <= end {
        let h = read_at(&mut fh, pos, 8)?;
        let size = u64::from(u32::from_be_bytes([h[0], h[1], h[2], h[3]]));
        if size < 8 || size > end - pos {
            return None;
        }
        if &h[4..8] == b"mvhd" {
            let b = read_at(&mut fh, pos + 8, 12)?;
            let secs = match b.first()? {
                0 if b.len() >= 8 => u64::from(u32::from_be_bytes([b[4], b[5], b[6], b[7]])),
                1 if b.len() >= 12 => u64::from_be_bytes(read_at(&mut fh, pos + 12, 8)?.try_into().ok()?),
                _ => return None,
            };
            return (secs > QUICKTIME_TO_UNIX).then(|| (secs - QUICKTIME_TO_UNIX) as f64);
        }
        pos += size;
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn boxed(kind: &[u8; 4], body: &[u8]) -> Vec<u8> {
        let mut v = ((body.len() + 8) as u32).to_be_bytes().to_vec();
        v.extend(kind);
        v.extend(body);
        v
    }

    fn file(name: &str, bytes: &[u8]) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("sq-shoot-{}-{name}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap_or_default();
        let p = dir.join(name);
        std::fs::write(&p, bytes).unwrap_or_default();
        p
    }

    #[test]
    fn mvhd_version_0_gives_the_creation_date() {
        // 2026-01-02T03:04:05Z
        let unix = 1_767_323_045u64;
        let mut body = vec![0, 0, 0, 0];
        body.extend(((unix + QUICKTIME_TO_UNIX) as u32).to_be_bytes());
        body.extend([0u8; 16]);
        let mut bytes = boxed(b"ftyp", b"isom");
        bytes.extend(boxed(b"moov", &boxed(b"mvhd", &body)));
        let r = ShootMetadata::read(&file("v0.mp4", &bytes), Some("  ZV-E1\n"));
        assert_eq!(r.created_unix, Some(unix as f64));
        assert_eq!(r.camera_model.as_deref(), Some("ZV-E1"));
    }

    #[test]
    fn mvhd_version_1_and_unset_dates() {
        let unix = 1_767_323_045u64;
        let mut body = vec![1, 0, 0, 0];
        body.extend((unix + QUICKTIME_TO_UNIX).to_be_bytes());
        body.extend([0u8; 20]);
        let r = ShootMetadata::read(&file("v1.mov", &boxed(b"moov", &boxed(b"mvhd", &body))), None);
        assert_eq!(r, ShootResult { created_unix: Some(unix as f64), camera_model: None });
        let unset = vec![0u8; 24];
        let r = ShootMetadata::read(&file("unset.mov", &boxed(b"moov", &boxed(b"mvhd", &unset))), Some(" "));
        assert_eq!(r, ShootResult::default());
        assert_eq!(ShootMetadata::read(Path::new("/no/such/file.mp4"), None), ShootResult::default());
    }

    fn keyed_meta(pairs: &[(&str, &str)]) -> Vec<u8> {
        let mut keys = vec![0, 0, 0, 0];
        keys.extend((pairs.len() as u32).to_be_bytes());
        let mut ilst = Vec::new();
        for (i, (k, v)) in pairs.iter().enumerate() {
            keys.extend(boxed(b"mdta", k.as_bytes()));
            let mut data = vec![0, 0, 0, 1, 0, 0, 0, 0];
            data.extend(v.as_bytes());
            ilst.extend(boxed(&((i + 1) as u32).to_be_bytes(), &boxed(b"data", &data)));
        }
        let mut meta = vec![0, 0, 0, 0];
        meta.extend(boxed(b"keys", &keys));
        meta.extend(boxed(b"ilst", &ilst));
        boxed(b"meta", &meta)
    }

    // Swift: ShootMetadata.read (AVFoundation `model` / `make` metadata items)
    #[test]
    fn quicktime_keys_give_the_model_and_fall_back_to_the_make() {
        let both =
            keyed_meta(&[("com.apple.quicktime.make", "Apple"), ("com.apple.quicktime.model", " iPhone 15 Pro ")]);
        let p = file("qt-both.mov", &boxed(b"moov", &both));
        assert_eq!(ShootMetadata::read(&p, None).camera_model.as_deref(), Some("iPhone 15 Pro"));
        let make_only = keyed_meta(&[("com.apple.quicktime.make", "Apple")]);
        let p = file("qt-make.mov", &boxed(b"moov", &make_only));
        assert_eq!(ShootMetadata::read(&p, None).camera_model.as_deref(), Some("Apple"));
        // Sony's model from the import wins over the container keys.
        assert_eq!(ShootMetadata::read(&p, Some("ZV-E1")).camera_model.as_deref(), Some("ZV-E1"));
    }

    #[test]
    fn old_udta_atoms_are_read_too() {
        let mut model = vec![0, 4, 0, 0];
        model.extend(b"Hero12");
        let udta = boxed(b"udta", &boxed(&[0xA9, b'm', b'o', b'd'], &model));
        let p = file("qt-udta.mov", &boxed(b"moov", &udta));
        assert_eq!(ShootMetadata::read(&p, None).camera_model.as_deref(), Some("Hero12"));
    }
}
