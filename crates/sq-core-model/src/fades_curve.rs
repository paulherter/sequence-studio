// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Fades+Curve.swift

use crate::{AnimatedProperty, Clip, FadeKeys, FadeMarks};
use serde::{Deserialize, Serialize};
use sq_core_time::{EaseHandle, Interpolation};

/// Shape of an audio fade (right-click menu on a fade handle). The shape lives in the ease handles of the fade's two
/// marked keys (the first key's out handle, the second key's in handle), so no model field and no file version is
/// needed: a fade without handles is `Linear`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum FadeCurve {
    /// Constant slope.
    #[serde(rename = "linear")]
    Linear,
    /// Slow start, fast middle, slow end.
    #[serde(rename = "sCurve")]
    SCurve,
    /// Equal-power shape: the level moves like the square root of the progress (the fade is louder in the middle than
    /// the linear one by up to 3 dB).
    #[serde(rename = "plus3dB")]
    Plus3dB,
    /// The opposite: the level moves like the square of the progress (quieter in the middle, up to 3 dB below linear).
    #[serde(rename = "minus3dB")]
    Minus3dB,
}

impl FadeCurve {
    /// Every curve in menu order (Swift `allCases`).
    pub const ALL: [FadeCurve; 4] = [FadeCurve::Linear, FadeCurve::SCurve, FadeCurve::Plus3dB, FadeCurve::Minus3dB];

    /// The stored name.
    pub fn from_raw(raw: &str) -> Option<FadeCurve> {
        match raw {
            "linear" => Some(FadeCurve::Linear),
            "sCurve" => Some(FadeCurve::SCurve),
            "plus3dB" => Some(FadeCurve::Plus3dB),
            "minus3dB" => Some(FadeCurve::Minus3dB),
            _ => None,
        }
    }

    /// Menu title.
    pub fn title(self) -> &'static str {
        match self {
            FadeCurve::Linear => "Linear",
            FadeCurve::SCurve => "S-Curve",
            FadeCurve::Plus3dB => "+3 dB",
            FadeCurve::Minus3dB => "-3 dB",
        }
    }

    /// Handles (out of the first key, in of the second key) that shape a fade IN (level rising) or a fade OUT.
    /// A fade out is the time mirror of the fade in: the progress is `1 - f(1 - t)`, which swaps and keeps the handles.
    fn handles(self, fade_in: bool) -> (EaseHandle, EaseHandle) {
        let h = |dx: f64, dy: f64| EaseHandle { dx, dy };
        let (out, inn) = match self {
            FadeCurve::Linear => return (EaseHandle::LINEAR, EaseHandle::LINEAR),
            FadeCurve::SCurve => return (h(1.0 / 3.0, 0.0), h(1.0 / 3.0, 0.0)),
            // y = sqrt(x) as a cubic bezier: P1 = (0, 1/3), P2 = (1/3, 2/3).
            FadeCurve::Plus3dB => (h(0.0, 1.0 / 3.0), h(2.0 / 3.0, 1.0 / 3.0)),
            // y = x * x: P1 = (1/3, 0), P2 = (2/3, 1/3).
            FadeCurve::Minus3dB => (h(1.0 / 3.0, 0.0), h(1.0 / 3.0, 2.0 / 3.0)),
        };
        if fade_in { (out, inn) } else { (inn, out) }
    }
}

fn close(a: EaseHandle, b: EaseHandle) -> bool {
    (a.dx - b.dx).abs() < 1e-6 && (a.dy - b.dy).abs() < 1e-6
}

impl FadeKeys {
    /// Curve of the head (`head`) or tail fade; `Linear` for a fade without handles or with a hand-made curve, `None`
    /// when there is no such fade.
    pub fn curve_of(p: &AnimatedProperty<f64>, marks: &FadeMarks, head: bool) -> Option<FadeCurve> {
        let ids = if head { &marks.head } else { &marks.tail };
        let (a, b) = Self::keys(p, ids)?;
        for c in FadeCurve::ALL {
            let h = c.handles(head);
            if close(a.out_handle, h.0) && close(b.in_handle, h.1) {
                return Some(c);
            }
        }
        Some(FadeCurve::Linear)
    }

    /// The property with the head or tail fade shaped as `curve`; unchanged when there is no such fade.
    pub fn setting_curve(
        curve: FadeCurve,
        prop: &AnimatedProperty<f64>,
        marks: &FadeMarks,
        head: bool,
    ) -> AnimatedProperty<f64> {
        let ids = if head { &marks.head } else { &marks.tail };
        if ids.len() != 2 {
            return prop.clone();
        }
        let (Some(ai), Some(bi)) = (prop.track.index_of(ids[0]), prop.track.index_of(ids[1])) else {
            return prop.clone();
        };
        let mut p = prop.clone();
        let h = curve.handles(head);
        p.track.keys[ai].out_handle = h.0;
        p.track.keys[ai].interpolation =
            if curve == FadeCurve::Linear { Interpolation::Linear } else { Interpolation::Bezier };
        p.track.keys[bi].in_handle = h.1;
        p
    }
}

impl Clip {
    /// Shape of the audio fade in; `None` without that fade.
    pub fn audio_fade_in_curve(&self) -> Option<FadeCurve> {
        FadeKeys::curve_of(&self.animation.volume, &self.audio_fades, true)
    }

