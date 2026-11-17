// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: InterFont.swift (font registration is the platform's job; this module names the bundled files)

use std::path::{Path, PathBuf};

/// Family name of the default text font.
pub const FAMILY_NAME: &str = "Inter";

/// File stems of the two variable fonts (upright first, then italic) under the package's `Resources/Fonts`.
pub const FILE_STEMS: [&str; 2] = ["Inter-VariableFont_opsz,wght", "Inter-Italic-VariableFont_opsz,wght"];

/// Paths of the bundled font files that exist under `fonts_root` (upright first, then italic).
pub fn font_urls(fonts_root: &Path) -> Vec<PathBuf> {
    FILE_STEMS.iter().map(|s| fonts_root.join(format!("{s}.ttf"))).filter(|p| p.is_file()).collect()
}

/// The license text that ships next to the fonts.
pub fn license_url(fonts_root: &Path) -> Option<PathBuf> {
    Some(fonts_root.join("OFL.txt")).filter(|p| p.is_file())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bundled_files_and_licence_ship() {
        let root = crate::bundled_fonts::test_fonts_root();
        assert_eq!(font_urls(&root).len(), 2);
        let license = license_url(&root).and_then(|u| std::fs::read_to_string(u).ok());
        assert!(license.is_some_and(|s| s.contains("SIL OPEN FONT LICENSE Version 1.1")));
    }

    #[test]
    fn new_text_defaults_to_inter_but_saved_styles_keep_their_font() {
        use crate::text_style::TextStyle;
        assert_eq!(TextStyle::default().font_name, "Inter");
        let old = TextStyle { font_name: "Helvetica".into(), size: 50.0, ..TextStyle::default() };
        let back: Result<TextStyle, _> = serde_json::from_str(&serde_json::to_string(&old).unwrap_or_default());
        assert_eq!(back.map(|b| b.font_name).ok().as_deref(), Some("Helvetica"));
    }
}
