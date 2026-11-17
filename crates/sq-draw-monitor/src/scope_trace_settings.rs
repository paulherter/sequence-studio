// Swift: ScopeTraceSettings.swift
//! The waveform settings of the scopes, one set for every scopes view: the trace intensity of the Waveform and RGB Parade
//! (the renderers' `intensity` gain), chosen from `menu_items()` and kept in the defaults. The vectorscope and histogram
//! keep their own map (gain 1).

use crate::memory_defaults::MemoryDefaults;
use sq_draw::monitor::scope_graticule::ScopeKind;
use sq_uikit::appearance_palette::UiDefaults;
use sq_uikit::sqmenu_model::SQMenuItem;
use std::rc::Rc;

/// The trace intensity and where it is kept.
pub struct ScopeTraceSettings {
    intensity: f32,
    version: u64,
    defaults: Box<dyn UiDefaults>,
}

impl ScopeTraceSettings {
    /// Defaults key of the intensity.
    pub const DEFAULTS_KEY: &'static str = "sq.scopes.waveformIntensity";
    /// The menu's intensity steps.
    pub const STEPS: [f32; 5] = [0.5, 0.75, 1.0, 1.5, 2.0];
    /// Lowest intensity.
    pub const MIN: f32 = 0.25;
    /// Highest intensity.
    pub const MAX: f32 = 4.0;
    /// The settings button's tip and menu header.
    pub const BUTTON_TIP: &'static str = "Waveform settings";

    /// Settings over an in-memory store (tests and hosts without a store).
    pub fn new() -> ScopeTraceSettings {
        Self::with_defaults(Box::new(MemoryDefaults::default()))
    }

    /// Settings over `defaults`; the stored intensity is clamped.
    pub fn with_defaults(defaults: Box<dyn UiDefaults>) -> ScopeTraceSettings {
        // The Swift store holds a Double; ours keeps it as decimal text (the UiDefaults store has no float).
        let stored = defaults.string(Self::DEFAULTS_KEY).and_then(|s| s.parse::<f64>().ok());
        let intensity = stored.map_or(1.0, |v| (v as f32).clamp(Self::MIN, Self::MAX));
        ScopeTraceSettings { intensity, version: 0, defaults }
    }

    /// The trace gain of the Waveform and RGB Parade (1 = the renderers' default map).
    pub fn intensity(&self) -> f32 {
        self.intensity
    }

    /// Changes whenever the intensity does, so every scopes view redraws (the Swift `didChange` notification).
    pub fn version(&self) -> u64 {
        self.version
    }

    /// Sets the intensity (clamped), stores it and bumps the version when it changed.
    pub fn set_intensity(&mut self, v: f32) {
        let v = v.clamp(Self::MIN, Self::MAX);
        if v == self.intensity {
            return;
        }
        self.intensity = v;
        self.defaults.set_string(Self::DEFAULTS_KEY, &f64::from(v).to_string());
        self.version += 1;
    }

    /// The scopes these settings apply to.
    pub fn has_settings(k: ScopeKind) -> bool {
        k == ScopeKind::Waveform || k == ScopeKind::Parade
    }

    /// The gain `k` is drawn with.
    pub fn intensity_for(&self, k: ScopeKind) -> f32 {
        if Self::has_settings(k) { self.intensity } else { 1.0 }
    }

    /// The settings menu: a header and the intensity steps, the current one checked. A pick calls `set`.
    pub fn menu_items(&self, set: Rc<dyn Fn(f32)>) -> Vec<SQMenuItem> {
        let mut rows = vec![SQMenuItem::header("Intensity")];
        for v in Self::STEPS {
            let mut i = SQMenuItem::new(&format!("{}%", (v * 100.0).round() as i64));
            i.is_checked = (self.intensity - v).abs() < 0.001;
            let set = Rc::clone(&set);
            i.action = Some(Rc::new(move || set(v)));
            rows.push(i);
        }
        rows
    }
}

impl Default for ScopeTraceSettings {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_uikit::sqmenu_model::SQMenuItemKind;
    use std::cell::RefCell;

    #[test]
    fn intensity_defaults_to_one_is_clamped_and_persists() {
        let mut d = MemoryDefaults::default();
        let mut s = ScopeTraceSettings::with_defaults(Box::new(d.clone()));
        assert_eq!(s.intensity(), 1.0);
        s.set_intensity(9.0);
        assert_eq!(s.intensity(), ScopeTraceSettings::MAX);
        s.set_intensity(0.0);
        assert_eq!(s.intensity(), ScopeTraceSettings::MIN);
        // a store that already holds a value is read back, clamped
        d.set_string(ScopeTraceSettings::DEFAULTS_KEY, "1.5");
        assert_eq!(ScopeTraceSettings::with_defaults(Box::new(d.clone())).intensity(), 1.5);
        d.set_string(ScopeTraceSettings::DEFAULTS_KEY, "99");
        assert_eq!(ScopeTraceSettings::with_defaults(Box::new(d)).intensity(), ScopeTraceSettings::MAX);
    }

    #[test]
    fn only_the_waveform_traces_take_the_intensity() {
        let mut s = ScopeTraceSettings::new();
        s.set_intensity(2.0);
        assert!(s.intensity_for(ScopeKind::Waveform) == 2.0 && s.intensity_for(ScopeKind::Parade) == 2.0);
        assert!(s.intensity_for(ScopeKind::Vectorscope) == 1.0 && s.intensity_for(ScopeKind::Histogram) == 1.0);
        assert!(
            ScopeTraceSettings::has_settings(ScopeKind::Waveform)
                && ScopeTraceSettings::has_settings(ScopeKind::Parade)
        );
        assert!(!ScopeTraceSettings::has_settings(ScopeKind::Vectorscope));
        assert!(!ScopeTraceSettings::has_settings(ScopeKind::Histogram));
    }

    #[test]
    fn the_menu_lists_the_steps_with_the_current_one_checked_and_a_change_bumps_the_version() {
        let mut s = ScopeTraceSettings::new();
        let picked: Rc<RefCell<Vec<f32>>> = Rc::default();
        let sink = Rc::clone(&picked);
        let items = s.menu_items(Rc::new(move |v| sink.borrow_mut().push(v)));
        let choices: Vec<&SQMenuItem> = items.iter().filter(|i| i.kind == SQMenuItemKind::Action).collect();
        assert_eq!(
            choices.iter().map(|i| i.title.as_str()).collect::<Vec<_>>(),
            ["50%", "75%", "100%", "150%", "200%"]
        );
        assert_eq!(choices.iter().filter(|i| i.is_checked).map(|i| i.title.as_str()).collect::<Vec<_>>(), ["100%"]);
        if let Some(a) = &choices[3].action {
            a();
        }
        assert_eq!(*picked.borrow(), [1.5]);
        s.set_intensity(1.5);
        assert_eq!(s.version(), 1);
        let again = s.menu_items(Rc::new(|_| {}));
        assert_eq!(again.iter().filter(|i| i.is_checked).map(|i| i.title.as_str()).collect::<Vec<_>>(), ["150%"]);
        s.set_intensity(1.5);
        assert_eq!(s.version(), 1, "no change, no bump");
    }
}
