// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: PixelAspect.swift (saved type, moved down; presets, display width, video info and Project edits: task M-4)

use crate::{Project, VideoTrackInfo};
use serde::{Deserialize, Serialize};
use sq_core_time::Id;

/// The shape of one stored pixel, width / height, as an exact ratio (2:1 = a 2x anamorphic lens, 1:1 = square).
///
/// Always reduced and within 1:4 ... 4:1; anything else is a broken tag and has no value (callers fall back to
/// square).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(try_from = "PixelAspectFields")]
pub struct PixelAspect {
    num: i64,
    den: i64,
}

#[derive(Deserialize)]
struct PixelAspectFields {
    num: i64,
    den: i64,
}

impl TryFrom<PixelAspectFields> for PixelAspect {
    type Error = &'static str;

    fn try_from(f: PixelAspectFields) -> Result<Self, Self::Error> {
        PixelAspect::new(f.num, f.den).ok_or("pixel aspect outside 1:4 ... 4:1")
    }
}

impl PixelAspect {
    /// Square pixels, 1:1.
    pub const fn square() -> PixelAspect {
        PixelAspect { num: 1, den: 1 }
    }

    /// The reduced ratio; `None` for a ratio that is not positive or lies outside 1:4 ... 4:1.
    pub fn new(num: i64, den: i64) -> Option<PixelAspect> {
        let (num4, den4) = (num.checked_mul(4)?, den.checked_mul(4)?);
        if num <= 0 || den <= 0 || num > den4 || den > num4 {
            return None;
        }
        let (mut a, mut b) = (num, den);
        while b != 0 {
            (a, b) = (b, a % b);
        }
        Some(PixelAspect { num: num / a, den: den / a })
    }

    /// Numerator (width part).
    pub fn num(&self) -> i64 {
        self.num
    }

    /// Denominator (height part).
    pub fn den(&self) -> i64 {
        self.den
    }

    /// 1:1.
    pub fn is_square(&self) -> bool {
        self.num == self.den
    }

    /// What the source settings offer: square and the common anamorphic squeeze factors (1.33 is the exact 4:3).
    pub const PRESETS: [PixelAspect; 7] = [
        PixelAspect { num: 1, den: 1 },
        PixelAspect { num: 5, den: 4 },
        PixelAspect { num: 4, den: 3 },
        PixelAspect { num: 3, den: 2 },
        PixelAspect { num: 8, den: 5 },
        PixelAspect { num: 9, den: 5 },
        PixelAspect { num: 2, den: 1 },
    ];

    /// For display and for import mapping only; sizes are computed from the ratio.
    pub fn value(&self) -> f64 {
        self.num as f64 / self.den as f64
    }

    /// Width in whole pixels at which `stored` pixels of this shape are shown. Square pixels keep the stored width; any
    /// other shape gives the nearest even number (at least 2): this one value is the layer size in playback and export
    /// and the width of a sequence made from the clip, and encoders take even sizes only (720 at 10:11 is 654).
    pub fn display_width(&self, stored: i64) -> i64 {
        if stored <= 0 {
            return 0;
        }
        if self.is_square() {
            return stored;
        }
        let Some(wide) = stored.checked_mul(self.num) else { return stored };
        (2 * ((wide + self.den) / (2 * self.den))).max(2)
    }
}

impl VideoTrackInfo {
    /// The pixel aspect the picture is shown with: the one chosen for the media item, else the file's own.
    pub fn display_pixel_aspect(&self) -> PixelAspect {
        self.pixel_aspect_override.unwrap_or(self.pixel_aspect)
    }

    /// Stored width desqueezed, before any rotation: with `height`, the size the decoded frame is drawn at for Scale 1.
    pub fn desqueezed_width(&self) -> i64 {
        self.display_pixel_aspect().display_width(self.width)
    }

    /// A decoder's info of a file, read the way the project reads that media item (`project` = `MediaRef.info.video`):
    /// the item's pixel aspect and its override replace the decoder's. An item probed before pixel aspect existed says
    /// square, so old projects keep their picture. `None` (media the project has no info for: a legacy item, a file not
    /// yet probed) is square too: only the project decides, a picture never changes shape by being opened.
    pub fn adopting_pixel_aspect(&self, project: Option<&VideoTrackInfo>) -> VideoTrackInfo {
        let mut out = self.clone();
        out.pixel_aspect = project.map_or(PixelAspect::square(), |p| p.pixel_aspect);
        out.pixel_aspect_override = project.and_then(|p| p.pixel_aspect_override);
        out
    }
}

