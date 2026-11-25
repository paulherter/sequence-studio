//! Cheap facts about the system clipboard: a change token and which kinds of content it offers. Nothing here reads or
//! decodes clipboard data, so the UI thread may ask on every frame (the Paste menu rule does).
//!
//! Mac: `NSPasteboard` change count and type names. Windows: `GetClipboardSequenceNumber` and
//! `IsClipboardFormatAvailable`. Linux has no cheap, portable owner-change signal without a display connection of our
//! own (arboard hides it), so it answers `None` and the caller falls back to a timed read.
// shortcut: Linux answers None (timed full read in sq-app-hosts); upgrade with the offered MIME types of the Wayland
// data-device / X11 selection targets.

/// What the clipboard offers right now.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ClipboardFacts {
    /// Changes whenever any app puts new content on the clipboard.
    pub token: u64,
    /// File paths are offered.
    pub files: bool,
    /// A picture is offered.
    pub image: bool,
}

/// The clipboard's facts, or `None` when this system cannot tell cheaply.
pub fn clipboard_facts() -> Option<ClipboardFacts> {
    #[cfg(target_os = "macos")]
    let raw = sq_platform_mac::clipboard_facts();
    #[cfg(windows)]
    let raw = sq_platform_win::clipboard_facts();
    #[cfg(not(any(target_os = "macos", windows)))]
    let raw: Option<(u64, bool, bool)> = None;
    raw.map(|(token, files, image)| ClipboardFacts { token, files, image })
}
