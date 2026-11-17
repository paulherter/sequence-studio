// Swift: KeyframeControlState.swift
//! The keyframe control vocabulary every Controls row maps its model onto; the shared draw UI paints it.

/// Keyframe state shown by the animate ring (DESIGN-SPEC §4, `KeyframeToggleView.drawRing`).
/// The ring lives in the row (F11: one animate control per row), never inside a scrub field.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ScrubKeyframeState {
    /// Property not animated: gray ring, hollow diamond.
    None,
    /// Playhead on a keyframe: accent-filled ring, white diamond.
    OnKey,
    /// Animated, playhead between keys: accent ring, gray diamond.
    Between,
}

/// What the keyframe control of one property shows (INTERACTION-AUDIT §2). Pure, so every panel maps its model the
/// same way: not animated = gray ring, no navigation; animated = accent ring plus prev / diamond / next, the ring and
/// the diamond filled while the playhead sits on a key.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct KeyframeControlState {
    /// The ring state.
    pub ring: ScrubKeyframeState,
    /// Prev / diamond / next are shown only while the property is animated.
    pub shows_navigation: bool,
    /// A key exists before the playhead.
    pub can_go_previous: bool,
    /// A key exists after the playhead.
    pub can_go_next: bool,
    /// Add / remove a key at the playhead (false while the playhead is outside the clip).
    pub can_toggle_key: bool,
    /// The diamond is filled (playhead on a key).
    pub key_is_on: bool,
}

impl KeyframeControlState {
    /// Not animated: gray ring, nothing else.
    pub const OFF: KeyframeControlState = KeyframeControlState {
        ring: ScrubKeyframeState::None,
        shows_navigation: false,
        can_go_previous: false,
        can_go_next: false,
        can_toggle_key: false,
        key_is_on: false,
    };

    /// - `animated`: the property has keyframes; `on_key`: the playhead is on one of them;
    /// - `has_previous` / `has_next`: a key exists before / after the playhead; `playhead_in_range`: the playhead is inside the clip.
    pub fn resolve(
        animated: bool,
        on_key: bool,
        has_previous: bool,
        has_next: bool,
        playhead_in_range: bool,
    ) -> KeyframeControlState {
        if !animated {
            return Self::OFF;
        }
        let on = on_key && playhead_in_range;
        KeyframeControlState {
            ring: if on { ScrubKeyframeState::OnKey } else { ScrubKeyframeState::Between },
            shows_navigation: true,
            can_go_previous: has_previous,
            can_go_next: has_next,
            can_toggle_key: playhead_in_range,
            key_is_on: on,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn not_animated_is_off() {
        assert_eq!(KeyframeControlState::resolve(false, true, true, true, true), KeyframeControlState::OFF);
    }

    #[test]
    fn animated_on_a_key_fills_ring_and_diamond() {
        let s = KeyframeControlState::resolve(true, true, true, false, true);
        assert_eq!(s.ring, ScrubKeyframeState::OnKey);
        assert!(s.shows_navigation && s.can_go_previous && !s.can_go_next && s.can_toggle_key && s.key_is_on);
    }

    #[test]
    fn playhead_outside_the_clip_blocks_toggling() {
        let s = KeyframeControlState::resolve(true, true, false, true, false);
        assert_eq!(s.ring, ScrubKeyframeState::Between);
        assert!(!s.can_toggle_key && !s.key_is_on && s.can_go_next);
    }
}
