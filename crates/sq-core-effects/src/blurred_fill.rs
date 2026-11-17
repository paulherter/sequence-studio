// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: BlurredFill.swift
//! Fit with Blurred Fill and Card (explicit, per clip, never automatic): the picture sits whole inside the frame and a
//! blurred, enlarged, darkened copy of it fills the bars. Built only from things the model already has (a second clip on a
//! new video track below, Gaussian Blur, Opacity, Rounded Corners, Drop Shadow), so no file format change: the pair is
//! recognized by the shared link and the copy's name suffix, and removed again by `remove_blurred_fill`.

use sq_core_color::ClipEffectColorExt;
use sq_core_masks::{ClipMasksExt, PictureMaskTimelineExt};
use sq_core_model::{
    AnimatedProperty, BlendMode, Clip, ClipAnimation, ClipEffect, EditError, FadeMarks, SequenceFormat, Timeline,
    Track, TrackKind,
};
use sq_core_time::{Id, IdSource, Vec2};
use std::collections::BTreeSet;
use std::fmt;

/// The two looks.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum BlurredFillStyle {
    /// Whole picture, blurred copy behind it.
    Fit,
    /// Picture at 85 %, rounded corners and a drop shadow over the blurred copy (for screenshots and cards).
    Card,
}

impl BlurredFillStyle {
    fn suffix(self) -> &'static str {
        if self == BlurredFillStyle::Fit { BlurredFill::FIT_SUFFIX } else { BlurredFill::CARD_SUFFIX }
    }
}

/// How the blurred background looks.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct BlurredFillOptions {
    /// Blurriness of the background's Gaussian Blur (Premiere units; 115 = sigma ~40 px of its own frame).
    pub blur: f64,
    /// 0...1: how much the background is darkened (its Opacity becomes 1 - dim over black).
    pub dim: f64,
}

impl Default for BlurredFillOptions {
    fn default() -> Self {
        BlurredFillOptions { blur: 115.0, dim: 0.35 }
    }
}

/// Why Fit with Blurred Fill refused, besides the plain edit errors.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BlurredFillError {
    /// The picture already has the sequence's aspect (Fit only): there is nothing to fill.
    AspectMatches,
    /// A generator or media without size information.
    UnknownSize,
    /// The edit itself was refused.
    Edit(EditError),
}

impl From<EditError> for BlurredFillError {
    fn from(e: EditError) -> Self {
        BlurredFillError::Edit(e)
    }
}

impl fmt::Display for BlurredFillError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            BlurredFillError::AspectMatches => f.write_str("the picture already has the sequence's aspect"),
            BlurredFillError::UnknownSize => f.write_str("the picture size is unknown"),
            BlurredFillError::Edit(e) => write!(f, "{e:?}"),
        }
    }
}

impl std::error::Error for BlurredFillError {}

/// The pair a clip belongs to.
#[derive(Clone, Debug, PartialEq)]
pub struct BlurredFillPair {
    /// The picture.
    pub picture: Clip,
    /// The blurred copy; `None` when the copy was deleted on its own while Card's effects are still on the picture.
    pub background: Option<Clip>,
    /// Which look.
    pub style: BlurredFillStyle,
}

/// Constants and helpers of the look.
pub struct BlurredFill;

/// Which derived id: the copy, Card's Rounded Corners, Card's Drop Shadow.
#[derive(Clone, Copy)]
enum Role {
    Copy = 0x5B,
    Round = 0x2D,
    Shadow = 0x71,
}

impl BlurredFill {
    /// Name suffix of the blurred copy.
    pub const FIT_SUFFIX: &'static str = " (Blur Fill)";
    /// Name suffix of Card's copy.
    pub const CARD_SUFFIX: &'static str = " (Card)";
    /// Card: picture size relative to the frame fit.
    pub const CARD_SCALE: f64 = 0.85;
    /// Card: corner radius.
    pub const CARD_RADIUS: f64 = 32.0;
    /// The background is enlarged past the cover size so the blur's soft edge falls outside the frame.
    const BLEED: f64 = 1.12;