    /// Shape of the audio fade out; `None` without that fade.
    pub fn audio_fade_out_curve(&self) -> Option<FadeCurve> {
        FadeKeys::curve_of(&self.animation.volume, &self.audio_fades, false)
    }

    /// Shapes the head or tail fade; nothing happens without that fade.
    pub fn set_audio_fade_curve(&mut self, curve: FadeCurve, head: bool) {
        self.animation.volume = FadeKeys::setting_curve(curve, &self.animation.volume, &self.audio_fades, head);
    }
}

/// User setting: the shape a new audio fade gets when its handle is dragged (`sq.audio.defaultFadeCurve`, a
/// `FadeCurve` stored name; missing or unknown = linear). The settings store itself belongs to the app shell.
pub struct DefaultFadeCurve;

impl DefaultFadeCurve {
    /// The settings key.
    pub const DEFAULTS_KEY: &'static str = "sq.audio.defaultFadeCurve";

    /// The curve a stored value stands for.
    pub fn from_stored(raw: Option<&str>) -> FadeCurve {
        raw.and_then(FadeCurve::from_raw).unwrap_or(FadeCurve::Linear)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::TrackKind;
    use crate::clip_animation::test_util::clip;
    use sq_core_time::{SequentialIds, Time};

    fn frame() -> Time {
        Time::new(1, 30)
    }

    fn audio() -> Clip {
        clip(TrackKind::Audio, 0, 4)
    }

    #[test]
    fn plain_fade_is_linear_and_no_fade_is_none() {
        let mut ids = SequentialIds::default();
        let mut c = audio();
        assert_eq!(c.audio_fade_in_curve(), None);
        c.set_audio_fade_in(Time::new(1, 1), frame(), &mut ids);
        assert_eq!(c.audio_fade_in_curve(), Some(FadeCurve::Linear));
        assert_eq!(c.audio_fade_out_curve(), None);
    }

    #[test]
    fn curves_round_trip_and_shape_the_line() {
        let mut ids = SequentialIds::default();
        let mut c = audio();
        c.set_audio_fade_in(Time::new(2, 1), frame(), &mut ids);
        let mid = Time::new(1, 1);
        assert!((c.animation.volume.value_at_local(mid) - 0.5).abs() < 1e-6);
        c.set_audio_fade_curve(FadeCurve::Plus3dB, true);
        assert_eq!(c.audio_fade_in_curve(), Some(FadeCurve::Plus3dB));
        assert!((c.animation.volume.value_at_local(mid) - 0.5_f64.sqrt()).abs() < 0.01);
        c.set_audio_fade_curve(FadeCurve::Minus3dB, true);
        assert_eq!(c.audio_fade_in_curve(), Some(FadeCurve::Minus3dB));
        assert!((c.animation.volume.value_at_local(mid) - 0.25).abs() < 0.01);
        c.set_audio_fade_curve(FadeCurve::SCurve, true);
        assert_eq!(c.audio_fade_in_curve(), Some(FadeCurve::SCurve));
        assert!(c.animation.volume.value_at_local(Time::new(1, 2)) < 0.25 - 0.01); // slower than linear at the start
        c.set_audio_fade_curve(FadeCurve::Linear, true);
        assert_eq!(c.audio_fade_in_curve(), Some(FadeCurve::Linear));
    }

    #[test]
    fn fade_out_mirrors_the_shape() {
        let mut ids = SequentialIds::default();
        let mut c = audio();
        c.set_audio_fade_out(Time::new(2, 1), frame(), &mut ids);
        c.set_audio_fade_curve(FadeCurve::Plus3dB, false);
        assert_eq!(c.audio_fade_out_curve(), Some(FadeCurve::Plus3dB));
        // Equal power: halfway through the fade out the level is sqrt(0.5), like a fade in read backwards.
        assert!((c.animation.volume.value_at_local(Time::new(3, 1)) - 0.5_f64.sqrt()).abs() < 0.01);
    }

    #[test]
    fn curve_survives_length_change() {
        let mut ids = SequentialIds::default();
        let mut c = audio();
        c.set_audio_fade_in(Time::new(1, 1), frame(), &mut ids);
        c.set_audio_fade_curve(FadeCurve::SCurve, true);
        c.set_audio_fade_in(Time::new(2, 1), frame(), &mut ids);
        assert_eq!(c.audio_fade_in_curve(), Some(FadeCurve::SCurve));
        assert_eq!(c.audio_fade_in(), Time::new(2, 1));
    }

    #[test]
    fn no_fade_ignores_curve() {
        let mut c = audio();
        c.set_audio_fade_curve(FadeCurve::SCurve, true);
        assert_eq!(c.audio_fade_in_curve(), None);
        assert!(c.animation.volume.track.is_empty());
    }

    #[test]
    fn stored_names_and_the_default_setting() {
        for c in FadeCurve::ALL {
            let raw = serde_json::to_value(c).unwrap_or_default();
            assert_eq!(FadeCurve::from_raw(raw.as_str().unwrap_or("")), Some(c));
        }
        assert_eq!(DefaultFadeCurve::from_stored(Some("plus3dB")), FadeCurve::Plus3dB);
        assert_eq!(DefaultFadeCurve::from_stored(Some("nonsense")), FadeCurve::Linear);
        assert_eq!(DefaultFadeCurve::from_stored(None), FadeCurve::Linear);
        assert_eq!(FadeCurve::Minus3dB.title(), "-3 dB");
    }
}
