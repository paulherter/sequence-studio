// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: PortableFontMatch.swift (the bundled fonts folder is set once with `set_fonts_root`, Swift's `Bundle.module`)
//! Picks the bundled font file and variation coordinates for a family, weight, style and size.

use crate::bundled_fonts::{self, FAMILIES};
use crate::font_resolver::{Axis, FontResolver};
use crate::glyph_raster::GlyphRasterFont;
use crate::inter_font;
use crate::text_style::FontWeight;
use sq_core_time::text::ci_contains;
use std::collections::{BTreeMap, HashMap};
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::sync::{Arc, LazyLock, Mutex, MutexGuard, OnceLock, PoisonError, RwLock};

/// A bundled font file at one point of its variation space: what the portable layout measures and the portable raster
/// draws. Matches Core Text's choice on the Mac (`FontResolver.resolveUprightFont` / `italicVersion`): the family face or
/// named instance whose weight trait is nearest the asked weight, the family's italic file for italic (else the upright
/// face sheared 12 degrees), `opsz` following the point size, the style's own axis values on top.
#[derive(Clone, Debug)]
pub struct PortableFontChoice {
    /// The font file.
    pub font: Arc<GlyphRasterFont>,
    /// Normalized variation coordinates (empty for a static font).
    pub coords: Vec<f64>,
    /// No italic file: the renderer shears the upright outlines.
    pub shear: bool,
    /// Core Text's weight trait of the chosen face (-1...1).
    pub weight_trait: f64,
}

impl PortableFontChoice {
    /// The font's face.
    pub fn face(&self) -> &crate::sfnt_face::SfntFace {
        &self.font.face
    }
}

#[derive(Clone, PartialEq, Eq, Hash)]
struct Key {
    name: String,
    weight: FontWeight,
    italic: bool,
    size: u64,
    axes: Option<Vec<(String, u64)>>,
}

#[derive(Default)]
struct State {
    fonts: HashMap<PathBuf, Arc<GlyphRasterFont>>,
    choices: HashMap<Key, PortableFontChoice>,
}

static STATE: LazyLock<Mutex<State>> = LazyLock::new(|| Mutex::new(State::default()));
static FONTS_ROOT: RwLock<Option<PathBuf>> = RwLock::new(None);

fn state() -> MutexGuard<'static, State> {
    STATE.lock().unwrap_or_else(PoisonError::into_inner)
}

/// Sets the folder of the bundled fonts (the package's `Resources/Fonts`) and forgets every remembered font.
pub fn set_fonts_root(root: &Path) {
    // Tests: wait while a test holds the root on something else (`ROOT_TEST_LOCK`); the root is process-wide.
    #[cfg(test)]
    drop(ROOT_TEST_LOCK.lock().unwrap_or_else(PoisonError::into_inner));
    set_root(root);
}

fn set_root(root: &Path) {
    *FONTS_ROOT.write().unwrap_or_else(PoisonError::into_inner) = Some(root.to_path_buf());
    let mut s = state();
    s.fonts.clear();
    s.choices.clear();
    drop(s);
    FontResolver::fonts_changed();
}

/// Registers font files for this session (pack fonts, Swift `CTFontManagerRegisterFontsForURLs` `.process`): text set in
/// one of their families draws with it from now on. Returns how many files gave a font.
pub fn register_font_files(files: &[PathBuf]) -> usize {
    let n = crate::system_fonts::register_files(files);
    if n > 0 {
        let mut s = state();
        s.choices.clear();
        drop(s);
        FontResolver::fonts_changed();
    }
    n
}

/// The folder set with `set_fonts_root`, else the one found beside the running program (`discover_fonts_root`), so text
/// drawn on another thread before the app sets the folder still finds its fonts.
pub fn fonts_root() -> Option<PathBuf> {
    static DISCOVERED: OnceLock<Option<PathBuf>> = OnceLock::new();
    let set = FONTS_ROOT.read().unwrap_or_else(PoisonError::into_inner).clone();
    set.or_else(|| {
        DISCOVERED
            .get_or_init(|| {
                let exe_dir = std::env::current_exe().ok().and_then(|e| e.parent().map(Path::to_path_buf));
                discover_fonts_root(std::env::var_os("SQ_FONTS"), exe_dir.as_deref(), std::env::var_os("APPDIR"))
            })
            .clone()
    })
}

