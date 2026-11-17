//! Track Mask: an effect that takes another video track of the sequence as the clip's mask.
// Swift: TrackMaskEffect.swift (the kind constants and `isTrackMask` are `ClipEffect::TRACK_MASK_*` in sq-core-model, the
//        shape at a time is `ClipEffectFilters::track_mask_shape` in sq-core-effects; the track-remapping helper is private
//        in both of those crates)

use sq_core_effects::effects_evaluation::ClipEffectFilters;
use sq_core_masks::MaskShape;
use sq_core_model::{Clip, ClipEffect};
use sq_core_time::{Id, Time};

/// Swift `ClipEffect.setMaskTrack`.
pub trait TrackMaskEffectExt {
    /// Sets the track of a Track Mask (None = none). Other effects are left alone.
    fn set_mask_track(&mut self, id: Option<Id>);
}

impl TrackMaskEffectExt for ClipEffect {
    fn set_mask_track(&mut self, id: Option<Id>) {
        if self.is_track_mask() {
            self.mask_track = id;
        }
    }
}

/// Swift `Clip.trackMaskShapes(atLocal:)` and `trackMaskReads`.
pub trait TrackMaskClipExt {
    /// The Picture masks of this clip's enabled Track Mask effects at clip-local `t`, in list order. Added after the clip's own
    /// masks as Intersect, so they limit whatever those leave.
    fn track_mask_shapes(&self, t: Time) -> Vec<MaskShape>;
    /// Some Track Mask effect of this clip reads `track`.
    fn track_mask_reads(&self, track: Id) -> bool;
}

impl TrackMaskClipExt for Clip {
    fn track_mask_shapes(&self, t: Time) -> Vec<MaskShape> {
        self.effects.iter().filter_map(|e| e.track_mask_shape(t)).collect()
    }

    fn track_mask_reads(&self, track: Id) -> bool {
        self.effects.iter().any(|e| e.is_track_mask() && e.mask_track == Some(track))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{MaskSource, TrackKind};
    use sq_core_time::TimeRange;

    fn clip_with_track_mask(track: Option<Id>, enabled: bool) -> Clip {
        let mut c = Clip::new(
            Id::from_u128(1),
            "c",
            Id::from_u128(2),
            TrackKind::Video,
            TimeRange::new(Time::ZERO, Time::new(2, 1)),
            Time::ZERO,
        );
        let mut e = ClipEffect::make(Id::from_u128(3), ClipEffect::TRACK_MASK_KIND).unwrap();
        e.set_mask_track(track);
        e.enabled = enabled;
        c.effects = vec![e, ClipEffect::new(Id::from_u128(4), "blur")];
        c
    }

    #[test]
    fn shapes_come_from_enabled_track_masks_with_a_track_only() {
        let track = Id::from_u128(9);
        let c = clip_with_track_mask(Some(track), true);
        let shapes = c.track_mask_shapes(Time::ZERO);
        assert_eq!(shapes.len(), 1);
        assert!(shapes[0].source == MaskSource::Picture && shapes[0].picture_track == Some(track));
        assert!(clip_with_track_mask(Some(track), false).track_mask_shapes(Time::ZERO).is_empty());
        assert!(clip_with_track_mask(None, true).track_mask_shapes(Time::ZERO).is_empty());
    }

    #[test]
    fn reads_and_setter_only_touch_track_mask_effects() {
        let track = Id::from_u128(9);
        let mut c = clip_with_track_mask(Some(track), true);
        assert!(c.track_mask_reads(track) && !c.track_mask_reads(Id::from_u128(8)));
        c.effects[1].set_mask_track(Some(track));
        assert_eq!(c.effects[1].mask_track, None);
    }
}
