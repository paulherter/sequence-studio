// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: BundledFonts.swift (registration with the OS is the platform's job; files are found under a fonts root)

//! Open-source fonts that ship with the app (all SIL OFL 1.1, each with its own `OFL.txt` next to the files in
//! `Resources/Fonts/Families/<folder>`). Only the weights creators use are bundled: variable fonts carry their whole
//! weight range, static families only the listed faces. Inter (the default font) is bundled separately, see `inter_font`.

use crate::inter_font;
use sq_core_time::text::standard_compare;
use std::path::{Path, PathBuf};

/// Kind of a bundled family.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Category {
    /// Impact titles.
    Impact,
    /// Sans serif.
    Sans,
    /// Rounded.
    Rounded,
    /// Serif.
    Serif,
    /// Script.
    Script,
    /// Display.
    Display,
}

/// One bundled font family.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Family {
    /// Family name as the platform reports it (what `TextStyle.font_name` holds).
    pub name: &'static str,
    /// Folder under `Resources/Fonts/Families`.
    pub folder: &'static str,
    /// Font files (without extension) in that folder.
    pub files: &'static [&'static str],
    /// Kind.
    pub category: Category,
}

const fn fam(name: &'static str, folder: &'static str, files: &'static [&'static str], category: Category) -> Family {
    Family { name, folder, files, category }
}

/// ~25 families typical for titles and captions. License of every entry is OFL 1.1 (checked per `OFL.txt`).
pub const FAMILIES: [Family; 25] = [
    fam("Bebas Neue", "bebasneue", &["BebasNeue-Regular"], Category::Impact),
    fam("Anton", "anton", &["Anton-Regular"], Category::Impact),
    fam("Oswald", "oswald", &["Oswald[wght]"], Category::Impact),
    fam("Archivo Black", "archivoblack", &["ArchivoBlack-Regular"], Category::Impact),
    fam("League Spartan", "leaguespartan", &["LeagueSpartan[wght]"], Category::Impact),
    fam("Passion One", "passionone", &["PassionOne-Regular"], Category::Impact),
    fam("Russo One", "russoone", &["RussoOne-Regular"], Category::Impact),
    fam("Montserrat", "montserrat", &["Montserrat[wght]"], Category::Sans),
    fam("Poppins", "poppins", &["Poppins-Medium", "Poppins-Bold", "Poppins-ExtraBold"], Category::Sans),
    fam("Rubik", "rubik", &["Rubik[wght]"], Category::Sans),
    fam("Space Grotesk", "spacegrotesk", &["SpaceGrotesk[wght]"], Category::Sans),
    fam("Outfit", "outfit", &["Outfit[wght]"], Category::Sans),
    fam("Fredoka", "fredoka", &["Fredoka[wdth,wght]"], Category::Rounded),
    fam("Lilita One", "lilitaone", &["LilitaOne-Regular"], Category::Rounded),
    fam("Righteous", "righteous", &["Righteous-Regular"], Category::Rounded),
    fam("Playfair Display", "playfairdisplay", &["PlayfairDisplay[wght]"], Category::Serif),
    fam("DM Serif Display", "dmserifdisplay", &["DMSerifDisplay-Regular"], Category::Serif),
    fam("Pacifico", "pacifico", &["Pacifico-Regular"], Category::Script),
    fam("Lobster", "lobster", &["Lobster-Regular"], Category::Script),
    fam("Caveat", "caveat", &["Caveat[wght]"], Category::Script),
    fam("Knewave", "knewave", &["Knewave-Regular"], Category::Script),
    fam("Bangers", "bangers", &["Bangers-Regular"], Category::Display),
    fam("Bungee", "bungee", &["Bungee-Regular"], Category::Display),
    fam("Bowlby One", "bowlbyone", &["BowlbyOne-Regular"], Category::Display),
    fam("Sigmar One", "sigmarone", &["SigmarOne-Regular"], Category::Display),
];

/// Names for pickers: the default font first, then the bundled families A to Z.
pub fn picker_names() -> Vec<String> {
    let mut names: Vec<&str> = FAMILIES.iter().map(|f| f.name).collect();
    names.sort_by(|a, b| standard_compare(a, b));
    std::iter::once(inter_font::FAMILY_NAME).chain(names).map(str::to_string).collect()
}

/// Whether `name` is Inter or a bundled family.
pub fn is_bundled(name: &str) -> bool {
    name == inter_font::FAMILY_NAME || FAMILIES.iter().any(|f| f.name == name)
}

/// Paths of the family's font files that exist under `fonts_root` (the package's `Resources/Fonts`).
pub fn font_urls(family: &Family, fonts_root: &Path) -> Vec<PathBuf> {
    let dir = fonts_root.join("Families").join(family.folder);
    family.files.iter().map(|f| dir.join(format!("{f}.ttf"))).filter(|p| p.is_file()).collect()
}

/// The family's `OFL.txt`, if it exists.
pub fn license_url(family: &Family, fonts_root: &Path) -> Option<PathBuf> {
    Some(fonts_root.join("Families").join(family.folder).join("OFL.txt")).filter(|p| p.is_file())
}

/// The fonts folder of the Swift package, for tests (fonts are never copied into the crate).
#[cfg(test)]
pub(crate) fn test_fonts_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../Packages/SQText/Sources/SQText/Resources/Fonts")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn catalog_has_about_twenty_five_unique_families() {
        let names: Vec<&str> = FAMILIES.iter().map(|f| f.name).collect();
        assert!(names.len() >= 25);
        let unique: std::collections::BTreeSet<&&str> = names.iter().collect();
        assert_eq!(unique.len(), names.len());
        assert_eq!(picker_names().first().map(String::as_str), Some("Inter"));
        assert!(is_bundled("Anton") && !is_bundled("Helvetica"));
    }

    #[test]
    fn every_family_ships_files_and_an_ofl_licence() {
        let root = test_fonts_root();
        for fam in &FAMILIES {
            assert_eq!(font_urls(fam, &root).len(), fam.files.len(), "files of {}", fam.name);
            let text = license_url(fam, &root).and_then(|u| std::fs::read_to_string(u).ok());
            let text = text.unwrap_or_default();
            assert!(text.to_uppercase().contains("OPEN FONT LICENSE"), "{} license is not OFL", fam.name);
            assert!(text.contains("Copyright"), "{} license lacks a copyright line", fam.name);
        }
    }
}