/// Finds the bundled fonts folder for the three package layouts: `SQ_FONTS`, the Mac bundle (`Contents/Resources/Fonts`
/// beside `Contents/MacOS`), a `Fonts` folder beside the executable (Windows install, Linux AppImage `usr/bin/Fonts`),
/// then `$APPDIR/usr/bin/Fonts`. Only folders that exist count.
pub fn discover_fonts_root(
    sq_fonts: Option<OsString>,
    exe_dir: Option<&Path>,
    appdir: Option<OsString>,
) -> Option<PathBuf> {
    let mut candidates: Vec<PathBuf> = sq_fonts.into_iter().map(PathBuf::from).collect();
    if let Some(dir) = exe_dir {
        candidates.push(dir.join("../Resources/Fonts"));
        candidates.push(dir.join("Fonts"));
    }
    candidates.extend(appdir.map(|a| PathBuf::from(a).join("usr/bin/Fonts")));
    candidates.into_iter().find(|c| c.is_dir())
}

/// Pseudo path of the Inter face compiled into the program, the last resort when no fonts folder is found.
const EMBEDDED_INTER: &str = "<embedded>/Inter-VariableFont_opsz,wght.ttf";
static EMBEDDED_INTER_BYTES: &[u8] =
    include_bytes!("../../../Packages/SQText/Sources/SQText/Resources/Fonts/Inter-VariableFont_opsz,wght.ttf");

/// Namespace of the font matching functions.
pub enum PortableFontMatch {}

impl PortableFontMatch {
    /// The face for a family (or file) name; unknown names draw in Inter. nil only without the bundled Inter.
    pub fn choose(
        name: &str,
        weight: FontWeight,
        italic: bool,
        size: f64,
        axes: Option<&BTreeMap<String, f64>>,
    ) -> Option<PortableFontChoice> {
        let key = Key {
            name: name.to_string(),
            weight,
            italic,
            size: size.to_bits(),
            axes: axes.map(|a| a.iter().map(|(k, v)| (k.clone(), v.to_bits())).collect()),
        };
        if let Some(c) = state().choices.get(&key) {
            return Some(c.clone());
        }
        let c = Self::resolve(name, weight, italic, size, axes).or_else(|| {
            if name == inter_font::FAMILY_NAME {
                None
            } else {
                Self::resolve(inter_font::FAMILY_NAME, weight, italic, size, axes)
            }
        })?;
        let mut s = state();
        if s.choices.len() > 512 {
            s.choices.clear();
        }
        s.choices.insert(key, c.clone());
        Some(c)
    }

    fn resolve(
        name: &str,
        weight: FontWeight,
        italic: bool,
        size: f64,
        axes: Option<&BTreeMap<String, f64>>,
    ) -> Option<PortableFontChoice> {
        let files = Self::candidates(name);
        if files.is_empty() {
            return None;
        }
        // A collection face has no file of its own to name its style: ask the font.
        let is_italic = |u: &&PathBuf| {
            if u.to_string_lossy().contains('#') {
                return Self::font(u).is_some_and(|f| f.face.is_italic());
            }
            u.file_name().is_some_and(|f| ci_contains(&f.to_string_lossy(), "italic"))
        };
        let italics: Vec<&PathBuf> = files.iter().filter(is_italic).collect();
        let uprights: Vec<&PathBuf> = files.iter().filter(|u| !is_italic(u)).collect();
        let pool: Vec<&PathBuf> = if italic {
            if italics.is_empty() { uprights } else { italics.clone() }
        } else if uprights.is_empty() {
            files.iter().collect()
        } else {
            uprights
        };
        let shear = italic && italics.is_empty();
        let target = FontResolver::trait_value(weight);
        // Options in Core Text's order: each file's default face first, then its named instances; the first nearest wins.
        let mut best: Option<(Arc<GlyphRasterFont>, Vec<f64>, f64)> = None;
        for u in pool {
            let Some(f) = Self::font(u) else { continue };
            let mut options: Vec<(Vec<f64>, f64)> = Vec::new();
            match f.face.variations.as_ref().and_then(|v| v.axis_index("wght").map(|w| (v, w))) {
                Some((v, w)) => {
                    let defaults: Vec<f64> = v.axes.iter().map(|a| a.default_value).collect();
                    let t = Self::weight_trait(defaults[w]);
                    options.push((defaults, t));
                    for inst in v.instances.iter().filter(|i| i.len() == v.axes.len()) {
                        options.push((inst.clone(), Self::weight_trait(inst[w])));
                    }
                }
                None => {
                    let defaults = f
                        .face
                        .variations
                        .as_ref()
                        .map(|v| v.axes.iter().map(|a| a.default_value).collect())
                        .unwrap_or_default();
                    options.push((defaults, Self::weight_trait(f.face.weight_class as f64)));
                }
            }
            for (user, t) in options {
                if best.as_ref().is_none_or(|b| (t - target).abs() < (b.2 - target).abs() - 1e-6) {
                    best = Some((Arc::clone(&f), user, t));
                }
            }
        }
        let (font, instance, trait_value) = best?;
        let Some(v) = font.face.variations.as_ref() else {
            return Some(PortableFontChoice { font, coords: Vec::new(), shear, weight_trait: trait_value });
        };
        let mut user = instance;
        if let Some(o) = v.axis_index("opsz") {
            user[o] = size; // Core Text sets the optical size to the point size
        }
        for (tag, value) in axes.into_iter().flatten().filter(|(_, v)| v.is_finite()) {
            if let Some(i) = v.axis_index(tag) {
                user[i] = *value;
            }
        }
        let wght = v.axis_index("wght").map(|i| user[i].max(v.axes[i].minimum).min(v.axes[i].maximum));
        let coords = v.normalized(&user);
        let coords = if coords.iter().any(|c| *c != 0.0) { coords } else { Vec::new() };
        let weight_trait = wght.map_or(trait_value, Self::weight_trait);
        Some(PortableFontChoice { font, coords, shear, weight_trait })
    }

