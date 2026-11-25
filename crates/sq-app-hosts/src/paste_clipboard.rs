// Swift: PasteMedia.swift:6 (`PasteMedia.read(from:)`), ShellPasteMedia.swift (`mediaClipboard`)
//! What the system clipboard holds that can become media, for Paste in the Project panel and the timeline.
//!
//! The rule lives here once ([`read_paste_content`]: files that exist win, else a picture as PNG); the system only
//! answers two questions through [`ClipboardSource`]. [`SystemClipboard`] answers them with `arboard` on all three
//! systems: file lists (Windows CF_HDROP, Mac file URLs, Linux `text/uri-list`) and pictures (Windows CF_DIB/PNG, Mac
//! PNG/TIFF, Linux `image/png`).

use sq_editor_session::{PasteContent, PasteOffer};
use std::cell::RefCell;
use std::path::PathBuf;
use std::time::{Duration, Instant};

/// The two reads that differ per system.
pub trait ClipboardSource {
    /// The file paths on the clipboard (a copied file in the file manager).
    fn file_paths(&self) -> Vec<PathBuf>;
    /// A copied picture as PNG data (a screenshot, an image copied from an app or a browser).
    fn image_png(&self) -> Option<Vec<u8>>;
    /// Cheap facts that read no data (change token, kinds on offer); `None` = this system cannot tell cheaply.
    fn facts(&self) -> Option<sq_platform::clipboard::ClipboardFacts> {
        None
    }
    /// A copy of this reader that may run on another thread (a picture is decoded and encoded there); `None` = read here.
    fn detached(&self) -> Option<Box<dyn ClipboardSource + Send>> {
        None
    }
}

/// A clipboard read that runs off the UI thread; its result is the same [`PasteContent`] as [`MediaClipboard::read`].
pub type ClipboardJob = Box<dyn FnOnce() -> PasteContent + Send>;

/// Existing files first (a path that is gone cannot be imported), else the picture; both empty = nothing to paste.
// Swift: PasteMedia.swift:6
pub fn read_paste_content(source: &dyn ClipboardSource) -> PasteContent {
    let files: Vec<PathBuf> = source.file_paths().into_iter().filter(|p| p.exists()).collect();
    if !files.is_empty() {
        return PasteContent::new(files, None);
    }
    PasteContent::new(Vec::new(), source.image_png().filter(|png| !png.is_empty()))
}

/// How long a clipboard read is reused on a system without cheap facts (Linux): the shell asks on every frame whether
/// Paste is enabled, and a copied screenshot must not be decoded and encoded again each time.
const REUSE: Duration = Duration::from_millis(500);

/// The clipboard reader the shell's `media_clipboard` hook answers from.
pub struct MediaClipboard {
    source: Box<dyn ClipboardSource>,
    last: RefCell<Option<(Instant, PasteContent)>>,
    offer: RefCell<Option<KeptOffer>>,
    /// A timed read running on a worker thread (systems without cheap facts).
    refresh: RefCell<Option<std::sync::mpsc::Receiver<PasteContent>>>,
}

/// The offer of one clipboard state, kept until its change token moves.
type KeptOffer = (u64, PasteOffer);

impl MediaClipboard {
    /// A reader over `source`.
    pub fn new(source: Box<dyn ClipboardSource>) -> MediaClipboard {
        MediaClipboard { source, last: RefCell::new(None), offer: RefCell::new(None), refresh: RefCell::new(None) }
    }

    /// A reader over the system clipboard.
    pub fn system() -> MediaClipboard {
        MediaClipboard::new(Box::new(SystemClipboard))
    }

    /// What Paste could take, for the menu: asked every frame, so it never reads or encodes clipboard data. With cheap
    /// facts it is the kinds on offer (files are not checked for existence until Paste); without them it falls back to the
    /// timed read of [`MediaClipboard::read`].
    pub fn offer(&self) -> PasteOffer {
        match self.source.facts() {
            Some(f) => {
                let mut kept = self.offer.borrow_mut();
                match *kept {
                    Some((token, offer)) if token == f.token => offer,
                    _ => {
                        let offer = PasteOffer { has_files: f.files, has_image: f.image && !f.files };
                        *kept = Some((f.token, offer));
                        offer
                    }
                }
            }
            None => self.offer_by_timed_read(),
        }
    }

