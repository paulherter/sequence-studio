//! The pictures the panels draw as renderer image slots (thumbnail atlas, scopes), kept on the CPU. The window uploads
//! the slots that changed to the GPU renderer, the headless shot hands the same slots to the software renderer, so both
//! show the same pictures.

use sq_app_shell::{ATLAS_SIZE, ATLAS_SLOT, ImageUpload};
use sq_draw::{DrawList, RgbaImage};

/// One picture per renderer image slot.
#[derive(Default)]
pub struct ImageSlots {
    images: [Option<RgbaImage>; DrawList::IMAGE_SLOTS],
    dirty: [bool; DrawList::IMAGE_SLOTS],
}

impl ImageSlots {
    /// Copies the hosts' pictures in: a whole slot is replaced, a part of the atlas is blitted (the atlas starts
    /// transparent).
    pub fn apply(&mut self, uploads: Vec<ImageUpload>) {
        for ImageUpload { slot, at, image } in uploads {
            let Some(cell) = self.images.get_mut(slot) else { continue };
            self.dirty[slot] = true;
            let Some((x, y)) = at else {
                *cell = Some(image);
                continue;
            };
            let size = if slot == ATLAS_SLOT { ATLAS_SIZE } else { (x + image.width).max(y + image.height) };
            let target =
                cell.get_or_insert_with(|| RgbaImage { width: size, height: size, pixels: vec![0; size * size * 4] });
            for row in 0..image.height.min(target.height.saturating_sub(y)) {
                let n = image.width.min(target.width.saturating_sub(x)) * 4;
                let (from, to) = (row * image.width * 4, ((y + row) * target.width + x) * 4);
                target.pixels[to..to + n].copy_from_slice(&image.pixels[from..from + n]);
            }
        }
    }

    /// The slots for the software renderer.
    pub fn images(&self) -> &[Option<RgbaImage>] {
        &self.images
    }

    /// Every slot that holds a picture (a window that opens later starts with all of them).
    pub fn all(&self) -> Vec<(usize, &RgbaImage)> {
        self.images.iter().enumerate().filter_map(|(i, img)| img.as_ref().map(|img| (i, img))).collect()
    }

    /// The slots changed since the last call, with their pictures (for the GPU upload).
    pub fn take_dirty(&mut self) -> Vec<(usize, &RgbaImage)> {
        let dirty = std::mem::take(&mut self.dirty);
        self.images
            .iter()
            .enumerate()
            .filter_map(|(i, img)| img.as_ref().filter(|_| dirty[i]).map(|img| (i, img)))
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pic(w: usize, h: usize, v: u8) -> RgbaImage {
        RgbaImage { width: w, height: h, pixels: vec![v; w * h * 4] }
    }

    #[test]
    fn a_part_lands_in_the_atlas_and_a_whole_replaces_a_slot() {
        let mut slots = ImageSlots::default();
        slots.apply(vec![
            ImageUpload { slot: ATLAS_SLOT, at: Some((3, 2)), image: pic(2, 2, 200) },
            ImageUpload { slot: 2, at: None, image: pic(4, 1, 9) },
        ]);
        let atlas = slots.images()[ATLAS_SLOT].as_ref().expect("atlas");
        assert_eq!((atlas.width, atlas.height), (ATLAS_SIZE, ATLAS_SIZE));
        assert_eq!(atlas.pixels[(2 * ATLAS_SIZE + 3) * 4], 200);
        assert_eq!(atlas.pixels[(2 * ATLAS_SIZE + 2) * 4], 0, "the pixel left of the part is untouched");
        assert_eq!(slots.images()[2].as_ref().map(|i| i.width), Some(4));
        assert_eq!(slots.take_dirty().len(), 2);
        assert!(slots.take_dirty().is_empty(), "uploaded once");
    }
}
