//! The Mask Tint of the Program monitor: the stored mattes of the selected clip's Magic masks at the playhead, laid over
//! the picture as one coverage image (Swift `MacMagicMasks.maskTint`, 30 % per mask). Reading the finished track's
//! mattes from the store is the pre-roll: the tint shows as soon as the run has stored the frame under the playhead.

use sq_analysis::frame_matte_store::FrameMatteStore;
use sq_app_shell::ImageUpload;
use sq_core_masks::magic_mask::MagicSelectionExt;
use sq_core_masks::masks::ClipMasksExt;
use sq_core_masks::subject_mask::SubjectMatte;
use sq_draw::RgbaImage;
use sq_editor_session::EditorSession;
use std::sync::Arc;

/// How strongly one mask tints the picture.
const STRENGTH: f32 = 0.3;

/// Builds the tint picture when the stored mattes under the playhead change.
pub struct MatteTint {
    store: Arc<FrameMatteStore>,
    slot: usize,
    /// What the last picture was made from: the keys with their frame time, and the store's revision.
    made: Option<(Vec<String>, i64)>,
    pending: Option<ImageUpload>,
}

impl MatteTint {
    /// A tint reading `store`, drawn through the renderer image `slot`.
    pub fn new(store: Arc<FrameMatteStore>, slot: usize) -> MatteTint {
        MatteTint { store, slot, made: None, pending: None }
    }

    /// Looks at the selection and the playhead; true while a tint is on show (the overlay draws `slot`).
    pub fn update(&mut self, session: &EditorSession) -> bool {
        let found = self.found(session);
        if found.is_empty() {
            self.made = None;
            return false;
        }
        let keys: Vec<String> = found.iter().map(|(k, _)| k.clone()).collect();
        let stamp = (keys, self.store.revision());
        if self.made.as_ref() != Some(&stamp) {
            let layers: Vec<&SubjectMatte> = found.iter().map(|(_, m)| m).collect();
            if let Some(image) = tint_image(&layers) {
                self.pending = Some(ImageUpload { slot: self.slot, at: None, image });
            }
            self.made = Some(stamp);
        }
        true
    }

    /// The renderer image slot the picture goes to.
    pub fn slot(&self) -> usize {
        self.slot
    }

    /// The picture made since the last call.
    pub fn take_upload(&mut self) -> Option<ImageUpload> {
        self.pending.take()
    }

    fn found(&self, session: &EditorSession) -> Vec<(String, SubjectMatte)> {
        let Some(timeline) = session.display_timeline() else { return Vec::new() };
        let Some(id) = session.selection().iter().next().copied() else { return Vec::new() };
        let Some(clip) = timeline.tracks.iter().flat_map(|t| t.clips()).find(|c| c.id == id) else { return Vec::new() };
        let at = clip.source_time(session.playhead(), timeline.frame_duration());
        let pts = at.value() as f64 / at.timescale() as f64;
        clip.masks()
            .iter()
            .filter_map(|m| {
                let key = m.magic.as_ref()?.cache_key(clip.media);
                let matte = self.store.matte(&key, pts)?;
                Some((format!("{key}@{pts}"), matte))
            })
            .collect()
    }
}

/// White picture whose alpha is the layers' tints laid over each other; `None` when the sizes differ from the first.
fn tint_image(layers: &[&SubjectMatte]) -> Option<RgbaImage> {
    let first = layers.first()?;
    let (width, height) = (first.width(), first.height());
    let count = width * height;
    let mut inverse = vec![1.0_f32; count];
    for m in layers.iter().filter(|m| m.values.len() == count) {
        for (rest, v) in inverse.iter_mut().zip(&m.values) {
            *rest *= 1.0 - v.clamp(0.0, 1.0) * STRENGTH;
        }
    }
    let mut pixels = vec![255_u8; width * height * 4];
    for (px, rest) in pixels.as_chunks_mut::<4>().0.iter_mut().zip(&inverse) {
        px[3] = ((1.0 - rest) * 255.0).round() as u8;
    }
    Some(RgbaImage { width, height, pixels })
}

#[cfg(test)]
mod tests;
