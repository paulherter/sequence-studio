// Swift: PasteMedia.swift:6 (`PasteMedia.read(from:)`), ShellPasteMedia.swift (`mediaClipboard`)
//! What the system clipboard holds that can become media, for Paste in the Project panel and the timeline.
//!
//! The rule lives here once ([`read_paste_content`]: files that exist win, else a picture as PNG); the system only
//! answers two questions through [`ClipboardSource`]. [`SystemClipboard`] answers them with `arboard` on all three
//! systems: file lists (Windows CF_HDROP, Mac file URLs, Linux `text/uri-list`) and pictures (Windows CF_DIB/PNG, Mac
//! PNG/TIFF, Linux `image/png`).

use sq_editor_session::PasteContent;
use std::cell::RefCell;
use std::path::PathBuf;
use std::time::{Duration, Instant};

/// The two reads that differ per system.
pub trait ClipboardSource {
    /// The file paths on the clipboard (a copied file in the file manager).
    fn file_paths(&self) -> Vec<PathBuf>;
    /// A copied picture as PNG data (a screenshot, an image copied from an app or a browser).
    fn image_png(&self) -> Option<Vec<u8>>;
}

/// Existing files first (a path that is gone cannot be imported), else the picture; both empty = nothing to paste.
// Swift: PasteMedia.swift:6
pub fn read_paste_content(source: &dyn ClipboardSource) -> PasteContent {
    let files: Vec<PathBuf> = source.file_paths().into_iter().filter(|p| p.exists()).collect();
    if !files.is_empty() {
        return PasteContent::new(files, None);
    }
    PasteContent::new(Vec::new(), source.image_png().filter(|png| !png.is_empty()))
}

/// How long a clipboard read is reused: the shell asks on every frame whether Paste is enabled, and a copied
/// screenshot must not be decoded and encoded again each time. Nobody copies in another app and pastes back here within it.
const REUSE: Duration = Duration::from_millis(500);

/// The clipboard reader the shell's `media_clipboard` hook answers from.
pub struct MediaClipboard {
    source: Box<dyn ClipboardSource>,
    last: RefCell<Option<(Instant, PasteContent)>>,
}

impl MediaClipboard {
    /// A reader over `source`.
    pub fn new(source: Box<dyn ClipboardSource>) -> MediaClipboard {
        MediaClipboard { source, last: RefCell::new(None) }
    }

    /// A reader over the system clipboard.
    pub fn system() -> MediaClipboard {
        MediaClipboard::new(Box::new(SystemClipboard))
    }

    /// The clipboard now (a read younger than [`REUSE`] is reused).
    pub fn read(&self) -> PasteContent {
        self.read_at(Instant::now())
    }

    fn read_at(&self, now: Instant) -> PasteContent {
        if let Some((at, content)) = self.last.borrow().as_ref()
            && now.saturating_duration_since(*at) < REUSE
        {
            return content.clone();
        }
        let content = read_paste_content(&*self.source);
        *self.last.borrow_mut() = Some((now, content.clone()));
        content
    }
}

/// The system clipboard through `arboard`; a clipboard that cannot be opened (no display, held by another app) holds
/// nothing.
struct SystemClipboard;

impl ClipboardSource for SystemClipboard {
    fn file_paths(&self) -> Vec<PathBuf> {
        arboard::Clipboard::new().ok().and_then(|mut c| c.get().file_list().ok()).unwrap_or_default()
    }

    fn image_png(&self) -> Option<Vec<u8>> {
        let image = arboard::Clipboard::new().ok()?.get_image().ok()?;
        encode_png(image.width, image.height, &image.bytes)
    }
}

/// RGBA8 pixels as PNG data (the shell writes it into the pasted image's file).
fn encode_png(width: usize, height: usize, rgba: &[u8]) -> Option<Vec<u8>> {
    let mut out = Vec::new();
    let mut enc = png::Encoder::new(&mut out, u32::try_from(width).ok()?, u32::try_from(height).ok()?);
    enc.set_color(png::ColorType::Rgba);
    enc.set_depth(png::BitDepth::Eight);
    let mut writer = enc.write_header().ok()?;
    writer.write_image_data(rgba).ok()?;
    writer.finish().ok()?;
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;
    use std::rc::Rc;

    #[derive(Default)]
    struct Fake {
        files: Vec<PathBuf>,
        png: Option<Vec<u8>>,
        reads: Rc<Cell<u32>>,
    }

    impl ClipboardSource for Fake {
        fn file_paths(&self) -> Vec<PathBuf> {
            self.reads.set(self.reads.get() + 1);
            self.files.clone()
        }
        fn image_png(&self) -> Option<Vec<u8>> {
            self.png.clone()
        }
    }

    fn real_file(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join("sq-paste-clipboard-tests");
        std::fs::create_dir_all(&dir).expect("dir");
        let file = dir.join(name);
        std::fs::write(&file, b"x").expect("file");
        file
    }

    #[test]
    fn files_that_exist_win_over_a_picture() {
        let file = real_file("a.mov");
        let c = read_paste_content(&Fake { files: vec![file.clone()], png: Some(vec![1]), ..Fake::default() });
        assert_eq!(c, PasteContent::new(vec![file], None));
    }

    #[test]
    fn a_path_that_is_gone_is_dropped_and_the_picture_is_used() {
        let gone = PathBuf::from("/sq-no-such-folder/gone.mov");
        let c = read_paste_content(&Fake { files: vec![gone], png: Some(vec![1, 2]), ..Fake::default() });
        assert_eq!(c, PasteContent::new(Vec::new(), Some(vec![1, 2])));
    }

    #[test]
    fn an_empty_clipboard_or_an_empty_picture_is_nothing() {
        assert!(!read_paste_content(&Fake::default()).has_media());
        assert!(!read_paste_content(&Fake { png: Some(Vec::new()), ..Fake::default() }).has_media());
    }

    #[test]
    fn a_read_is_reused_for_a_moment_and_then_made_again() {
        let reads = Rc::new(Cell::new(0));
        let clip = MediaClipboard::new(Box::new(Fake { reads: Rc::clone(&reads), ..Fake::default() }));
        let t0 = Instant::now();
        clip.read_at(t0);
        clip.read_at(t0 + REUSE / 2);
        assert_eq!(reads.get(), 1, "the shell's per-frame asks do not read the system again");
        clip.read_at(t0 + REUSE);
        assert_eq!(reads.get(), 2, "a copy made since is seen");
    }

    #[test]
    fn rgba_pixels_become_a_png_that_decodes_to_the_same_pixels() {
        let rgba = [255, 0, 0, 255, 0, 255, 0, 128];
        let data = encode_png(2, 1, &rgba).expect("png");
        let mut reader = png::Decoder::new(std::io::Cursor::new(data)).read_info().expect("header");
        let mut pixels = vec![0; reader.output_buffer_size().expect("size")];
        let info = reader.next_frame(&mut pixels).expect("frame");
        assert_eq!((info.width, info.height, info.color_type), (2, 1, png::ColorType::Rgba));
        assert_eq!(&pixels[..8], &rgba);
        assert!(encode_png(2, 1, &rgba[..4]).is_none(), "too few pixels is not a picture");
    }
}