    /// The explicit marker of a pair, with no file format change: the identities of the copy and of Card's two effects are
    /// derived from the picture clip's id (a fixed byte-wise addition), so they survive renames, trims, moves and an
    /// unlinked pair. A user clip or effect can never have such an id by accident. A pasted or duplicated picture gets a new
    /// id and therefore starts without a pair. Trade-off: the copy is deliberately NOT linked to the picture (a link would
    /// make deleting the copy delete the picture and its audio), so moving the picture does not move the copy; applying
    /// the look again re-places the copy under the picture.
    fn derived_id(id: Id, role: Role) -> Id {
        let mut b = id.as_u128().to_be_bytes();
        // Addition, not XOR: derived(derived(x)) must differ from x.
        for (i, x) in b.iter_mut().enumerate() {
            *x = x.wrapping_add(role as u8).wrapping_add((i as u8).wrapping_mul(29));
        }
        Id::from_u128(u128::from_be_bytes(b))
    }

    /// True when the picture's aspect equals the frame's within 1 %.
    pub fn matches_aspect(picture: (i64, i64), frame: &SequenceFormat) -> bool {
        if picture.0 <= 0 || picture.1 <= 0 || frame.width <= 0 || frame.height <= 0 {
            return true;
        }
        let a = picture.0 as f64 / picture.1 as f64;
        let b = frame.width as f64 / frame.height as f64;
        (a - b).abs() / b < 0.01
    }
}

/// Swift `extension Timeline` in BlurredFill.swift.
pub trait TimelineBlurredFillExt {
    /// The pair `id` belongs to: `id` may be the picture or its blurred copy.
    fn blurred_fill_pair(&self, id: Id) -> Option<BlurredFillPair>;
    /// The picture clip a command should act on: the clip itself, or the picture when `id` is the blurred copy.
    fn blurred_fill_picture(&self, id: Id) -> Id;
    /// Fit with Blurred Fill / Card on a video clip whose picture is `picture` px (upright). `id` may also be the blurred
    /// copy of an earlier application (the picture is used). A new video track is inserted directly below the picture's
    /// track and receives the blurred copy (same media, range, speed and color effects, not linked, see
    /// `BlurredFill::derived_id`). The picture gets the frame-fit scale (Card: 85 % of it). Applying again replaces the
    /// previous look. `TrackLocked`, `ClipNotFound`, `WrongTrackKind` (audio), and `AspectMatches` (Fit only); nothing
    /// changes then.
    fn apply_blurred_fill(
        &mut self,
        clip: Id,
        picture: (i64, i64),
        style: BlurredFillStyle,
        options: BlurredFillOptions,
        ids: &mut dyn IdSource,
    ) -> Result<(), BlurredFillError>;
    /// Takes the look away: deletes the blurred copy (and its track when that is now empty), drops exactly the Rounded
    /// Corners and Drop Shadow effects Card added (the user's own stay) and undoes Card's 85 % scale (Fit keeps its
    /// frame-fit scale). `id` may be either clip of the pair. No-op when `id` is not part of a pair.
    fn remove_blurred_fill(&mut self, id: Id) -> Result<(), EditError>;
}

impl TimelineBlurredFillExt for Timeline {
    fn blurred_fill_pair(&self, id: Id) -> Option<BlurredFillPair> {
        let all: Vec<&Clip> = self.tracks.iter().flat_map(|t| t.clips().iter()).collect();
        let x = all.iter().find(|c| c.id == id)?;
        let pic = all
            .iter()
            .find(|c| c.kind == TrackKind::Video && BlurredFill::derived_id(c.id, Role::Copy) == id)
            .unwrap_or(x);
        let bg = all.iter().find(|c| c.id == BlurredFill::derived_id(pic.id, Role::Copy));
        let is_card = pic.effects.iter().any(|e| e.id == BlurredFill::derived_id(pic.id, Role::Round));
        if is_card {
            return Some(BlurredFillPair {
                picture: (*pic).clone(),
                background: bg.map(|c| (*c).clone()),
                style: BlurredFillStyle::Card,
            });
        }
        bg.map(|b| BlurredFillPair {
            picture: (*pic).clone(),
            background: Some((*b).clone()),
            style: BlurredFillStyle::Fit,
        })
    }

    fn blurred_fill_picture(&self, id: Id) -> Id {
        self.blurred_fill_pair(id).map_or(id, |p| p.picture.id)
    }

