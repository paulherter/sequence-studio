//! Where the system fallback faces live (symbols, emoji, CJK, Arabic, Hebrew): the Windows `Fonts` folder by file name,
//! the Mac system font folders by file name, the Linux font folders by a shallow walk (distros put the same Noto and DejaVu
//! files in different subfolders) plus what fontconfig's `fc-match` names for each script. The portable UI draws text on
//! the CPU on all three systems (`GlyphAtlas`), so the Mac needs this list too; Core Text is not involved.

use sq_os::Platform;
use std::ffi::OsString;
use std::path::{Path, PathBuf};

/// What the faces are looked up for.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FallbackRole {
    /// Other scripts and everything the UI faces lack: first match wins per scalar.
    Script,
    /// Symbols and emoji of the text path.
    Symbol,
    /// The color emoji font ([`crate::emoji_font::EmojiFont`]): bitmap (`sbix`, `CBDT`) or layered (`COLR`).
    Emoji,
}

/// How deep below a Linux font folder a file may sit (`/usr/share/fonts/opentype/noto/X.ttc` is 2).
const LINUX_DEPTH: usize = 4;

/// Namespace of the lookup.
pub enum FallbackFontFiles {}

impl FallbackFontFiles {
    /// The file names to look for, best first.
    pub fn names(platform: Platform, role: FallbackRole) -> &'static [&'static str] {
        match (platform, role) {
            // Outline fonts only (`glyf` or CFF): Apple Color Emoji is bitmap (`sbix`) and would draw blank here; the Emoji role
            // below opens it for color. PingFang lives in a
            // hashed downloadable-asset folder on recent systems, so Hiragino, Apple SD Gothic Neo, STHeiti and Arial Unicode
            // carry the CJK scripts.
            (Platform::Mac, FallbackRole::Script) => &[
                "SFArabic.ttf",
                "SFHebrew.ttf",
                "GeezaPro.ttc",
                "Hiragino Sans GB.ttc",
                "AppleSDGothicNeo.ttc",
                "ヒラギノ角ゴシック W3.ttc",
                "STHeiti Light.ttc",
                "Apple Symbols.ttf",
                "Arial Unicode.ttf",
            ],
            (Platform::Mac, FallbackRole::Emoji) => &["Apple Color Emoji.ttc"],
            (Platform::Windows, FallbackRole::Emoji) => &["seguiemj.ttf"],
            (Platform::Linux, FallbackRole::Emoji) => &["NotoColorEmoji.ttf"],
            (Platform::Mac, FallbackRole::Symbol) => &["Apple Symbols.ttf", "Arial Unicode.ttf"],
            (Platform::Windows, FallbackRole::Script) => &[
                "segoeui.ttf",
                "msyh.ttc",
                "malgun.ttf",
                "YuGothM.ttc",
                "YuGothR.ttc",
                "msjh.ttc",
                "simsun.ttc",
                "arial.ttf",
                "tahoma.ttf",
                "seguisym.ttf",
                "seguiemj.ttf",
            ],
            (Platform::Windows, FallbackRole::Symbol) => &["seguiemj.ttf", "seguisym.ttf"],
            (Platform::Linux, FallbackRole::Script) => &[
                "NotoSans-Regular.ttf",
                "NotoSansCJK-Regular.ttc",
                "NotoSansArabic-Regular.ttf",
                "NotoSansArabicUI-Regular.ttf",
                "NotoNaskhArabic-Regular.ttf",
                "NotoNaskhArabicUI-Regular.ttf",
                "NotoKufiArabic-Regular.ttf",
                "NotoSansHebrew-Regular.ttf",
                "NotoSansCJKjp-Regular.otf",
                "NotoSansCJKsc-Regular.otf",
                "NanumGothic.ttf",
                "DroidSansFallbackFull.ttf",
                "wqy-microhei.ttc",
                "DejaVuSans.ttf",
                "NotoSansSymbols2-Regular.ttf",
                "NotoSansSymbols-Regular.ttf",
            ],
            (Platform::Linux, FallbackRole::Symbol) => {
                &["NotoSansSymbols2-Regular.ttf", "NotoSansSymbols-Regular.ttf", "DejaVuSans.ttf"]
            }
        }
    }

    /// The folders searched, in order; empty when the environment names none.
    pub fn roots(platform: Platform, env: impl Fn(&str) -> Option<OsString>) -> Vec<PathBuf> {
        let var = |name: &str| env(name).filter(|v| !v.is_empty()).map(PathBuf::from);
        match platform {
            Platform::Mac => ["/System/Library/Fonts", "/System/Library/Fonts/Supplemental", "/Library/Fonts"]
                .iter()
                .map(PathBuf::from)
                .collect(),
            Platform::Windows => {
                var("SystemRoot").or_else(|| var("windir")).map(|r| r.join("Fonts")).into_iter().collect()
            }
            Platform::Linux => {
                let mut roots = Vec::new();
                if let Some(data) = platform.data_dir(&env) {
                    roots.push(data.join("fonts"));
                }
                if let Some(home) = platform.home_dir(&env) {
                    roots.push(home.join(".fonts"));
                }
                roots.push(PathBuf::from("/usr/local/share/fonts"));
                roots.push(PathBuf::from("/usr/share/fonts"));
                roots
            }
        }
    }

    /// The files of `names` that exist under `roots`, in the order of `names` (one file per name, the first root wins).
    pub fn locate(platform: Platform, roots: &[PathBuf], names: &[&str]) -> Vec<PathBuf> {
        let depth = if platform == Platform::Linux { LINUX_DEPTH } else { 0 };
        names.iter().filter_map(|n| roots.iter().find_map(|r| find_file(r, n, depth))).collect()
    }

    /// The fallback faces of this machine for `role`: the named files, then (Linux, scripts) what fontconfig picks.
    pub fn find(platform: Platform, role: FallbackRole, env: impl Fn(&str) -> Option<OsString>) -> Vec<PathBuf> {
        let mut files = Self::locate(platform, &Self::roots(platform, env), Self::names(platform, role));
        if platform == Platform::Linux && role != FallbackRole::Symbol && cfg!(target_os = "linux") {
            let queries: &[&str] = if role == FallbackRole::Emoji { &[EMOJI_QUERY] } else { &FONTCONFIG_QUERIES };
            for query in queries.iter().copied() {
                if let Some(file) = fontconfig_file(query)
                    && !files.contains(&file)
                {
                    files.push(file);
                }
            }
        }
        files
    }
}

