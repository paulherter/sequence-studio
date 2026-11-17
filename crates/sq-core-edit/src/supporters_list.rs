//! Port of `SupportersList.swift`: the Supporters list, one name per line in the bundled `SUPPORTERS.md`. Blank lines and
//! lines starting with `#` are ignored.

use std::collections::BTreeSet;

/// `enum SupportersList`.
pub struct SupportersList;

impl SupportersList {
    /// Bundled file name.
    pub const FILE_NAME: &'static str = "SUPPORTERS";
    /// Bundled file extension.
    pub const FILE_EXTENSION: &'static str = "md";

    /// Names in file order, trimmed, duplicates (case-insensitive) removed keeping the first.
    pub fn parse(text: &str) -> Vec<String> {
        let mut seen = BTreeSet::new();
        let mut names = Vec::new();
        // Swift `Character.isNewline`: LF, VT, FF, CR, NEL, LS, PS (CR LF is one character, empty pieces are dropped).
        for raw in text.split(['\n', '\u{0B}', '\u{0C}', '\r', '\u{85}', '\u{2028}', '\u{2029}']) {
            let line = sq_core_model::trim_spaces(raw, false);
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            if seen.insert(line.to_lowercase()) {
                names.push(line.to_string());
            }
        }
        names
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_and_only_comments_give_no_names() {
        assert!(SupportersList::parse("").is_empty());
        assert!(SupportersList::parse("# header\n\n   \n# more\n").is_empty());
    }

    #[test]
    fn trims_whitespace_and_keeps_order() {
        assert_eq!(SupportersList::parse("  Zoe \n# skip\n\nAdam\r\n\tMia  \n"), ["Zoe", "Adam", "Mia"]);
    }

    #[test]
    fn removes_duplicates_keeping_first() {
        assert_eq!(SupportersList::parse("Ann\nBob\nann\nBob \nCy"), ["Ann", "Bob", "Cy"]);
    }
}