    fn apply_blurred_fill(
        &mut self,
        clip: Id,
        picture: (i64, i64),
        style: BlurredFillStyle,
        options: BlurredFillOptions,
        ids: &mut dyn IdSource,
    ) -> Result<(), BlurredFillError> {
        if picture.0 <= 0 || picture.1 <= 0 {
            return Err(BlurredFillError::UnknownSize);
        }
        let mut work = self.clone();
        let id = work.blurred_fill_picture(clip);
        if work.blurred_fill_pair(id).is_some() {
            work.remove_blurred_fill(id)?;
        }
        let m = work.find(id).ok_or(EditError::ClipNotFound)?;
        if m.clip.kind != TrackKind::Video || m.clip.is_generator() {
            return Err(EditError::WrongTrackKind.into());
        }
        if work.tracks[m.track].is_locked {
            return Err(EditError::TrackLocked.into());
        }
        if style == BlurredFillStyle::Fit && BlurredFill::matches_aspect(picture, &work.format) {
            return Err(BlurredFillError::AspectMatches);
        }

        let format = &self.format;
        let fit = format.fit_scale(picture.0, picture.1);
        let cover = (format.display_width() as f64 / picture.0 as f64).max(format.height as f64 / picture.1 as f64);

        let mut pic = m.clip.clone();
        let s = if style == BlurredFillStyle::Card { fit * BlurredFill::CARD_SCALE } else { fit };
        pic.animation.scale = AnimatedProperty::new(Vec2::new(s, s));
        if style == BlurredFillStyle::Card {
            let mut round = ClipEffect::rounded_corners(ids.next_id(), BlurredFill::CARD_RADIUS);
            round.id = BlurredFill::derived_id(pic.id, Role::Round);
            pic.effects.push(round);
            if let Some(mut shadow) = ClipEffect::make(ids.next_id(), ClipEffect::DROP_SHADOW_KIND) {
                shadow.id = BlurredFill::derived_id(pic.id, Role::Shadow);
                for (key, v) in [
                    (ClipEffect::SHADOW_OPACITY_KEY, 60.0),
                    (ClipEffect::SHADOW_DIRECTION_KEY, 180.0),
                    (ClipEffect::SHADOW_DISTANCE_KEY, 24.0),
                    (ClipEffect::SHADOW_SOFTNESS_KEY, 48.0),
                ] {
                    shadow.parameters.insert(key.to_string(), AnimatedProperty::new(v));
                }
                pic.effects.push(shadow);
            }
        }

        let mut bg = m.clip.clone();
        bg.id = BlurredFill::derived_id(pic.id, Role::Copy);
        bg.link = None;
        bg.name = format!("{}{}", m.clip.name, style.suffix());
        bg.animation = ClipAnimation::default();
        bg.set_masks(Vec::new()); // the blurred backdrop fills the frame: no masks, no baked presets of the picture
        bg.baked_store = None;
        let bs = cover * BlurredFill::BLEED;
        bg.animation.scale = AnimatedProperty::new(Vec2::new(bs, bs));
        bg.animation.opacity = AnimatedProperty::new((1.0 - options.dim).clamp(0.0, 1.0));
        bg.effects = m
            .clip
            .effects
            .iter()
            .filter(|e| e.is_color())
            .map(|e| {
                let mut c = e.clone();
                c.id = ids.next_id();
                c
            })
            .collect();
        if let Some(mut blur) = ClipEffect::make(ids.next_id(), ClipEffect::GAUSSIAN_BLUR_KIND) {
            blur.parameters
                .insert(ClipEffect::BLURRINESS_KEY.to_string(), AnimatedProperty::new(options.blur.max(0.0)));
            bg.effects.push(blur);
        }
        bg.blend_mode = BlendMode::Normal;
        bg.audio_fades = FadeMarks::default();
        bg.duck_key_ids = Vec::new();

        work.tracks[m.track].replace(pic);
        let mut below = Track::new(ids.next_id(), TrackKind::Video);
        below.name = String::new();
        below.overwrite(bg, ids)?;
        work.tracks.insert(m.track, below);
        *self = work;
        Ok(())
    }