/// What `fc-match` is asked for: Arabic, Hebrew, the three CJK languages and one emoji scalar.
const FONTCONFIG_QUERIES: [&str; 6] = [":lang=ar", ":lang=he", ":lang=zh-cn", ":lang=ja", ":lang=ko", EMOJI_QUERY];
const EMOJI_QUERY: &str = ":charset=1f600";

/// The file `fc-match` names best for `query`; `None` without fontconfig or when the answer is no file.
// shortcut: runs the `fc-match` tool (no fontconfig crate in the tree); upgrade to the crate if the call shows in startup.
fn fontconfig_file(query: &str) -> Option<PathBuf> {
    let out = std::process::Command::new("fc-match")
        .args(["-f", "%{file}", query])
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .output()
        .ok()?;
    let text = String::from_utf8(out.stdout).ok()?;
    let path = PathBuf::from(text.trim());
    path.is_file().then_some(path)
}

/// `name` directly in `dir`, else (while `depth` lasts) in a subfolder, folders in name order.
fn find_file(dir: &Path, name: &str, depth: usize) -> Option<PathBuf> {
    let direct = dir.join(name);
    if direct.is_file() {
        return Some(direct);
    }
    if depth == 0 {
        return None;
    }
    let mut subs: Vec<PathBuf> =
        std::fs::read_dir(dir).ok()?.flatten().map(|e| e.path()).filter(|p| p.is_dir()).collect();
    subs.sort();
    subs.iter().find_map(|s| find_file(s, name, depth - 1))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn env(pairs: &'static [(&'static str, &'static str)]) -> impl Fn(&str) -> Option<OsString> {
        move |k| pairs.iter().find(|(n, _)| *n == k).map(|(_, v)| OsString::from(*v))
    }

    #[test]
    fn names_per_system() {
        assert!(FallbackFontFiles::names(Platform::Mac, FallbackRole::Script).contains(&"Hiragino Sans GB.ttc"));
        assert!(FallbackFontFiles::names(Platform::Mac, FallbackRole::Symbol).contains(&"Apple Symbols.ttf"));
        assert_eq!(FallbackFontFiles::names(Platform::Windows, FallbackRole::Symbol), ["seguiemj.ttf", "seguisym.ttf"]);
        assert!(FallbackFontFiles::names(Platform::Windows, FallbackRole::Script).contains(&"msyh.ttc"));
        assert!(FallbackFontFiles::names(Platform::Linux, FallbackRole::Script).contains(&"NotoSansCJK-Regular.ttc"));
        assert!(FallbackFontFiles::names(Platform::Linux, FallbackRole::Symbol).contains(&"DejaVuSans.ttf"));
        assert_eq!(FallbackFontFiles::names(Platform::Mac, FallbackRole::Emoji), ["Apple Color Emoji.ttc"]);
        assert_eq!(FallbackFontFiles::names(Platform::Windows, FallbackRole::Emoji), ["seguiemj.ttf"]);
        assert_eq!(FallbackFontFiles::names(Platform::Linux, FallbackRole::Emoji), ["NotoColorEmoji.ttf"]);
    }

    #[test]
    fn roots_per_system() {
        let e = env(&[("HOME", "/u"), ("SystemRoot", "C:/W"), ("XDG_DATA_HOME", "/x")]);
        assert!(FallbackFontFiles::roots(Platform::Mac, &e).contains(&PathBuf::from("/System/Library/Fonts")));
        assert_eq!(FallbackFontFiles::roots(Platform::Windows, &e), [PathBuf::from("C:/W").join("Fonts")]);
        assert_eq!(
            FallbackFontFiles::roots(Platform::Windows, env(&[("windir", "D:/W")])),
            [PathBuf::from("D:/W/Fonts")]
        );
        assert!(FallbackFontFiles::roots(Platform::Windows, env(&[])).is_empty());
        let linux = FallbackFontFiles::roots(Platform::Linux, &e);
        assert_eq!(linux[0], PathBuf::from("/x/fonts"));
        assert_eq!(linux[1], PathBuf::from("/u/.fonts"));
        assert!(linux.contains(&PathBuf::from("/usr/share/fonts")));
        assert!(!FallbackFontFiles::roots(Platform::Linux, env(&[])).is_empty());
    }

    #[test]
    fn locate_walks_linux_folders_but_only_looks_flat_on_windows() {
        let root = std::env::temp_dir().join(format!("sq-fallback-fonts-{}", std::process::id()));
        let deep = root.join("opentype").join("noto");
        std::fs::create_dir_all(&deep).unwrap_or_default();
        std::fs::write(deep.join("NotoSansCJK-Regular.ttc"), b"x").unwrap_or_default();
        std::fs::write(root.join("DejaVuSans.ttf"), b"x").unwrap_or_default();
        let roots = [root.clone()];
        let names = ["NotoSansCJK-Regular.ttc", "missing.ttf", "DejaVuSans.ttf"];
        assert_eq!(
            FallbackFontFiles::locate(Platform::Linux, &roots, &names),
            [deep.join("NotoSansCJK-Regular.ttc"), root.join("DejaVuSans.ttf")]
        );
        assert_eq!(FallbackFontFiles::locate(Platform::Windows, &roots, &names), [root.join("DejaVuSans.ttf")]);
        std::fs::remove_dir_all(&root).unwrap_or_default();
    }
}
