//! The viewer of the Library's video preview. The panel only draws a picture the host gives it, so this keeps one decoder
//! on the previewed file, asks it for the frame at the sound's position on every draw, packs what arrives into a cell of
//! the thumbnail atlas and tells the panel where that cell is.

use crate::poster_pump::{Placed, SharedAtlas};
use crate::preview_video::{MAX_HEIGHT, MAX_WIDTH, OpenSource, PreviewPicture, PreviewVideo};
use sq_app_shell::{ATLAS_SLOT, ImageUpload};
use sq_draw::RgbaImage;
use sq_draw_library::library::library_draw_panel::{LibraryDrawPanel, LibraryPicture};
use sq_library::library_preview_math::PreviewMode;
use sq_library::watched_folder::LibraryEntryID;
use std::sync::Arc;

pub(super) struct LivePreview {
    video: PreviewVideo,
    atlas: Option<SharedAtlas>,
    /// The atlas cell the pictures go to: reserved with the first picture, given back when the preview ends.
    cell: Option<Placed>,
    /// The file the decoder works on.
    loaded: Option<LibraryEntryID>,
    /// The newest picture, waiting for the window to copy it into the atlas.
    upload: Option<ImageUpload>,
}

impl LivePreview {
    pub(super) fn new(open: OpenSource) -> LivePreview {
        LivePreview { video: PreviewVideo::new(open), atlas: None, cell: None, loaded: None, upload: None }
    }

    /// Another decoder (tests); the atlas and the wake stay.
    #[cfg(test)]
    pub(super) fn replace_source(&mut self, open: OpenSource) {
        self.video = PreviewVideo::new(open);
    }

    /// Pictures go into `atlas`; without one the viewer keeps showing the poster.
    pub(super) fn share_atlas(&mut self, atlas: SharedAtlas) {
        self.atlas = Some(atlas);
    }

    pub(super) fn set_wake(&mut self, wake: Arc<dyn Fn() + Send + Sync>) {
        self.video.set_wake(wake);
    }

    /// Once per draw: follows the panel's preview (file, then position) and hands it the newest picture.
    pub(super) fn update(&mut self, panel: &mut LibraryDrawPanel) {
        let video = if panel.preview_mode() == Some(PreviewMode::Video) { panel.model.preview_item() } else { None };
        let Some(item) = video else {
            self.end(panel);
            return;
        };
        if self.loaded.as_ref() != Some(&item.id()) {
            let (id, url) = (item.id(), item.url.clone());
            self.end(panel);
            self.video.load(&url);
            self.loaded = Some(id);
        }
        self.video.show(panel.model.preview.seconds());
        if let Some(picture) = self.video.take() {
            self.place(picture, panel);
        }
    }

    fn place(&mut self, picture: PreviewPicture, panel: &mut LibraryDrawPanel) {
        let Some(atlas) = &self.atlas else { return };
        let cell = match self.cell {
            Some(cell) => cell,
            None => {
                let Some(cell) = atlas.borrow_mut().acquire(MAX_WIDTH, MAX_HEIGHT) else { return };
                self.cell = Some(cell);
                cell
            }
        };
        if picture.width > cell.w || picture.height > cell.h {
            return;
        }
        // shortcut: the window re-uploads the whole atlas slot (16 MB) for each picture; upgrade to a dirty-rect upload
        // (ImageSlots, WgpuRenderer) when a playing preview shows up in a frame-time profile.
        let shown = Placed { x: cell.x, y: cell.y, w: picture.width, h: picture.height };
        let image = RgbaImage { width: picture.width, height: picture.height, pixels: picture.rgba };
        self.upload = Some(ImageUpload { slot: ATLAS_SLOT, at: Some((shown.x, shown.y)), image });
        panel.preview_frame = Some(LibraryPicture { slot: ATLAS_SLOT, source: shown.uv(), size: shown.size() });
    }

    /// The preview left the video: the decoder lets go of the file, the cell goes back, the viewer shows the poster.
    fn end(&mut self, panel: &mut LibraryDrawPanel) {
        if self.loaded.take().is_none() {
            return;
        }
        self.video.unload();
        self.upload = None;
        panel.preview_frame = None;
        if let (Some(atlas), Some(cell)) = (&self.atlas, self.cell.take()) {
            atlas.borrow_mut().release(cell);
        }
    }

    pub(super) fn take_upload(&mut self) -> Option<ImageUpload> {
        self.upload.take()
    }
}