    /// Without cheap facts (Linux): the last full read answers, and a new one runs on a worker thread once the last is
    /// older than [`REUSE`], so the UI thread never decodes or encodes a picture. The offer may be one read behind.
    fn offer_by_timed_read(&self) -> PasteOffer {
        let Some(job) = self.source.detached().map(|s| move || read_paste_content(&*s)) else {
            return PasteOffer::of(&self.read()); // a source that cannot leave this thread is read here
        };
        let mut running = self.refresh.borrow_mut();
        if let Some(rx) = running.as_ref() {
            match rx.try_recv() {
                Ok(content) => {
                    *self.last.borrow_mut() = Some((Instant::now(), content));
                    *running = None;
                }
                Err(std::sync::mpsc::TryRecvError::Disconnected) => *running = None,
                Err(std::sync::mpsc::TryRecvError::Empty) => {}
            }
        }
        let stale = self.last.borrow().as_ref().is_none_or(|(at, _)| at.elapsed() >= REUSE);
        if stale && running.is_none() {
            let (tx, rx) = std::sync::mpsc::channel();
            std::thread::spawn(move || {
                let _ = tx.send(job());
            });
            *running = Some(rx);
        }
        self.last.borrow().as_ref().map(|(_, c)| PasteOffer::of(c)).unwrap_or_default()
    }

    /// The full read as a job for another thread, for Paste (a picture takes tens to hundreds of milliseconds to
    /// encode); `None` when the source must be read here.
    pub fn job(&self) -> Option<ClipboardJob> {
        let source = self.source.detached()?;
        Some(Box::new(move || read_paste_content(&*source)))
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

    fn facts(&self) -> Option<sq_platform::clipboard::ClipboardFacts> {
        sq_platform::clipboard::clipboard_facts()
    }

    fn detached(&self) -> Option<Box<dyn ClipboardSource + Send>> {
        Some(Box::new(SystemClipboard))
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
        images: Rc<Cell<u32>>,
        facts: Option<sq_platform::clipboard::ClipboardFacts>,
    }

    impl ClipboardSource for Fake {
        fn file_paths(&self) -> Vec<PathBuf> {
            self.reads.set(self.reads.get() + 1);
            self.files.clone()
        }
        fn image_png(&self) -> Option<Vec<u8>> {
            self.images.set(self.images.get() + 1);
            self.png.clone()
        }
        fn facts(&self) -> Option<sq_platform::clipboard::ClipboardFacts> {
            self.facts
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
    fn the_menu_offer_never_reads_a_big_picture() {
        use sq_platform::clipboard::ClipboardFacts;
        let (reads, images) = (Rc::new(Cell::new(0)), Rc::new(Cell::new(0)));
        let fake = Fake {
            png: Some(vec![0; 4_000_000]),
            reads: Rc::clone(&reads),
            images: Rc::clone(&images),
            facts: Some(ClipboardFacts { token: 7, files: false, image: true }),
            ..Fake::default()
        };
        let clip = MediaClipboard::new(Box::new(fake));
        for _ in 0..1000 {
            assert_eq!(clip.offer(), PasteOffer { has_files: false, has_image: true });
        }
        assert_eq!((reads.get(), images.get()), (0, 0), "a menu refresh reads no clipboard data");
    }

    #[test]
    fn without_facts_a_worker_reads_and_the_ui_thread_never_does() {
        #[derive(Default)]
        struct Linux {
            ui_reads: Rc<Cell<u32>>,
        }
        struct Worker;
        impl ClipboardSource for Worker {
            fn file_paths(&self) -> Vec<PathBuf> {
                Vec::new()
            }
            fn image_png(&self) -> Option<Vec<u8>> {
                Some(vec![1])
            }
        }
        impl ClipboardSource for Linux {
            fn file_paths(&self) -> Vec<PathBuf> {
                self.ui_reads.set(self.ui_reads.get() + 1);
                Vec::new()
            }
            fn image_png(&self) -> Option<Vec<u8>> {
                self.ui_reads.set(self.ui_reads.get() + 1);
                None
            }
            fn detached(&self) -> Option<Box<dyn ClipboardSource + Send>> {
                Some(Box::new(Worker))
            }
        }
        let reads = Rc::new(Cell::new(0));
        let clip = MediaClipboard::new(Box::new(Linux { ui_reads: Rc::clone(&reads) }));
        assert_eq!(clip.offer(), PasteOffer::default(), "the first answer does not wait for the read");
        let mut offer = PasteOffer::default();
        let deadline = Instant::now() + Duration::from_secs(10);
        while Instant::now() < deadline {
            offer = clip.offer();
            if offer.has_image {
                break;
            }
            std::thread::yield_now();
        }
        assert!(offer.has_image, "the worker's read arrives");
        assert_eq!(reads.get(), 0, "the UI-side source was never read");
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