    /// Core Text's weight trait for a `wght` value or OS/2 weight class (measured: 100 -0.6, 200 -0.4, 300 -0.23,
    /// 400 0, 500 0.2, 600 0.3, 700 0.4, 800 0.6, 900 0.8; linear between).
    pub fn weight_trait(wght: f64) -> f64 {
        const TABLE: [(f64, f64); 9] = [
            (100.0, -0.6),
            (200.0, -0.4),
            (300.0, -0.23),
            (400.0, 0.0),
            (500.0, 0.2),
            (600.0, 0.3),
            (700.0, 0.4),
            (800.0, 0.6),
            (900.0, 0.8),
        ];
        if wght <= TABLE[0].0 {
            return TABLE[0].1;
        }
        for k in 1..TABLE.len() {
            if wght <= TABLE[k].0 {
                let (a, b) = (TABLE[k - 1], TABLE[k]);
                return a.1 + (wght - a.0) / (b.0 - a.0) * (b.1 - a.1);
            }
        }
        TABLE[TABLE.len() - 1].1
    }

    /// The variation axes of the font a name resolves to (the upright file), in axis order.
    pub fn axes_for_font_name(name: &str) -> Vec<Axis> {
        let Some(v) =
            Self::candidates(name).first().and_then(|u| Self::font(u)).and_then(|f| f.face.variations.clone())
        else {
            return Vec::new();
        };
        v.axes
            .iter()
            .map(|a| Axis {
                tag: a.tag.clone(),
                name: a.tag.clone(),
                minimum: a.minimum,
                maximum: a.maximum,
                default_value: a.default_value,
            })
            .collect()
    }

    /// The bundled or installed font files of a family, PostScript (or file) name; empty for an unknown name.
    pub fn candidates(name: &str) -> Vec<PathBuf> {
        let n = name.to_lowercase();
        let Some(root) = fonts_root() else {
            return if n == inter_font::FAMILY_NAME.to_lowercase() {
                vec![PathBuf::from(EMBEDDED_INTER)]
            } else {
                Vec::new()
            };
        };
        // known limit: a bundled family wins over an installed one of the same name; installed fonts come from `system_fonts` (.otf/.ttf/.ttc/.otc).
        if n == inter_font::FAMILY_NAME.to_lowercase() {
            let files = inter_font::font_urls(&root);
            return if files.is_empty() { vec![PathBuf::from(EMBEDDED_INTER)] } else { files };
        }
        match FAMILIES.iter().find(|f| f.name.to_lowercase() == n || f.files.iter().any(|x| x.to_lowercase() == n)) {
            Some(fam) => bundled_fonts::font_urls(fam, &root),
            None => crate::system_fonts::find(name),
        }
    }

    /// The font file at `url`, read once.
    pub fn font(url: &Path) -> Option<Arc<GlyphRasterFont>> {
        if let Some(f) = state().fonts.get(url) {
            return Some(Arc::clone(f));
        }
        let loaded = if url == Path::new(EMBEDDED_INTER) {
            static WARNED: OnceLock<()> = OnceLock::new();
            WARNED.get_or_init(|| {
                sq_os::errln!("bundled fonts folder not found: text uses the Inter face built into the program")
            });
            GlyphRasterFont::new(EMBEDDED_INTER_BYTES.to_vec())
        } else {
            GlyphRasterFont::from_path(url)
        };
        let f = Arc::new(loaded?);
        state().fonts.insert(url.to_path_buf(), Arc::clone(&f));
        Some(f)
    }
}

