// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Core Text's font lookup by family or PostScript name (the Mac app finds fonts the user installed).
//! Finds installed font files (user and system font folders) by PostScript, full or family name, so a title set in a font
//! that is not bundled (for example a brand font in `~/Library/Fonts`) draws with that font, not with the Inter fallback.

use std::ffi::OsString;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::LazyLock;

/// One installed font file with the names Core Text matches on.
#[derive(Clone, Debug)]
pub struct InstalledFont {
    /// The file.
    pub path: PathBuf,
    /// Family name (name id 1, or 16 when present).
    pub family: String,
    /// PostScript name (id 6).
    pub postscript: String,
    /// Full name (id 4).
    pub full: String,
}

static INSTALLED: LazyLock<Vec<InstalledFont>> = LazyLock::new(|| scan(&font_folders()));

/// The PostScript name of a font file (tests and tools).
pub fn read_postscript(file: &Path) -> Option<String> {
    read_names(file, None).map(|i| i.postscript)
}

/// Font files registered for this process (pack fonts), matched before the installed ones (Swift `CTFontManager` `.process`).
static REGISTERED: std::sync::RwLock<Vec<InstalledFont>> = std::sync::RwLock::new(Vec::new());

/// Registers font files for this session; returns how many gave a readable font. Already registered files are kept once.
pub fn register_files(files: &[PathBuf]) -> usize {
    let mut list = REGISTERED.write().unwrap_or_else(std::sync::PoisonError::into_inner);
    let mut added = 0;
    for f in files {
        if list.iter().any(|i| i.path == *f) {
            added += 1;
            continue;
        }
        let ext = f.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default();
        if ext == "ttc" || ext == "otc" {
            let before = list.len();
            read_collection(f, &mut list);
            added += usize::from(list.len() > before);
        } else if let Some(i) = read_names(f, None) {
            list.push(i);
            added += 1;
        }
    }
    added
}

/// The folders the system and the user install fonts to, on all three systems (the ones that do not exist are skipped).
fn font_folders() -> Vec<PathBuf> {
    folders_from(&|k| std::env::var_os(k))
}

fn folders_from(env: &dyn Fn(&str) -> Option<OsString>) -> Vec<PathBuf> {
    let mut v = Vec::new();
    let home = env("HOME").map(PathBuf::from);
    if let Some(h) = &home {
        // macOS, then Linux (`~/.fonts` is the old place, `~/.local/share/fonts` the current one)
        v.push(h.join("Library/Fonts"));
        v.push(h.join(".fonts"));
        v.push(env("XDG_DATA_HOME").map_or_else(|| h.join(".local/share"), PathBuf::from).join("fonts"));
    }
    for p in ["/Library/Fonts", "/System/Library/Fonts", "/Network/Library/Fonts"] {
        v.push(PathBuf::from(p));
    }
    // Fonts the user downloaded in Font Book live in asset folders (`com_apple_MobileAsset_Font*/<id>.asset/AssetData`).
    if let Ok(rd) = std::fs::read_dir("/System/Library/AssetsV2") {
        let mut assets: Vec<PathBuf> = rd
            .flatten()
            .map(|e| e.path())
            .filter(|p| p.file_name().is_some_and(|n| n.to_string_lossy().starts_with("com_apple_MobileAsset_Font")))
            .collect();
        assets.sort();
        v.extend(assets);
    }
    v.push(PathBuf::from("/usr/share/fonts"));
    v.push(PathBuf::from("/usr/local/share/fonts"));
    if let Some(w) = env("WINDIR").or_else(|| env("SystemRoot")) {
        v.push(PathBuf::from(w).join("Fonts"));
    }
    if let Some(l) = env("LOCALAPPDATA") {
        v.push(PathBuf::from(l).join("Microsoft/Windows/Fonts"));
    }
    v
}

/// A face of a font collection is addressed as `<file>#<index>` (a plain font file has no suffix and means face 0).
pub fn face_path(file: &Path, index: u32) -> PathBuf {
    let mut s = file.as_os_str().to_os_string();
    s.push(format!("#{index}"));
    PathBuf::from(s)
}

