//! The picture the Program monitor shows: the playback engine's newest frame, handed from the app to the monitor host
//! and the renderer without either knowing the other.

use sq_draw::RgbaImage;
use sq_render::effects::view_choices::ViewChoices;
use sq_uikit::controls_grid::CGSize;
use std::any::Any;
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{Arc, Mutex, PoisonError};

/// Reads a GPU-held picture back to the CPU (only when a reader needs pixels: scopes, eyedropper, snapshots).
pub type PictureReader = Arc<dyn Fn() -> Option<RgbaImage> + Send + Sync>;

/// The composite as linear half floats: `bytes` is `width * height * 4` little-endian IEEE binary16 values (rgba,
/// premultiplied, linear Rec.709 light, rows top down, stride `width * 8`). What Export Frame writes (Swift: the
/// compositor's rgba16Float texture).
pub struct LinearImage {
    pub width: usize,
    pub height: usize,
    pub bytes: Vec<u8>,
}

/// Reads the linear composite back to the CPU (only for Export Frame).
pub type LinearReader = Arc<dyn Fn() -> Option<LinearImage> + Send + Sync>;

#[derive(Default)]
struct Slot {
    linear: Option<LinearReader>,
    image: Option<Arc<RgbaImage>>,
    size: Option<(usize, usize)>,
    /// The display-ready texture the window samples directly (type-erased so the hosts need no GPU types).
    gpu: Option<Arc<dyn Any + Send + Sync>>,
    reader: Option<PictureReader>,
}

/// A shared slot for the monitor's frame (cheap to clone; every clone sees the same picture). It also carries the
/// View > Display and View > View Gamma choices the monitor's pixels are shown by, so every reader of the picture (the
/// render thread's display pass, the windows) and the menu that sets them share one handle of one app.
#[derive(Clone, Default)]
pub struct MonitorPicture(Arc<Mutex<Slot>>, Arc<AtomicI64>, ViewChoices);

impl MonitorPicture {
    /// The View choices this picture is shown by.
    pub fn view_choices(&self) -> &ViewChoices {
        &self.2
    }

    /// A new empty picture shown by the same View choices (the Source monitor next to the Program monitor).
    pub fn sibling(&self) -> MonitorPicture {
        MonitorPicture(Arc::default(), Arc::default(), self.2.clone())
    }

    fn slot(&self) -> std::sync::MutexGuard<'_, Slot> {
        self.0.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Replaces the picture (`None` clears it).
    pub fn set(&self, image: Option<RgbaImage>) {
        let size = image.as_ref().map(|i| (i.width, i.height));
        *self.slot() = Slot { image: image.map(Arc::new), size, gpu: None, reader: None, linear: None };
        self.1.fetch_add(1, Ordering::Relaxed);
    }

    /// Replaces the picture with one that stays on the GPU: `gpu` is what the window draws, `reader` gives the pixels
    /// when [`get`](Self::get) is asked for them.
    pub fn set_gpu(&self, size: (usize, usize), gpu: Arc<dyn Any + Send + Sync>, reader: PictureReader) {
        *self.slot() = Slot { image: None, size: Some(size), gpu: Some(gpu), reader: Some(reader), linear: None };
        self.1.fetch_add(1, Ordering::Relaxed);
    }

    /// Changes with every [`set`](Self::set): the scopes measure a picture once per generation.
    pub fn generation(&self) -> i64 {
        self.1.load(Ordering::Relaxed)
    }

    /// The current picture's pixels (a GPU picture is read back once and kept).
    pub fn get(&self) -> Option<Arc<RgbaImage>> {
        let reader = {
            let slot = self.slot();
            if slot.image.is_some() {
                return slot.image.clone();
            }
            slot.reader.clone()?
        };
        let generation = self.generation();
        let image = reader().map(Arc::new);
        let mut slot = self.slot();
        if self.generation() == generation {
            slot.image.clone_from(&image);
        }
        image
    }

    /// Attaches the linear reader of the picture just published (call after `set` / `set_gpu`, which clear it).
    pub fn set_linear(&self, reader: Option<LinearReader>) {
        self.slot().linear = reader;
    }

    /// The linear half-float composite of the current picture, read back now; `None` when the picture has none.
    pub fn linear(&self) -> Option<LinearImage> {
        let reader = self.slot().linear.clone()?;
        reader()
    }

    /// The picture's size without reading it back.
    pub fn size(&self) -> Option<(usize, usize)> {
        self.slot().size
    }

    /// The GPU picture the window draws, `None` for a CPU picture.
    pub fn gpu(&self) -> Option<Arc<dyn Any + Send + Sync>> {
        self.slot().gpu.clone()
    }
}

/// The size the monitor fits its picture by: the sequence frame (shown size), else the picture's own pixels. The panel
/// letterboxes by this aspect, never by the panel's.
pub fn fit_size(sequence: Option<(i64, i64)>, picture: Option<(usize, usize)>) -> Option<CGSize> {
    let valid = |w: f64, h: f64| (w > 0.0 && h > 0.0).then(|| CGSize::new(w, h));
    sequence
        .and_then(|(w, h)| valid(w as f64, h as f64))
        .or_else(|| picture.and_then(|(w, h)| valid(w as f64, h as f64)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_draw::Color;

    #[test]
    fn fit_prefers_the_sequence_frame() {
        assert_eq!(fit_size(Some((1080, 1350)), Some((1920, 1080))), Some(CGSize::new(1080.0, 1350.0)));
        assert_eq!(fit_size(None, Some((1920, 1080))), Some(CGSize::new(1920.0, 1080.0)));
        assert_eq!(fit_size(Some((0, 1080)), Some((640, 360))), Some(CGSize::new(640.0, 360.0)));
        assert_eq!(fit_size(None, None), None);
    }

    #[test]
    fn a_4_by_5_frame_is_letterboxed_in_a_wide_slot() {
        use sq_core_edit::viewer_zoom::ViewerZoom;
        use sq_draw_monitor::monitor_view_mapping::MonitorViewMapping;
        let size = fit_size(Some((1080, 1350)), None).unwrap();
        let m = MonitorViewMapping::new(CGSize::new(1600.0, 900.0), 2.0, size, ViewerZoom::Fit);
        let r = m.canvas_rect();
        assert!((r.width / r.height - 0.8).abs() < 1e-6, "{r:?}");
        assert!(r.width < 1600.0 && r.height <= 900.0);
    }

    #[test]
    fn clones_share_one_picture() {
        let a = MonitorPicture::default();
        let b = a.clone();
        assert!(b.get().is_none());
        a.set(Some(RgbaImage::filled(2, 2, Color::WHITE)));
        assert_eq!(b.get().map(|i| i.width), Some(2));
        a.set(None);
        assert!(b.get().is_none());
    }

    #[test]
    fn every_set_moves_the_generation() {
        let a = MonitorPicture::default();
        let g = a.generation();
        a.set(None);
        assert_ne!(a.generation(), g);
    }
}