/// Points the font matcher at the package's bundled fonts (fonts are never copied into the crate).
#[cfg(test)]
pub(crate) fn use_bundled_fonts() {
    set_fonts_root(&crate::bundled_fonts::test_fonts_root());
}

/// Held by a test that points the fonts root somewhere else, so parallel tests do not flip it back mid-test.
#[cfg(test)]
static ROOT_TEST_LOCK: Mutex<()> = Mutex::new(());

#[cfg(test)]
mod tests {
    use super::*;
    use crate::text_style::TextStyle;

    fn inter(axes: Option<&[(&str, f64)]>, weight: FontWeight) -> TextStyle {
        use_bundled_fonts();
        let mut s = TextStyle::new("Inter", 40.0, weight, crate::text_style::RGBAColor::WHITE);
        s.font_axes = axes.map(|a| a.iter().map(|(k, v)| (k.to_string(), *v)).collect());
        s
    }

    fn trait_of(s: &TextStyle) -> f64 {
        FontResolver::weight_trait_of(&FontResolver::font_for(s))
    }

    #[test]
    fn a_registered_pack_font_becomes_a_candidate_for_its_names() {
        use_bundled_fonts();
        let root = crate::bundled_fonts::test_fonts_root();
        let file = inter_font::font_urls(&root).into_iter().next().expect("inter file");
        let ps = crate::system_fonts::read_postscript(&file).expect("postscript name");
        let dir = std::env::temp_dir().join(format!("sq-pack-font-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("dir");
        let copy = dir.join("PackFont.ttf");
        std::fs::copy(&file, &copy).expect("copy");
        assert_eq!(register_font_files(std::slice::from_ref(&copy)), 1);
        // Other tests register copies of the same face: ours must be among the candidates, once.
        assert_eq!(PortableFontMatch::candidates(&ps).iter().filter(|c| **c == copy).count(), 1);
        assert!(PortableFontMatch::choose(&ps, FontWeight::Regular, false, 20.0, None).is_some());
    }

    #[test]
    fn inter_exposes_the_weight_axis() {
        use_bundled_fonts();
        let axes = FontResolver::axes_for_font_name("Inter");
        let w = axes.iter().find(|a| a.tag == "wght").unwrap();
        assert!(w.minimum <= 100.0 + 1e-6 && w.maximum >= 900.0 - 1e-6);
        assert!(FontResolver::axes_for_font_name("Georgia").is_empty());
    }

    #[test]
    fn weight_axis_value_changes_the_font() {
        let light = trait_of(&inter(Some(&[("wght", 200.0)]), FontWeight::Regular));
        let heavy = trait_of(&inter(Some(&[("wght", 900.0)]), FontWeight::Regular));
        assert!(heavy > light + 0.2);
        // Axis values win over the discrete weight.
        assert!((trait_of(&inter(Some(&[("wght", 900.0)]), FontWeight::Thin)) - heavy).abs() < 1e-6);
    }

    #[test]
    fn out_of_range_values_clamp_and_unknown_axes_are_ignored() {
        let top = trait_of(&inter(Some(&[("wght", 900.0)]), FontWeight::Regular));
        let beyond = trait_of(&inter(Some(&[("wght", 5000.0)]), FontWeight::Regular));
        assert!((top - beyond).abs() < 1e-6);
        let plain = FontResolver::font_for(&inter(None, FontWeight::Regular));
        let unknown = FontResolver::font_for(&inter(Some(&[("zzzz", 3.0)]), FontWeight::Regular));
        assert_eq!(plain.choice.coords, unknown.choice.coords);
        assert_eq!(FontResolver::weight_trait_of(&plain), FontResolver::weight_trait_of(&unknown));
    }

    #[test]
    fn the_memo_does_not_mix_axis_values() {
        let a = trait_of(&inter(Some(&[("wght", 250.0)]), FontWeight::Regular));
        let b = trait_of(&inter(Some(&[("wght", 850.0)]), FontWeight::Regular));
        let a2 = trait_of(&inter(Some(&[("wght", 250.0)]), FontWeight::Regular));
        assert!(a != b && a == a2);
    }

    #[test]
    fn italic_uses_the_italic_file() {
        use_bundled_fonts();
        let c = PortableFontMatch::choose("Inter", FontWeight::Bold, true, 40.0, None).unwrap();
        assert!(!c.shear);
        let sheared = PortableFontMatch::choose("Montserrat", FontWeight::Bold, true, 40.0, None).unwrap();
        assert!(sheared.shear);
    }

    #[test]
    fn the_weight_trait_table_is_monotonic_and_linear_between_steps() {
        let all = [
            FontWeight::Thin,
            FontWeight::Light,
            FontWeight::Regular,
            FontWeight::Medium,
            FontWeight::Semibold,
            FontWeight::Bold,
            FontWeight::Heavy,
            FontWeight::Black,
        ];
        let v: Vec<f64> = all.iter().map(|w| FontResolver::trait_value(*w)).collect();
        assert!(v.windows(2).all(|p| p[0] < p[1]));
        assert_eq!(PortableFontMatch::weight_trait(50.0), -0.6);
        assert_eq!(PortableFontMatch::weight_trait(400.0), 0.0);
        assert!((PortableFontMatch::weight_trait(450.0) - 0.1).abs() < 1e-12);
        assert_eq!(PortableFontMatch::weight_trait(1000.0), 0.8);
    }

    #[test]
    fn unknown_names_draw_in_inter() {
        use_bundled_fonts();
        let c = PortableFontMatch::choose("NoSuchFont-XYZ", FontWeight::Bold, false, 20.0, None).unwrap();
        assert!(c.font.face.variations.is_some());
    }

    fn layout(tag: &str, parts: &[&str]) -> (PathBuf, PathBuf) {
        let base = std::env::temp_dir().join(format!("sq-fonts-layout-{tag}-{}", std::process::id()));
        let fonts = parts.iter().fold(base.clone(), |p, x| p.join(x));
        std::fs::create_dir_all(&fonts).unwrap();
        (base, fonts)
    }

    #[test]
    fn the_fonts_folder_is_found_in_each_package_layout() {
        // Mac bundle: Contents/MacOS/<exe>, Contents/Resources/Fonts.
        let (base, fonts) = layout("mac", &["Contents", "Resources", "Fonts"]);
        let exe = base.join("Contents/MacOS");
        std::fs::create_dir_all(&exe).unwrap();
        assert_eq!(
            discover_fonts_root(None, Some(&exe), None).map(|p| p.canonicalize().unwrap()),
            Some(fonts.canonicalize().unwrap())
        );
        // Windows: Fonts beside the exe.
        let (base, fonts) = layout("win", &["Fonts"]);
        assert_eq!(discover_fonts_root(None, Some(&base), None), Some(fonts));
        // Linux AppImage: usr/bin/Fonts, found from the exe dir and from APPDIR alone.
        let (base, fonts) = layout("lin", &["usr", "bin", "Fonts"]);
        assert_eq!(discover_fonts_root(None, Some(&base.join("usr/bin")), None), Some(fonts.clone()));
        assert_eq!(discover_fonts_root(None, None, Some(base.clone().into_os_string())), Some(fonts.clone()));
        // SQ_FONTS wins; a missing folder is skipped.
        assert_eq!(
            discover_fonts_root(Some(fonts.clone().into_os_string()), Some(Path::new("/nowhere")), None),
            Some(fonts)
        );
        assert_eq!(discover_fonts_root(Some("/nowhere/x".into()), Some(Path::new("/nowhere")), None), None);
    }

    #[test]
    fn text_resolves_before_the_app_sets_the_fonts_folder() {
        // The playback thread can draw a caption before the shell calls `set_fonts_root` (7 of 7 AppImage starts).
        let c = PortableFontMatch::choose("Inter", FontWeight::Regular, false, 24.0, None);
        assert!(c.is_some_and(|c| c.font.face.variations.is_some()));
    }

    #[test]
    fn an_empty_or_wrong_fonts_folder_falls_back_to_the_built_in_inter() {
        let (_, empty) = layout("empty", &["Fonts"]);
        let held = ROOT_TEST_LOCK.lock().unwrap_or_else(PoisonError::into_inner);
        set_root(&empty);
        for name in ["Inter", "NoSuchFont-XYZ", "Anton"] {
            let c = PortableFontMatch::choose(name, FontWeight::Bold, true, 30.0, None);
            assert!(c.is_some(), "{name}");
        }
        // A size no other test uses, so a parallel test cannot have left its Anton (a static face) in the process-wide memo.
        let style = TextStyle { font_name: "Anton".into(), size: 30.125, ..TextStyle::default() };
        assert!(FontResolver::font_for(&style).face().variations.is_some());
        // The fonts root is process-wide: give the bundled one back for the tests that share this process.
        drop(held);
        use_bundled_fonts();
    }

    #[test]
    fn the_built_in_inter_face_parses() {
        assert!(GlyphRasterFont::new(EMBEDDED_INTER_BYTES.to_vec()).is_some_and(|f| f.face.variations.is_some()));
    }
}