/// The font file and the face number of a path made by `face_path`; a path that exists as it is stays whole.
pub fn split_face(path: &Path) -> (PathBuf, u32) {
    if path.exists() {
        return (path.to_path_buf(), 0);
    }
    let text = path.to_string_lossy();
    match text.rsplit_once('#').and_then(|(file, n)| Some((file, n.parse::<u32>().ok()?))) {
        Some((file, n)) => (PathBuf::from(file), n),
        None => (path.to_path_buf(), 0),
    }
}

/// Font files whose PostScript, full or family name equals `name` (case-insensitive), PostScript matches first.
pub fn find(name: &str) -> Vec<PathBuf> {
    let registered = find_in(&REGISTERED.read().unwrap_or_else(std::sync::PoisonError::into_inner), name);
    if registered.is_empty() { find_in(&INSTALLED, name) } else { registered }
}

/// The installed family names, each once, sorted case-insensitively (Swift `FontFamilyList.fetch`).
pub fn families() -> Vec<String> {
    let mut all = INSTALLED.clone();
    all.extend(REGISTERED.read().unwrap_or_else(std::sync::PoisonError::into_inner).iter().cloned());
    families_in(&all)
}

fn families_in(list: &[InstalledFont]) -> Vec<String> {
    let mut names: Vec<String> = list.iter().map(|i| i.family.clone()).filter(|f| !f.is_empty()).collect();
    names.sort_by_cached_key(|n| n.to_lowercase());
    names.dedup();
    names
}

fn find_in(list: &[InstalledFont], name: &str) -> Vec<PathBuf> {
    let n = name.to_lowercase();
    let by = |f: &dyn Fn(&InstalledFont) -> &str| -> Vec<PathBuf> {
        list.iter().filter(|i| f(i).to_lowercase() == n).map(|i| i.path.clone()).collect()
    };
    let ps = by(&|i| &i.postscript);
    if !ps.is_empty() {
        return ps;
    }
    let full = by(&|i| &i.full);
    if !full.is_empty() {
        return full;
    }
    by(&|i| &i.family)
}

fn scan(folders: &[PathBuf]) -> Vec<InstalledFont> {
    let mut out = Vec::new();
    for dir in folders {
        scan_dir(dir, 0, &mut out);
    }
    out
}

/// How deep below a font folder fonts are looked for (Linux and the macOS asset folders keep them in sub folders).
const MAX_DEPTH: usize = 5;

fn scan_dir(dir: &Path, depth: usize, out: &mut Vec<InstalledFont>) {
    let Ok(rd) = std::fs::read_dir(dir) else { return };
    let mut paths: Vec<PathBuf> = rd.flatten().map(|e| e.path()).collect();
    paths.sort();
    for p in paths {
        if p.is_dir() {
            if depth < MAX_DEPTH {
                scan_dir(&p, depth + 1, out);
            }
            continue;
        }
        let ext = p.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default();
        match ext.as_str() {
            "otf" | "ttf" => out.extend(read_names(&p, None)),
            "ttc" | "otc" => read_collection(&p, out),
            _ => {}
        }
    }
}

/// Every font of a collection file, each addressed by `face_path`.
fn read_collection(path: &Path, out: &mut Vec<InstalledFont>) {
    let Ok(mut f) = File::open(path) else { return };
    let mut head = [0u8; 12];
    if f.read_exact(&mut head).is_err() || &head[0..4] != b"ttcf" {
        return;
    }
    let Some(count) = be32(&head, 8).filter(|&n| n <= 256) else { return };
    let mut offsets = vec![0u8; count * 4];
    if f.read_exact(&mut offsets).is_err() {
        return;
    }
    for i in 0..count {
        let Some(base) = be32(&offsets, i * 4) else { continue };
        out.extend(read_names(&face_path(path, i as u32), Some(base as u64)));
    }
}

fn be16(b: &[u8], o: usize) -> Option<usize> {
    Some(u16::from_be_bytes([*b.get(o)?, *b.get(o + 1)?]) as usize)
}
fn be32(b: &[u8], o: usize) -> Option<usize> {
    Some(u32::from_be_bytes([*b.get(o)?, *b.get(o + 1)?, *b.get(o + 2)?, *b.get(o + 3)?]) as usize)
}