impl Project {
    /// The pixel aspect `id`'s picture is shown with; `None` for unknown media and media without a (probed) picture.
    pub fn pixel_aspect_of(&self, id: Id) -> Option<PixelAspect> {
        self.media(id)?.info.as_ref()?.video.as_ref().map(VideoTrackInfo::display_pixel_aspect)
    }

    /// Source settings > Pixel Aspect: how `id`'s pixels are read from now on, for every clip of it (a setting of the
    /// media item, not of a clip; subclips share their file's setting). `None` = what the file says. Clips keep their
    /// Scale, so the picture changes width where it is used. Returns whether anything changed; false for unknown media
    /// and for media without a probed picture.
    pub fn set_pixel_aspect(&mut self, aspect: Option<PixelAspect>, id: Id) -> bool {
        let Some(item) = self.media(id) else { return false };
        let file = item.subclip.as_ref().map_or(id, |s| s.parent);
        let mut changed = false;
        for m in &mut self.media {
            if m.id != file && m.subclip.as_ref().map(|s| s.parent) != Some(file) {
                continue;
            }
            let Some(v) = m.info.as_mut().and_then(|i| i.video.as_mut()) else { continue };
            let value = if aspect == Some(v.pixel_aspect) { None } else { aspect };
            if value != v.pixel_aspect_override {
                v.pixel_aspect_override = value;
                changed = true;
            }
        }
        changed
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::media_info::assert_round_trip;
    use serde_json::json;

    #[test]
    fn new_reduces_and_checks_the_range() {
        assert_eq!(PixelAspect::new(8, 4).map(|p| (p.num(), p.den())), Some((2, 1)));
        assert_eq!(PixelAspect::new(4, 1).map(|p| p.num()), Some(4));
        assert!(PixelAspect::new(5, 1).is_none());
        assert!(PixelAspect::new(1, 5).is_none());
        assert!(PixelAspect::new(0, 1).is_none());
        assert!(PixelAspect::new(-1, 1).is_none());
        assert!(PixelAspect::new(i64::MAX, i64::MAX).is_none());
        assert!(PixelAspect::square().is_square());
    }

    #[test]
    fn decoding_rejects_a_ratio_outside_the_range_and_reduces() {
        assert!(serde_json::from_value::<PixelAspect>(json!({"num": 1, "den": 9})).is_err());
        let p: PixelAspect = serde_json::from_value(json!({"num": 6, "den": 3})).unwrap();
        assert_eq!((p.num(), p.den()), (2, 1));
        assert_round_trip::<PixelAspect>(json!({"num": 4, "den": 3}));
    }
    #[test]
    fn presets_are_exact() {
        let values: Vec<f64> = PixelAspect::PRESETS.iter().map(PixelAspect::value).collect();
        assert_eq!(values, [1.0, 1.25, 4.0 / 3.0, 1.5, 1.6, 1.8, 2.0]);
        assert!(PixelAspect::PRESETS[0].is_square());
        assert!(PixelAspect::PRESETS.iter().all(|p| p.num() > 0 && p.den() > 0));
    }

    fn par(n: i64, d: i64) -> PixelAspect {
        PixelAspect::new(n, d).unwrap_or_else(PixelAspect::square)
    }

    #[test]
    fn display_width_is_even_for_non_square_pixels() {
        let sq = PixelAspect::square();
        assert_eq!((sq.display_width(1920), sq.display_width(721)), (1920, 721));
        assert_eq!(par(2, 1).display_width(1920), 3840);
        assert_eq!((par(4, 3).display_width(1440), par(4, 3).display_width(1920)), (1920, 2560));
        assert_eq!(par(10, 11).display_width(720), 654, "654.5: nearest even");
        assert_eq!(par(40, 33).display_width(720), 872, "872.7");
        for a in &PixelAspect::PRESETS[1..] {
            for w in [1, 3, 719, 720, 1439, 1920, 4095] {
                assert_eq!(a.display_width(w) % 2, 0, "{a:?} {w}");
            }
        }
        assert_eq!(par(9, 5).display_width(3), 6, "5.4");
        assert_eq!(par(1, 4).display_width(1), 2, "never 0");
        assert_eq!(par(2, 1).display_width(0), 0);
    }

    fn video(w: i64, h: i64, rotation: i64, tag: PixelAspect, over: Option<PixelAspect>) -> VideoTrackInfo {
        let mut v = json!({"width": w, "height": h, "codec": "avc1", "bitDepth": 8, "chroma": "4:2:0",
            "nominalFrameDuration": {"value": 1, "timescale": 25}, "isVariableFrameRate": false, "rotation": rotation});
        v["pixelAspect"] = json!({"num": tag.num(), "den": tag.den()});
        if let Some(o) = over {
            v["pixelAspectOverride"] = json!({"num": o.num(), "den": o.den()});
        }
        serde_json::from_value(v).unwrap_or_else(|e| panic!("video: {e}"))
    }

    #[test]
    fn display_size_uses_tag_override_and_rotation() {
        let sq = PixelAspect::square();
        assert_eq!(video(1920, 1080, 0, sq, None).display_width(), 1920);
        let tagged = video(1440, 1080, 0, par(4, 3), None);
        assert_eq!((tagged.display_width(), tagged.display_height(), tagged.desqueezed_width()), (1920, 1080, 1920));
        let overridden = video(1440, 1080, 0, par(4, 3), Some(sq));
        assert_eq!((overridden.display_pixel_aspect(), overridden.display_width()), (sq, 1440));
        // The stored width is desqueezed before the quarter turn.
        let turned = video(1920, 1080, 90, sq, Some(par(2, 1)));
        assert_eq!((turned.display_width(), turned.display_height()), (1080, 3840));
        assert_eq!((turned.desqueezed_width(), turned.height), (3840, 1080));
    }

    #[test]
    fn adopting_takes_the_projects_aspect_or_square() {
        let decoder = video(1440, 1080, 0, par(4, 3), None);
        let project = video(1440, 1080, 0, par(5, 4), Some(par(2, 1)));
        let adopted = decoder.adopting_pixel_aspect(Some(&project));
        assert_eq!((adopted.pixel_aspect, adopted.pixel_aspect_override), (par(5, 4), Some(par(2, 1))));
        let none = decoder.adopting_pixel_aspect(None);
        assert_eq!((none.pixel_aspect, none.pixel_aspect_override), (PixelAspect::square(), None));
    }

    fn project_with(v: &VideoTrackInfo) -> Project {
        use crate::nesting::test_util::*;
        let info = json!({"duration": time(10, 1), "video": serde_json::to_value(v).unwrap_or_default()});
        let media = json!({"id": id(1), "name": "a.mov", "path": "/a.mov", "fingerprint": {"size": 1},
            "duration": time(10, 1), "info": info});
        project_json(vec![media], vec![timeline_json(10, vec![])])
    }

    #[test]
    fn set_pixel_aspect_overrides_the_file_and_resets() {
        use crate::nesting::test_util::id;
        let mut p = project_with(&video(1440, 1080, 0, par(4, 3), None));
        assert_eq!(p.pixel_aspect_of(id(1)), Some(par(4, 3)));
        assert!(p.set_pixel_aspect(Some(par(2, 1)), id(1)));
        assert_eq!(p.pixel_aspect_of(id(1)), Some(par(2, 1)));
        assert!(!p.set_pixel_aspect(Some(par(2, 1)), id(1)), "unchanged");
        assert!(p.set_pixel_aspect(Some(par(4, 3)), id(1)), "the file's own value clears the override");
        assert_eq!(p.media(id(1)).and_then(|m| m.info.as_ref()?.video.as_ref()?.pixel_aspect_override), None);
        assert!(!p.set_pixel_aspect(Some(par(2, 1)), id(9)), "unknown media");
        assert_eq!(p.pixel_aspect_of(id(9)), None);
    }

    #[test]
    fn set_pixel_aspect_reaches_subclips_of_the_file() {
        use crate::nesting::test_util::id;
        let mut p = project_with(&video(1440, 1080, 0, par(4, 3), None));
        let mut sub = p.media[0].clone();
        sub.id = id(2);
        sub.subclip = Some(crate::Subclip {
            parent: id(1),
            range: sq_core_time::TimeRange::new(sq_core_time::Time::ZERO, sq_core_time::Time::new(1, 1)),
        });
        p.media.push(sub);
        assert!(p.set_pixel_aspect(Some(par(2, 1)), id(2)), "set through the subclip");
        assert_eq!((p.pixel_aspect_of(id(1)), p.pixel_aspect_of(id(2))), (Some(par(2, 1)), Some(par(2, 1))));
    }
}
