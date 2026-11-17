// Swift: SQCore/SafeZoneChoice.swift, PlatformUIMock.swift (the SafeZoneChoice extension), MonitorMenus.swift (defaults)
//! The platform whose UI zone the Program monitor overlays.
// shortcut: this crate carries the SafeZoneChoice port because sq-core-edit's `safe_zone_choice.rs` is still empty;
// move it there (without the defaults helpers) when that file lands and re-export from here.

use sq_core_edit::cut_check::{CutCheckPlatform, NormRect, SafeZone};
use sq_core_edit::platform_uimock::{PlatformUIMock, PlatformUIMockElement};
use sq_uikit::appearance_palette::UiDefaults;

/// The platform whose UI zone the Program monitor overlays. Independent of the sequence; remembered by the app
/// (`sq.monitor.safeZone`). Creator platforms only.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum SafeZoneChoice {
    /// No zone.
    Off,
    /// TikTok.
    Tiktok,
    /// Instagram Reels.
    Reels,
    /// YouTube Shorts.
    Shorts,
    /// YouTube long-form.
    Youtube,
}

impl SafeZoneChoice {
    /// Every choice, in popup order.
    pub const ALL: [SafeZoneChoice; 5] = [Self::Off, Self::Tiktok, Self::Reels, Self::Shorts, Self::Youtube];
    /// Defaults key of the remembered platform mock switch.
    pub const MOCK_DEFAULTS_KEY: &'static str = "sq.monitor.safeZoneMock";
    /// Defaults key of the remembered choice.
    pub const DEFAULTS_KEY: &'static str = "sq.monitor.safeZone";

    /// The Swift raw value.
    pub fn raw_value(self) -> &'static str {
        match self {
            Self::Off => "off",
            Self::Tiktok => "tiktok",
            Self::Reels => "reels",
            Self::Shorts => "shorts",
            Self::Youtube => "youtube",
        }
    }

    /// The case of a raw value.
    pub fn from_raw(raw: &str) -> Option<SafeZoneChoice> {
        Self::ALL.into_iter().find(|c| c.raw_value() == raw)
    }

    /// Popup title.
    pub fn title(self) -> &'static str {
        match self {
            Self::Off => "Off",
            Self::Tiktok => "TikTok",
            Self::Reels => "Reels",
            Self::Shorts => "Shorts",
            Self::Youtube => "YouTube",
        }
    }

    /// Short label of the monitor popup ("Zone off" is shown as "Zone").
    pub fn badge_title(self) -> &'static str {
        if self == Self::Off { "Zone" } else { self.title() }
    }

    /// Unknown or missing stored values mean off.
    pub fn from_stored(stored: Option<&str>) -> SafeZoneChoice {
        stored.and_then(Self::from_raw).unwrap_or(Self::Off)
    }

    /// YouTube long-form: approximate title bar (top) and player controls (bottom) of the 16:9 player, full frame at any aspect.
    const YOUTUBE_ZONE: SafeZone = SafeZone { top: 0.08, bottom: 0.12, left: 0.05, right: 0.05 };

    /// The clear (safe) rectangle as frame fractions, origin top-left; `None` when off.
    pub fn norm_rect(self, frame_aspect: f64) -> Option<NormRect> {
        match self {
            Self::Off => None,
            Self::Tiktok => Some(SafeZone::rect_for(CutCheckPlatform::Tiktok, frame_aspect)),
            Self::Reels => Some(SafeZone::rect_for(CutCheckPlatform::Reels, frame_aspect)),
            Self::Shorts => Some(SafeZone::rect_for(CutCheckPlatform::Shorts, frame_aspect)),
            Self::Youtube => Some(Self::YOUTUBE_ZONE.rect()),
        }
    }

    /// The platforms that have a UI mock (the vertical creator apps); YouTube long-form and off have none.
    pub fn has_ui_mock(self) -> bool {
        matches!(self, Self::Tiktok | Self::Reels | Self::Shorts)
    }

    /// The mock elements for this choice in a frame of `frame_aspect`; empty when there is none.
    pub fn ui_mock(self, frame_aspect: f64) -> Vec<PlatformUIMockElement> {
        if !self.has_ui_mock() {
            return Vec::new();
        }
        match self.norm_rect(frame_aspect) {
            Some(z) => PlatformUIMock::elements(z, frame_aspect),
            None => Vec::new(),
        }
    }

    /// The choice remembered across launches and projects.
    pub fn stored(d: &dyn UiDefaults) -> SafeZoneChoice {
        Self::from_stored(d.string(Self::DEFAULTS_KEY).as_deref())
    }

    /// Remembers this choice.
    pub fn remember(self, d: &mut dyn UiDefaults) {
        d.set_string(Self::DEFAULTS_KEY, self.raw_value());
    }

    /// The remembered platform mock switch.
    pub fn stored_mock(d: &dyn UiDefaults) -> bool {
        d.integer(Self::MOCK_DEFAULTS_KEY).is_some_and(|v| v != 0)
    }

    /// Remembers the platform mock switch.
    pub fn remember_mock(on: bool, d: &mut dyn UiDefaults) {
        d.set_integer(Self::MOCK_DEFAULTS_KEY, i64::from(on));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_the_vertical_creator_apps_have_a_mock() {
        let with: Vec<SafeZoneChoice> = SafeZoneChoice::ALL.into_iter().filter(|c| c.has_ui_mock()).collect();
        assert_eq!(with, [SafeZoneChoice::Tiktok, SafeZoneChoice::Reels, SafeZoneChoice::Shorts]);
        assert!(SafeZoneChoice::Youtube.ui_mock(16.0 / 9.0).is_empty());
        assert!(!SafeZoneChoice::Tiktok.ui_mock(9.0 / 16.0).is_empty());
    }

    #[test]
    fn unknown_stored_values_mean_off() {
        assert_eq!(SafeZoneChoice::from_stored(None), SafeZoneChoice::Off);
        assert_eq!(SafeZoneChoice::from_stored(Some("nope")), SafeZoneChoice::Off);
        assert_eq!(SafeZoneChoice::from_stored(Some("reels")), SafeZoneChoice::Reels);
        assert_eq!(SafeZoneChoice::Off.badge_title(), "Zone");
    }
}