    fn remove_blurred_fill(&mut self, id: Id) -> Result<(), EditError> {
        let Some(pair) = self.blurred_fill_pair(id) else { return Ok(()) };
        let mut work = self.clone();
        if let Some(bg_clip) = &pair.background {
            let bi = work.tracks.iter().position(|t| t.clip(bg_clip.id).is_some()).ok_or(EditError::ClipNotFound)?;
            if work.tracks[bi].is_locked {
                return Err(EditError::TrackLocked);
            }
            work.tracks[bi].remove(bg_clip.id);
            if work.tracks[bi].clips().is_empty() && work.tracks[bi].transitions.is_empty() {
                let gone = work.tracks.remove(bi).id;
                work.clear_picture_masks_reading_track(gone);
            }
        }
        let mut pic = pair.picture;
        if pair.style == BlurredFillStyle::Card {
            let ours: BTreeSet<Id> =
                [BlurredFill::derived_id(pic.id, Role::Round), BlurredFill::derived_id(pic.id, Role::Shadow)].into();
            pic.effects.retain(|e| !ours.contains(&e.id));
            if !pic.animation.scale.is_animated() {
                let v = pic.animation.scale.value;
                pic.animation.scale =
                    AnimatedProperty::new(Vec2::new(v.x / BlurredFill::CARD_SCALE, v.y / BlurredFill::CARD_SCALE));
            }
        }
        let pi = work.tracks.iter().position(|t| t.clip(pic.id).is_some()).ok_or(EditError::ClipNotFound)?;
        if work.tracks[pi].is_locked {
            return Err(EditError::TrackLocked);
        }
        work.tracks[pi].replace(pic);
        *self = work;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{ClipMask, MaskPath};
    use sq_core_time::{SequentialIds, Time, TimeRange};

    fn s(n: i64) -> Time {
        Time::new(n, 1)
    }

    fn shot(ids: &mut SequentialIds, media: Id, kind: TrackKind, link: Option<Id>) -> Clip {
        let mut c = Clip::new(ids.next_id(), "shot", media, kind, TimeRange::new(s(2), s(5)), s(1));
        c.link = link;
        c
    }

    fn make(ids: &mut SequentialIds, link: Option<Id>, audio: bool) -> (Timeline, Clip) {
        let media = ids.next_id();
        let c = shot(ids, media, TrackKind::Video, link);
        let mut v = Track::new(ids.next_id(), TrackKind::Video);
        assert!(v.overwrite(c.clone(), ids).is_ok());
        let mut tracks = vec![v, Track::new(ids.next_id(), TrackKind::Video)];
        if audio {
            let a = shot(ids, media, TrackKind::Audio, link);
            let mut at = Track::new(ids.next_id(), TrackKind::Audio);
            assert!(at.overwrite(a, ids).is_ok());
            tracks.push(at);
        }
        let mut f = SequenceFormat::new(Time::new(1, 30));
        f.width = 1080;
        f.height = 1920;
        (Timeline::new(ids.next_id(), "T", f, tracks), c)
    }

    fn apply(t: &mut Timeline, id: Id, pic: (i64, i64), style: BlurredFillStyle, ids: &mut SequentialIds) {
        assert_eq!(t.apply_blurred_fill(id, pic, style, BlurredFillOptions::default(), ids), Ok(()));
    }

    #[test]
    fn fit_puts_the_blurred_copy_on_a_new_track_below() {
        let mut ids = SequentialIds::default();
        let (mut t, c) = make(&mut ids, None, false);
        let o = BlurredFillOptions { blur: 50.0, dim: 0.5 };
        assert_eq!(t.apply_blurred_fill(c.id, (1920, 1080), BlurredFillStyle::Fit, o, &mut ids), Ok(()));
        assert_eq!(t.tracks.len(), 3);
        let (pic, bg) = (&t.tracks[1].clips()[0], &t.tracks[0].clips()[0]);
        assert!(pic.id == c.id && bg.id != c.id);
        assert!((pic.animation.scale.value.x - 1080.0 / 1920.0).abs() < 1e-9);
        assert!((bg.animation.scale.value.x - 1920.0 / 1080.0 * 1.12).abs() < 1e-9);
        assert_eq!(bg.animation.opacity.value, 0.5);
        let blur = bg
            .effect_of_kind(ClipEffect::GAUSSIAN_BLUR_KIND)
            .and_then(|e| e.parameters.get(ClipEffect::BLURRINESS_KEY));
        assert_eq!(blur.map(|p| p.value), Some(50.0));
        assert!(bg.start == c.start && bg.source == c.source && bg.media == c.media);
        assert!(bg.link.is_none() && pic.link.is_none());
        assert_eq!(bg.name, "shot (Blur Fill)");
        assert_eq!(t.blurred_fill_pair(bg.id).map(|p| p.picture.id), Some(c.id));
    }

    #[test]
    fn the_background_copy_drops_masks_and_baked_effects() {
        let mut ids = SequentialIds::default();
        let (mut t, mut c) = make(&mut ids, None, false);
        c.set_masks(vec![ClipMask::new(
            ids.next_id(),
            "m",
            sq_core_model::MaskShapeKind::Rectangle,
            MaskPath::rectangle(Vec2::new(0.2, 0.2), Vec2::new(0.8, 0.8)),
        )]);
        t.tracks[0].replace(c.clone());
        apply(&mut t, c.id, (1920, 1080), BlurredFillStyle::Fit, &mut ids);
        assert_eq!(t.tracks[1].clips()[0].masks().len(), 1);
        assert!(t.tracks[0].clips()[0].masks().is_empty());
        assert!(t.tracks[0].clips()[0].baked_store.is_none());
    }

    #[test]
    fn matching_aspect_is_refused_for_fit_but_not_card() {
        let mut ids = SequentialIds::default();
        let (mut t, c) = make(&mut ids, None, false);
        let before = t.clone();
        let o = BlurredFillOptions::default();
        assert_eq!(
            t.apply_blurred_fill(c.id, (1080, 1920), BlurredFillStyle::Fit, o, &mut ids),
            Err(BlurredFillError::AspectMatches)
        );
        assert_eq!(t, before);
        apply(&mut t, c.id, (1080, 1920), BlurredFillStyle::Card, &mut ids);
        let kinds: Vec<&str> = t.tracks[1].clips()[0].effects.iter().map(|e| e.kind.as_str()).collect();
        assert_eq!(kinds, [ClipEffect::ROUNDED_CORNERS_KIND, ClipEffect::DROP_SHADOW_KIND]);
    }

    #[test]
    fn card_scales_the_picture_and_remove_restores_it_and_the_empty_track() {
        let mut ids = SequentialIds::default();
        let (mut t, c) = make(&mut ids, None, false);
        apply(&mut t, c.id, (1600, 1200), BlurredFillStyle::Card, &mut ids);
        let pic = &t.tracks[1].clips()[0];
        assert!((pic.animation.scale.value.x - 1080.0 / 1600.0 * 0.85).abs() < 1e-9);
        assert_eq!(pic.effects.len(), 2);
        assert_eq!(t.blurred_fill_pair(c.id).map(|p| p.style), Some(BlurredFillStyle::Card));
        assert_eq!(t.remove_blurred_fill(c.id), Ok(()));
        assert_eq!(t.tracks.len(), 2);
        let pic = &t.tracks[0].clips()[0];
        assert!(pic.effects.is_empty());
        assert!((pic.animation.scale.value.x - 1080.0 / 1600.0).abs() < 1e-9);
        assert!(t.blurred_fill_pair(c.id).is_none());
    }

    #[test]
    fn the_copy_is_not_in_the_av_link_and_remove_from_the_copy_keeps_audio() {
        let mut ids = SequentialIds::default();
        let link = ids.next_id();
        let (mut t, c) = make(&mut ids, Some(link), true);
        apply(&mut t, c.id, (1920, 1080), BlurredFillStyle::Fit, &mut ids);
        let bg = t.tracks[0].clips()[0].clone();
        assert!(bg.link.is_none());
        assert_eq!(t.remove_blurred_fill(bg.id), Ok(()));
        assert_eq!(t.tracks.len(), 3);
        assert_eq!(t.tracks[0].clips()[0].link, Some(link));
        assert_eq!(t.tracks[2].clips()[0].link, Some(link));
    }

    #[test]
    fn applying_with_the_copy_selected_acts_on_the_picture_and_again_replaces_the_look() {
        let mut ids = SequentialIds::default();
        let (mut t, c) = make(&mut ids, None, false);
        apply(&mut t, c.id, (1920, 1080), BlurredFillStyle::Fit, &mut ids);
        let copy = t.tracks[0].clips()[0].id;
        apply(&mut t, copy, (1920, 1080), BlurredFillStyle::Card, &mut ids);
        assert!(t.tracks.len() == 3 && t.tracks.iter().map(|x| x.clips().len()).sum::<usize>() == 2);
        assert_eq!(t.blurred_fill_pair(c.id).map(|p| p.style), Some(BlurredFillStyle::Card));
        assert_eq!(t.blurred_fill_pair(copy).map(|p| p.picture.id), Some(c.id));
        apply(&mut t, c.id, (1600, 1200), BlurredFillStyle::Fit, &mut ids);
        apply(&mut t, c.id, (1600, 1200), BlurredFillStyle::Card, &mut ids);
        assert!(t.tracks.len() == 3 && t.tracks.iter().map(|x| x.clips().len()).sum::<usize>() == 2);
        assert_eq!(t.tracks[1].clips()[0].effects.len(), 2);
    }

    #[test]
    fn the_pair_survives_rename_and_an_unlinked_trim_of_one_side() {
        let mut ids = SequentialIds::default();
        let (mut t, c) = make(&mut ids, None, false);
        apply(&mut t, c.id, (1920, 1080), BlurredFillStyle::Fit, &mut ids);
        let mut bg = t.tracks[0].clips()[0].clone();
        bg.name = "something else".into();
        t.tracks[0].replace(bg.clone());
        assert!(t.ripple_trim(c.id, sq_core_model::ClipEdge::Tail, Time::ZERO - s(1)).is_ok());
        assert_eq!(t.blurred_fill_pair(c.id).and_then(|p| p.background).map(|b| b.id), Some(bg.id));
        assert_eq!(t.remove_blurred_fill(c.id), Ok(()));
        assert!(t.tracks.len() == 2 && t.tracks.iter().map(|x| x.clips().len()).sum::<usize>() == 1);
    }

    #[test]
    fn a_user_clip_named_card_with_blur_is_not_a_pair_and_card_removes_only_its_own_effects() {
        let mut ids = SequentialIds::default();
        let (mut t, c) = make(&mut ids, None, false);
        let mut other = Clip::new(ids.next_id(), "x (Card)", c.media, TrackKind::Video, c.source, c.start);
        other.effects = vec![ClipEffect::make(ids.next_id(), ClipEffect::GAUSSIAN_BLUR_KIND).unwrap()];
        let mut tr = Track::new(ids.next_id(), TrackKind::Video);
        assert!(tr.overwrite(other.clone(), &mut ids).is_ok());
        t.tracks.push(tr);
        assert!(t.blurred_fill_pair(other.id).is_none() && t.blurred_fill_pair(c.id).is_none());
        assert_eq!(t.remove_blurred_fill(other.id), Ok(()));
        assert_eq!(t.tracks.iter().map(|x| x.clips().len()).sum::<usize>(), 2);

        let (mut t, c) = make(&mut ids, None, false);
        let mut mine = c.clone();
        mine.effects = vec![
            ClipEffect::rounded_corners(ids.next_id(), 5.0),
            ClipEffect::make(ids.next_id(), ClipEffect::DROP_SHADOW_KIND).unwrap(),
        ];
        t.tracks[0].replace(mine.clone());
        apply(&mut t, c.id, (1600, 1200), BlurredFillStyle::Card, &mut ids);
        assert_eq!(t.blurred_fill_pair(c.id).map(|p| p.picture.effects.len()), Some(4));
        assert_eq!(t.remove_blurred_fill(c.id), Ok(()));
        assert_eq!(t.tracks[0].clips()[0].effects, mine.effects);
    }

    #[test]
    fn refuses_a_locked_track_audio_and_an_unknown_size_and_leaves_the_timeline_unchanged() {
        let mut ids = SequentialIds::default();
        let (mut t, c) = make(&mut ids, None, false);
        t.tracks[0].is_locked = true;
        let before = t.clone();
        let o = BlurredFillOptions::default();
        assert_eq!(
            t.apply_blurred_fill(c.id, (1920, 1080), BlurredFillStyle::Fit, o, &mut ids),
            Err(EditError::TrackLocked.into())
        );
        assert_eq!(t, before);
        assert_eq!(
            t.apply_blurred_fill(c.id, (0, 1080), BlurredFillStyle::Fit, o, &mut ids),
            Err(BlurredFillError::UnknownSize)
        );
        let (mut t2, _) = make(&mut ids, None, true);
        let a = t2.tracks[2].clips()[0].id;
        assert_eq!(
            t2.apply_blurred_fill(a, (1920, 1080), BlurredFillStyle::Fit, o, &mut ids),
            Err(EditError::WrongTrackKind.into())
        );
    }

    #[test]
    fn derived_ids_are_stable_distinct_and_not_involutions() {
        let id = Id::from_u128(0x0123_4567_89AB_CDEF_0123_4567_89AB_CDEF);
        let (c, r, sh) = (
            BlurredFill::derived_id(id, Role::Copy),
            BlurredFill::derived_id(id, Role::Round),
            BlurredFill::derived_id(id, Role::Shadow),
        );
        assert!(c != id && r != id && sh != id && c != r && r != sh);
        assert_ne!(BlurredFill::derived_id(c, Role::Copy), id);
        assert_eq!(c, BlurredFill::derived_id(id, Role::Copy));
    }
}
