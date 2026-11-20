//! Cuts in the middle for text that must keep both ends. A file path loses folders from its middle and keeps its start
//! (`~/Movies/`) and its file name; cutting it at a word boundary instead left nothing of a path without spaces.

const ELLIPSIS: char = '\u{2026}';

fn is_sep(c: char) -> bool {
    c == '/' || c == '\\'
}

/// `text` with its middle replaced by an ellipsis until `fits` accepts it; the text itself when it already fits. Both
/// ends stay as long as anything does (AppKit `byTruncatingMiddle`).
pub fn fit_middle(text: &str, fits: impl Fn(&str) -> bool) -> String {
    if fits(text) {
        return text.to_string();
    }
    let chars: Vec<char> = text.chars().collect();
    let join = |head: usize, tail: usize| {
        format!(
            "{}{ELLIPSIS}{}",
            chars[..head].iter().collect::<String>(),
            chars[chars.len() - tail..].iter().collect::<String>()
        )
    };
    let (mut head, mut tail) = (chars.len() / 2, chars.len() - chars.len() / 2);
    while head + tail > 0 && !fits(&join(head, tail)) {
        if tail >= head {
            tail -= 1;
        } else {
            head -= 1;
        }
    }
    join(head, tail)
}

/// The folders and the file name of `path`, each folder with its trailing separator; a leading separator (or run of them,
/// `\\server\`) belongs to the first folder.
fn path_parts(path: &str) -> Vec<&str> {
    let lead = path.len() - path.trim_start_matches(is_sep).len();
    let mut parts = Vec::new();
    let mut start = 0;
    for (i, c) in path.char_indices() {
        if is_sep(c) && i >= lead {
            parts.push(&path[start..=i]);
            start = i + 1;
        }
    }
    if start < path.len() {
        parts.push(&path[start..]);
    }
    parts
}

/// `path` cut until `fits` accepts it: whole folders go from the middle (`~/Movies/…/Sequence 01.mp4`), the start and the
/// file name stay, and as many folders at both ends as fit. A file name too long for that is cut inside itself by
/// [`fit_middle`]. Both separator styles work on every system (a Windows path read on a Mac).
pub fn fit_path(path: &str, fits: impl Fn(&str) -> bool) -> String {
    if fits(path) {
        return path.to_string();
    }
    let parts = path_parts(path);
    let n = parts.len();
    let Some(sep) = parts.first().and_then(|p| p.chars().last()).filter(|c| is_sep(*c)) else {
        return fit_middle(path, fits);
    };
    if n < 3 {
        return fit_middle(path, fits);
    }
    let candidate =
        |head: usize, tail: usize| format!("{}{ELLIPSIS}{sep}{}", parts[..head].concat(), parts[n - tail..].concat());
    if !fits(&candidate(1, 1)) {
        return fit_middle(path, fits);
    }
    let (mut head, mut tail) = (1, 1);
    loop {
        let mut grew = false;
        if head + tail < n - 1 && fits(&candidate(head + 1, tail)) {
            head += 1;
            grew = true;
        }
        if head + tail < n - 1 && fits(&candidate(head, tail + 1)) {
            tail += 1;
            grew = true;
        }
        if !grew {
            return candidate(head, tail);
        }
    }
}

/// The text a cut label shows, and what a tooltip must say when it is cut. The one answer to "this text does not fit its
/// box" (FUNDE pattern 1): every label that can overflow builds one of these, draws `shown` and offers `tip()` to the
/// pointer (`Hover::offer_truncated`), so nothing is cut without the full text one hover away.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TruncatedLabel {
    /// What to draw: the whole text when it fits, else the Finder-style cut.
    pub shown: String,
    /// The whole text when `shown` is a cut of it, else `None`.
    pub full: Option<String>,
}

impl TruncatedLabel {
    /// The tooltip text: the full text, only when the label is cut.
    pub fn tip(&self) -> Option<&str> {
        self.full.as_deref()
    }
}

/// The file extension of `name` with its dot (".mov"): the last dot that is not the first character, followed by 1 to 8
/// letters or digits. `None` for names without one ("Interview 2. take", "archive.").
fn extension_start(name: &str) -> Option<usize> {
    let dot = name.rfind('.')?;
    let ext = &name[dot + 1..];
    (dot > 0 && (1..=8).contains(&ext.chars().count()) && ext.chars().all(char::is_alphanumeric)).then_some(dot)
}