/// Reads only the `name` table of a font: a single-font sfnt file, or the font at `base` in a collection (`path` then
/// carries the face suffix).
fn read_names(path: &Path, base: Option<u64>) -> Option<InstalledFont> {
    let mut f = File::open(split_face(path).0).ok()?;
    f.seek(SeekFrom::Start(base.unwrap_or(0))).ok()?;
    let mut head = [0u8; 12];
    f.read_exact(&mut head).ok()?;
    if !matches!(&head[0..4], b"OTTO" | b"true" | [0, 1, 0, 0]) {
        return None;
    }
    let count = be16(&head, 4)?;
    let mut dir = vec![0u8; count * 16];
    f.read_exact(&mut dir).ok()?;
    let (offset, length) = (0..count).find_map(|i| {
        let r = i * 16;
        (&dir[r..r + 4] == b"name").then(|| (be32(&dir, r + 8), be32(&dir, r + 12)))
    })?;
    let (offset, length) = (offset?, length?);
    if length > 1 << 20 {
        return None;
    }
    f.seek(SeekFrom::Start(offset as u64)).ok()?;
    let mut t = vec![0u8; length];
    f.read_exact(&mut t).ok()?;
    let (n, storage) = (be16(&t, 2)?, be16(&t, 4)?);
    let get = |id: usize| -> Option<String> {
        let mut found: Option<String> = None;
        for i in 0..n {
            let r = 6 + i * 12;
            let (plat, enc, nid, len, off) =
                (be16(&t, r)?, be16(&t, r + 2)?, be16(&t, r + 6)?, be16(&t, r + 8)?, be16(&t, r + 10)?);
            if nid != id {
                continue;
            }
            let raw = t.get(storage + off..storage + off + len)?;
            let s = if plat == 3 || plat == 0 || (plat == 2 && enc == 1) {
                let u: Vec<u16> = raw.as_chunks::<2>().0.iter().map(|c| u16::from_be_bytes([c[0], c[1]])).collect();
                String::from_utf16_lossy(&u)
            } else {
                raw.iter().map(|&b| b as char).collect()
            };
            if plat == 3 || found.is_none() {
                found = Some(s);
            }
        }
        found
    };
    Some(InstalledFont {
        path: path.to_path_buf(),
        family: get(16).or_else(|| get(1)).unwrap_or_default(),
        postscript: get(6)?,
        full: get(4).unwrap_or_default(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn families_are_unique_and_sorted_ignoring_case() {
        let font = |f: &str| InstalledFont {
            path: PathBuf::new(),
            family: f.to_string(),
            postscript: String::new(),
            full: String::new(),
        };
        let list = vec![font("zeta"), font("Beta"), font("alpha"), font("Beta"), font("")];
        assert_eq!(families_in(&list), vec!["alpha", "Beta", "zeta"]);
    }

    #[test]
    fn a_registered_file_is_found_by_its_names_and_listed_as_a_family() {
        let root = crate::bundled_fonts::test_fonts_root();
        let file = crate::inter_font::font_urls(&root).into_iter().next().expect("inter file");
        let names = read_names(&file, None).expect("names");
        let dir = std::env::temp_dir().join(format!("sq-registered-font-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("dir");
        let copy = dir.join("PackFace.ttf");
        std::fs::copy(&file, &copy).expect("copy");
        assert_eq!(register_files(&[copy.clone(), dir.join("missing.ttf")]), 1);
        assert_eq!(register_files(std::slice::from_ref(&copy)), 1, "twice stays one entry");
        // Other tests register copies of the same face: ours must be among the matches, once.
        let found = find(&names.postscript);
        assert_eq!(found.iter().filter(|f| **f == copy).count(), 1);
        assert!(families().contains(&names.family));
    }

    #[test]
    fn reads_names_of_a_bundled_font_and_finds_it_by_each_name() {
        let root = crate::bundled_fonts::test_fonts_root();
        let file = crate::inter_font::font_urls(&root).into_iter().next().expect("inter file");
        let one = read_names(&file, None).expect("names");
        assert!(!one.postscript.is_empty() && one.family.to_lowercase().contains("inter"));
        let list = vec![one.clone()];
        assert_eq!(find_in(&list, &one.postscript.to_uppercase()), vec![file.clone()]);
        assert_eq!(find_in(&list, &one.family), vec![file]);
        assert!(find_in(&list, "No Such Font").is_empty());
    }

    /// A collection of the first two bundled families that have a file (the file offsets are absolute, so each font's
    /// table records are shifted by where the font lands).
    fn collection_of_two() -> (Vec<u8>, [PathBuf; 2]) {
        let root = crate::bundled_fonts::test_fonts_root();
        let files: Vec<PathBuf> = crate::bundled_fonts::FAMILIES
            .iter()
            .filter_map(|f| crate::bundled_fonts::font_urls(f, &root).into_iter().next())
            .take(2)
            .collect();
        let (a, b) = (files[0].clone(), files[1].clone());
        let mut out = vec![0u8; 12 + 8];
        out[0..4].copy_from_slice(b"ttcf");
        out[4..8].copy_from_slice(&[0, 1, 0, 0]);
        out[8..12].copy_from_slice(&2u32.to_be_bytes());
        for (i, file) in [&a, &b].into_iter().enumerate() {
            let mut data = std::fs::read(file).expect("font");
            let pos = out.len() as u32;
            out[12 + i * 4..16 + i * 4].copy_from_slice(&pos.to_be_bytes());
            for t in 0..usize::from(u16::from_be_bytes([data[4], data[5]])) {
                let at = 12 + t * 16 + 8;
                let old = u32::from_be_bytes([data[at], data[at + 1], data[at + 2], data[at + 3]]);
                data[at..at + 4].copy_from_slice(&(old + pos).to_be_bytes());
            }
            out.extend(data);
        }
        (out, [a, b])
    }

    #[test]
    fn a_font_collection_lists_every_face_and_loads_the_picked_one() {
        let (ttc, singles) = collection_of_two();
        let dir = std::env::temp_dir().join(format!("sq-ttc-test-{}", std::process::id())).join("deeper");
        std::fs::create_dir_all(&dir).expect("dir");
        let file = dir.join("Pair.ttc");
        std::fs::write(&file, ttc).expect("write");
        let listed = scan(&[dir.parent().expect("parent").to_path_buf()]);
        assert_eq!(listed.len(), 2, "both faces of the collection, found in a sub folder");
        for (i, single) in singles.iter().enumerate() {
            let want = read_names(single, None).expect("single names");
            assert_eq!(listed[i].path, face_path(&file, i as u32));
            assert_eq!((&listed[i].postscript, &listed[i].family), (&want.postscript, &want.family));
            assert_eq!(find_in(&listed, &want.postscript), vec![face_path(&file, i as u32)]);
            let in_ttc = crate::glyph_raster::GlyphRasterFont::from_path(&listed[i].path).expect("face loads");
            let alone = crate::glyph_raster::GlyphRasterFont::from_path(single).expect("single loads");
            assert_eq!((in_ttc.ascender, in_ttc.units_per_em), (alone.ascender, alone.units_per_em));
            assert_eq!(in_ttc.glyph_for('A'), alone.glyph_for('A'));
            assert_eq!(in_ttc.contours(in_ttc.glyph_for('A'), &[]), alone.contours(alone.glyph_for('A'), &[]));
        }
        std::fs::remove_dir_all(dir.parent().expect("parent")).ok();
    }

    /// A collection the OS ships (macOS has many `.ttc`, Windows has `msgothic.ttc`, most Linux installs have DejaVu or Noto
    /// collections): its faces are listed and at least one outline font of them loads. Skipped without any collection.
    #[test]
    fn installed_collection_faces_are_listed_and_load() {
        let faces: Vec<&InstalledFont> =
            INSTALLED.iter().filter(|i| i.path.to_string_lossy().contains(".tt")).collect();
        let faces: Vec<&&InstalledFont> = faces.iter().filter(|i| i.path.to_string_lossy().contains('#')).collect();
        if faces.is_empty() {
            return;
        }
        assert!(
            faces.iter().any(
                |f| crate::glyph_raster::GlyphRasterFont::from_path(&f.path).is_some_and(|g| g.glyph_for('A') != 0)
            )
        );
        assert!(faces.iter().all(|f| !f.postscript.is_empty()));
    }

    #[test]
    fn face_paths_split_back_and_plain_paths_stay_whole() {
        let p = face_path(Path::new("/x/Helvetica.ttc"), 3);
        assert_eq!(split_face(&p), (PathBuf::from("/x/Helvetica.ttc"), 3));
        assert_eq!(split_face(Path::new("/x/Plain.ttf")), (PathBuf::from("/x/Plain.ttf"), 0));
    }

    #[test]
    fn folders_cover_the_three_systems() {
        let env = |k: &str| match k {
            "HOME" => Some(OsString::from("/home/u")),
            "WINDIR" => Some(OsString::from("C:\\Windows")),
            "LOCALAPPDATA" => Some(OsString::from("C:\\U\\AppData\\Local")),
            _ => None,
        };
        let f = folders_from(&env);
        for want in [
            "/home/u/Library/Fonts",
            "/home/u/.local/share/fonts",
            "/home/u/.fonts",
            "/Library/Fonts",
            "/System/Library/Fonts",
            "/usr/share/fonts",
            "/usr/local/share/fonts",
        ] {
            assert!(f.contains(&PathBuf::from(want)), "{want}");
        }
        assert!(f.contains(&PathBuf::from("C:\\Windows").join("Fonts")));
        assert!(f.contains(&PathBuf::from("C:\\U\\AppData\\Local").join("Microsoft/Windows/Fonts")));
    }

    /// The o2 Black Weeks title "Unlimited M Flex" (OnAir-Bold 60, padding 34/20): the layout uses the installed font's
    /// own advances and hhea metrics (what Core Text reports for it), and the box is the text plus the padding.
    /// Skipped on a machine without the font.
    #[test]
    fn installed_brand_font_drives_the_title_box() {
        use crate::text_layout::TextLayout;
        use crate::text_style::{BoxPadding, FontWeight, RGBAColor, TextBackground, TextStyle};
        let root = crate::bundled_fonts::test_fonts_root();
        crate::portable_font_match::set_fonts_root(&root);
        let Some(file) = find("OnAir-Bold").into_iter().next() else { return };
        let face = crate::sfnt_face::SfntFace::from_path(&file).expect("face");
        let size = 60.0;
        let text = "Unlimited M Flex";
        let mut style = TextStyle::new("OnAir-Bold", size, FontWeight::Bold, RGBAColor::WHITE);
        style.background =
            Some(TextBackground::new(RGBAColor::new(1.0, 1.0, 1.0, 1.0), BoxPadding::new(34.0, 20.0), 22.0));
        let r = TextLayout::layout(text, &style, None, None);
        let scale = size / face.units_per_em as f64;
        let sum: f64 = text.chars().map(|c| face.advance(face.glyph_for(c)) as f64 * scale).sum();
        let line = &r.lines[0];
        // Advances without pair kerning bound the width from above within a few percent.
        assert!(line.width <= sum + 1e-6 && line.width > sum * 0.93, "width {} vs advances {}", line.width, sum);
        let height = (face.ascender as f64 - face.descender as f64) * scale;
        assert!((line.height - height).abs() < 1e-6, "height {} vs hhea {}", line.height, height);
        // CFF outlines are read: "l" has a closed contour inside the em box.
        let gr = crate::glyph_raster::GlyphRasterFont::from_path(&file).expect("cff font loads");
        let c = gr.contours(face.glyph_for('l'), &[]);
        assert!(!c.is_empty() && c.iter().flatten().all(|p| p.y > -400.0 && p.y < 1100.0));
        let bg = r.background_rect.expect("box");
        assert!((bg.width - (line.width + 68.0)).abs() < 1e-6 && (bg.height - (line.height + 40.0)).abs() < 1e-6);
        // Not the Inter fallback: a different face gives a different width.
        let mut fallback = style.clone();
        fallback.font_name = "Inter".into();
        let inter = TextLayout::layout(text, &fallback, None, None);
        assert!((inter.lines[0].width - line.width).abs() > 1.0);
    }
}