/// A file or item name cut like the Finder: the start of the name and its extension stay, the middle becomes an ellipsis
/// (`Interview Final Cu…v3.mov` loses the end of the stem, never the `.mov`). A name without an extension is cut in
/// its middle by [`fit_middle`]. The name itself when `fits` accepts it.
pub fn fit_name(name: &str, fits: impl Fn(&str) -> bool) -> String {
    if fits(name) {
        return name.to_string();
    }
    let Some(dot) = extension_start(name) else { return fit_middle(name, fits) };
    let (stem, ext) = name.split_at(dot);
    let chars: Vec<char> = stem.chars().collect();
    let join = |head: usize| format!("{}{ELLIPSIS}{ext}", chars[..head].iter().collect::<String>());
    let mut head = chars.len();
    while head > 0 && !fits(&join(head)) {
        head -= 1;
    }
    if head == 0 && !fits(&join(0)) { fit_middle(name, fits) } else { join(head) }
}

/// [`fit_name`] packed with the tooltip: `full` is set exactly when the name had to be cut.
pub fn truncate_name(name: &str, fits: impl Fn(&str) -> bool) -> TruncatedLabel {
    let shown = fit_name(name, fits);
    let full = (shown != name).then(|| name.to_string());
    TruncatedLabel { shown, full }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn within(width: usize) -> impl Fn(&str) -> bool {
        move |t| t.chars().count() <= width
    }

    #[test]
    fn a_text_that_fits_stays_whole() {
        assert_eq!(fit_middle("short", within(10)), "short");
        assert_eq!(fit_path("~/Movies/a.mp4", within(40)), "~/Movies/a.mp4");
    }

    #[test]
    fn a_middle_cut_keeps_both_ends() {
        let cut = fit_middle("A001_C002_long_camera_original_name.mov", within(20));
        assert!(cut.starts_with("A001") && cut.ends_with(".mov") && cut.contains('\u{2026}'), "{cut}");
        assert!(cut.chars().count() <= 20);
        assert_eq!(fit_middle("abc", within(0)), "\u{2026}");
    }

    #[test]
    fn a_path_loses_its_middle_folders_and_keeps_the_start_and_the_file_name() {
        let path = "~/Movies/Client Work/2026/Spring Campaign/Sequence 01.mp4";
        assert_eq!(fit_path(path, within(30)), "~/Movies/\u{2026}/Sequence 01.mp4");
        assert_eq!(fit_path(path, within(20)), "~/\u{2026}/Sequence 01.mp4");
        assert_eq!(fit_path(path, within(44)), "~/Movies/\u{2026}/Spring Campaign/Sequence 01.mp4");
        assert_eq!(fit_path(path, within(48)), "~/Movies/\u{2026}/2026/Spring Campaign/Sequence 01.mp4");
    }

    #[test]
    fn a_path_without_spaces_never_collapses() {
        let cut = fit_path("/Users/anna/Library/Containers/very-long-folder/export.mp4", within(26));
        assert_eq!(cut, "/Users/anna/\u{2026}/export.mp4");
    }

    #[test]
    fn windows_paths_cut_the_same_way_on_every_system() {
        let cut = fit_path("C:\\Users\\anna\\Videos\\Projects\\Sequence 01.mp4", within(30));
        assert_eq!(cut, "C:\\Users\\\u{2026}\\Sequence 01.mp4");
        let share = fit_path("\\\\server\\share\\a\\b\\c\\file.mp4", within(22));
        assert!(share.starts_with("\\\\server\\") && share.ends_with("\\file.mp4"), "{share}");
    }

    #[test]
    fn a_file_name_too_long_for_the_folders_is_cut_inside() {
        let cut = fit_path("~/Movies/a-very-long-file-name-for-an-export.mp4", within(24));
        assert!(cut.starts_with("~/Movies/") && cut.ends_with(".mp4") && cut.contains('\u{2026}'), "{cut}");
        assert!(cut.chars().count() <= 24);
        let bare = fit_path("a-very-long-file-name-for-an-export.mp4", within(16));
        assert!(bare.starts_with("a-ver") && bare.ends_with(".mp4"), "{bare}");
    }

    #[test]
    fn a_name_keeps_its_start_and_its_extension() {
        let name = "Interview Final Cut v3.mov";
        let cut = fit_name(name, within(15));
        assert!(cut.starts_with("Interview") && cut.ends_with(".mov") && cut.contains('\u{2026}'), "{cut}");
        assert!(cut.chars().count() <= 15);
        assert_eq!(fit_name(name, within(40)), name);
        // Too narrow for the extension plus anything: falls back to the middle cut.
        assert!(fit_name(name, within(3)).chars().count() <= 3);
        // No extension: middle cut, both ends.
        let plain = fit_name("A very long title without a dot at all", within(16));
        assert!(plain.starts_with("A ve") && plain.ends_with("all") && plain.chars().count() <= 16, "{plain}");
    }

    #[test]
    fn a_cut_label_registers_the_full_text_as_its_tooltip() {
        let name = "Interview Final Cut v3.mov";
        let cut = truncate_name(name, within(15));
        assert_eq!(cut.tip(), Some(name));
        assert_ne!(cut.shown, name);
        let whole = truncate_name("a.mov", within(15));
        assert_eq!((whole.shown.as_str(), whole.tip()), ("a.mov", None));
    }
}
