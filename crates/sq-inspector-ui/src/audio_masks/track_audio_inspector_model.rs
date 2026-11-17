// Swift: TrackAudioInspectorModel.swift
//! State behind the track audio inspector (preset popup, noise reduction, 4-band compressor).

use std::ops::RangeInclusive;

use sq_audiofx::creator_fx::{NoiseGateLimits, NoiseGateSettings, SaturationLimits, SaturationSettings};
use sq_audiofx::presets::{MultibandBand, MultibandCompressorSettings, PresetLibrary, TrackAudioPreset};
use sq_core_model::AudioTag;
use sq_core_time::IdSource;

/// `AudioTag.allCases`.
pub const ALL_TAGS: [AudioTag; 3] = [AudioTag::Dialogue, AudioTag::Music, AudioTag::Sfx];

/// Crossover limits shared by the inspector model and the bands view.
pub enum CrossoverRules {}

impl CrossoverRules {
    pub const MIN_HZ: f64 = 20.0;
    pub const MAX_HZ: f64 = 20_000.0;
    /// Minimum distance between neighboring crossovers as a frequency ratio (about 1/4 octave).
    pub const MIN_RATIO: f64 = 1.2;

    /// Clamps crossover `index` of `current` (3 ascending values) to `hz`, keeping order and spacing.
    pub fn clamp(hz: f64, index: usize, current: &[f64]) -> f64 {
        let lower = if index > 0 { current[index - 1] * Self::MIN_RATIO } else { Self::MIN_HZ };
        let upper = if index + 1 < current.len() { current[index + 1] / Self::MIN_RATIO } else { Self::MAX_HZ };
        hz.max(lower).min(lower.max(upper))
    }
}

pub enum BandLimits {}

impl BandLimits {
    pub const THRESHOLD_DB: RangeInclusive<f64> = -60.0..=0.0;
    pub const RATIO: RangeInclusive<f64> = 1.0..=20.0;
    pub const ATTACK_MS: RangeInclusive<f64> = 0.5..=500.0;
    pub const RELEASE_MS: RangeInclusive<f64> = 5.0..=2000.0;
    pub const GAIN_DB: RangeInclusive<f64> = -24.0..=24.0;
    pub const OVERALL_GAIN_DB: RangeInclusive<f64> = -24.0..=24.0;
}

fn clamped(v: f64, r: RangeInclusive<f64>) -> f64 {
    v.clamp(*r.start(), *r.end())
}

/// Swift `CharacterSet.whitespaces`: spaces and tabs, no line breaks.
fn trim_whitespaces(s: &str) -> &str {
    s.trim_matches(|c: char| {
        c == '\t'
            || (c.is_whitespace() && !matches!(c, '\n' | '\r' | '\u{b}' | '\u{c}' | '\u{85}' | '\u{2028}' | '\u{2029}'))
    })
}

/// A hook of `TrackAudioInspectorModel` (Swift `onBeginChange`, `onEndChange`, `onChange`, `onRoleChange`), in call order.
#[derive(Clone, Debug, PartialEq)]
pub enum TrackAudioEvent {
    BeginChange,
    EndChange,
    /// After every effective change with the resulting values.
    Change(Box<TrackAudioPreset>),
    /// The user picked a role (inside one change bracket). The host saves it; an untouched chain follows the role, an edited one stays.
    RoleChange(Option<AudioTag>),
    /// The user picked a loudness target for the track (`None`: the role's default). Not a preset change.
    LoudnessChange(Option<f64>),
}

/// State behind the track audio inspector (preset popup, noise reduction, 4-band compressor).
/// Every mutation reports `Change`; changes are bracketed by `BeginChange` / `EndChange`
/// so the host can open and close one undo group per gesture. Discrete edits bracket themselves;
/// slider drags call `begin_change()` / `end_change()` around the gesture (nesting is counted).
pub struct TrackAudioInspectorModel {
    library: PresetLibrary,
    /// Preset the current values were loaded from; None after deleting it or for unsaved custom values.
    selected_preset_id: Option<String>,
    compressor: MultibandCompressorSettings,
    /// Denoiser wet/dry mix 0...1.
    noise_reduction: f64,
    gate: NoiseGateSettings,
    saturation: SaturationSettings,
    /// The loaded preset's de-esser (the Voice role turns it on); carried through every edit so a tweak keeps it.
    de_ess: bool,
    /// Track role (Dialogue / Music / SFX); picking one loads its voiced preset.
    role: Option<AudioTag>,
    /// The Loudness target (LUFS) the track chose; `None` = the role's default.
    loudness_target: Option<f64>,
    /// The Clean Voice amount (0...1) the switch brings back after being turned off.
    clean_voice_memory: f64,
    /// Bumped by every change of the shown state.
    pub version: u64,
    events: Vec<TrackAudioEvent>,
    depth: i64,
    ids: Box<dyn IdSource>,
}

impl TrackAudioInspectorModel {
    /// The amount Clean Voice starts at when switched on with nothing remembered (the Voice preset's 60 %).
    pub const DEFAULT_CLEAN_VOICE: f64 = 0.6;

    /// Without an explicit `preset`, a `role` starts on its voiced preset.
    pub fn new(
        library: PresetLibrary,
        preset: Option<TrackAudioPreset>,
        role: Option<AudioTag>,
        ids: Box<dyn IdSource>,
    ) -> Self {
        let preset = preset.or_else(|| role.map(TrackAudioPreset::for_role)).unwrap_or_else(TrackAudioPreset::off);
        TrackAudioInspectorModel {
            library,
            role,
            loudness_target: None,
            selected_preset_id: Some(preset.id.clone()),
            compressor: preset.compressor,
            noise_reduction: preset.noise_reduction,
            gate: preset.gate,
            saturation: preset.saturation,
            de_ess: preset.de_ess,
            clean_voice_memory: Self::DEFAULT_CLEAN_VOICE,
            version: 0,
            events: Vec::new(),
            depth: 0,
            ids,
        }
    }

    /// The hook calls since the last call, in order.
    pub fn take_events(&mut self) -> Vec<TrackAudioEvent> {
        std::mem::take(&mut self.events)
    }

    pub fn library(&self) -> &PresetLibrary {
        &self.library
    }
    pub fn selected_preset_id(&self) -> Option<&str> {
        self.selected_preset_id.as_deref()
    }
    pub fn compressor(&self) -> &MultibandCompressorSettings {
        &self.compressor
    }
    pub fn noise_reduction(&self) -> f64 {
        self.noise_reduction
    }
    pub fn gate(&self) -> NoiseGateSettings {
        self.gate
    }
    pub fn saturation(&self) -> SaturationSettings {
        self.saturation
    }
    pub fn role(&self) -> Option<AudioTag> {
        self.role
    }

    // MARK: Derived

    /// Whether a library or user preset other than the role's own voiced one is loaded: the preset replaced the whole chain
    /// (Swift `selectPreset` loads compressor, noise reduction, gate and saturation), so the role no longer names it.
    pub fn role_is_overridden(&self) -> bool {
        self.role.is_some_and(|r| self.selected_preset_id.as_deref() != Some(TrackAudioPreset::for_role(r).id.as_str()))
    }

    /// Whether the Role control shows `role` as active: it is the track's role and its own voiced preset is what runs.
    pub fn role_is_active(&self, role: AudioTag) -> bool {
        self.role == Some(role) && !self.role_is_overridden()
    }

    /// Library presets, plus the current role's voiced preset.
    pub fn presets(&self) -> Vec<TrackAudioPreset> {
        let mut all = self.library.all();
        if let Some(r) = self.role {
            all.push(TrackAudioPreset::for_role(r));
        }
        all
    }

    /// Role popup titles: "None" then every role.
    pub fn role_titles() -> Vec<&'static str> {
        let mut t = vec!["None"];
        t.extend(ALL_TAGS.iter().map(|r| r.title()));
        t
    }

    pub fn noise_reduction_percent(&self) -> f64 {
        (self.noise_reduction * 100.0).round()
    }

    pub fn selected_preset(&self) -> Option<TrackAudioPreset> {
        self.selected_preset_id.as_deref().and_then(|id| self.library.preset(id))
    }

    pub fn is_modified(&self) -> bool {
        let Some(p) = self.selected_preset() else { return true };
        p.compressor != self.compressor
            || p.noise_reduction != self.noise_reduction
            || p.gate != self.gate
            || p.saturation != self.saturation
    }

    pub fn can_edit_selected_preset(&self) -> bool {
        self.selected_preset().is_some_and(|p| !p.is_built_in)
    }

    /// Current values as an anonymous preset (what the engine should apply).
    pub fn current_values(&self) -> TrackAudioPreset {
        let id = self.selected_preset_id.clone().unwrap_or_else(|| "custom".to_string());
        let name = self.selected_preset().map(|p| p.name).unwrap_or_else(|| "Custom".to_string());
        let mut p =
            TrackAudioPreset::new(&id, &name, self.compressor.clone()).with_noise_reduction(self.noise_reduction);
        p.gate = self.gate;
        p.saturation = self.saturation;
        p.de_ess = self.de_ess;
        p
    }

    // MARK: Change bracketing

    pub fn begin_change(&mut self) {
        if self.depth == 0 {
            self.events.push(TrackAudioEvent::BeginChange);
        }
        self.depth += 1;
    }

    pub fn end_change(&mut self) {
        if self.depth <= 0 {
            return;
        }
        self.depth -= 1;
        if self.depth == 0 {
            self.events.push(TrackAudioEvent::EndChange);
        }
    }

    fn edit(&mut self, body: impl FnOnce(&mut Self)) {
        let old_c = self.compressor.clone();
        let old_n = self.noise_reduction;
        let old_g = self.gate;
        let old_s = self.saturation;
        let old_d = self.de_ess;
        self.begin_change();
        body(self);
        self.version += 1;
        if self.compressor != old_c
            || self.noise_reduction != old_n
            || self.gate != old_g
            || self.saturation != old_s
            || self.de_ess != old_d
        {
            self.events.push(TrackAudioEvent::Change(Box::new(self.current_values())));
        }
        self.end_change();
    }

    // MARK: Presets

    pub fn select_preset(&mut self, id: &str) {
        let Some(p) = self.library.preset(id) else { return };
        self.edit(|m| {
            m.selected_preset_id = Some(p.id.clone());
            m.compressor = p.compressor.clone();
            m.noise_reduction = p.noise_reduction;
            m.gate = p.gate;
            m.saturation = p.saturation;
            m.de_ess = p.de_ess;
        });
        // Selecting the same preset with modified values resets them; selecting it unchanged is a no-op.
    }

    /// Sets the track role and shows its voiced preset (None: back to Off), unless the chain was edited or picked: that
    /// stays. One change bracket; same role is a no-op.
    /// Reports only `RoleChange`, never `Change`: the role is the single source of truth and the engine resolves
    /// role -> preset itself, so the role preset is never stored as an explicit preset (undo of the role stays exact).
    pub fn set_role(&mut self, new_role: Option<AudioTag>) {
        // The same role again still counts while another preset replaced its chain: it loads the voiced preset back.
        if new_role == self.role && !self.role_is_overridden() {
            return;
        }
        // Typed edits and a picked preset stay with the track (the session keeps them too); the role chip then lets go,
        // and picking the role again loads its voiced preset back.
        let edited =
            new_role != self.role && !self.current_values().same_chain(&TrackAudioPreset::starting_chain(self.role));
        self.begin_change();
        if edited {
            self.role = new_role;
            self.version += 1;
        } else {
            self.load_role(new_role);
        }
        self.events.push(TrackAudioEvent::RoleChange(new_role));
        self.end_change();
    }

    /// The Loudness target the track chose (`None`: the role's default).
    pub fn loudness_target(&self) -> Option<f64> {
        self.loudness_target
    }

    /// The target the Loudness row shows and Match Loudness aims for: the track's choice, else the role's default,
    /// else the dialogue default (what the engine does for a track without a role).
    pub fn effective_loudness_target(&self) -> f64 {
        self.loudness_target.unwrap_or_else(|| self.role.unwrap_or(AudioTag::Dialogue).target_lufs())
    }

    /// The Loudness choices the dropdown offers: title and target (`None` = the role's default).
    pub fn loudness_choices() -> [(&'static str, Option<f64>); 5] {
        [
            ("Role default", None),
            ("Web \u{b7} \u{2212}14 LUFS", Some(-14.0)),
            ("Streaming \u{b7} \u{2212}16 LUFS", Some(-16.0)),
            ("Music bed \u{b7} \u{2212}20 LUFS", Some(-20.0)),
            ("Broadcast \u{b7} \u{2212}23 LUFS", Some(-23.0)),
        ]
    }

    /// The name of a target in the dropdown ("Web \u{b7} \u{2212}14 LUFS"); a value that is none of the choices reads "Custom".
    pub fn loudness_title(lufs: f64) -> String {
        Self::loudness_choices()
            .iter()
            .find(|(_, v)| v.is_some_and(|v| (v - lufs).abs() < 0.05))
            .map_or_else(|| format!("Custom \u{b7} \u{2212}{:.0} LUFS", lufs.abs()), |(t, _)| (*t).to_string())
    }

    /// The user picked a loudness target; reports `LoudnessChange` (a same value is a no-op).
    pub fn set_loudness_target(&mut self, target: Option<f64>) {
        if target == self.loudness_target {
            return;
        }
        self.loudness_target = target;
        self.events.push(TrackAudioEvent::LoudnessChange(target));
    }

    /// Follows a loudness target changed elsewhere (undo/redo): no callbacks.
    pub fn sync_loudness_target(&mut self, target: Option<f64>) {
        self.loudness_target = target;
    }

    /// Follows a role changed elsewhere (undo/redo, another view): shows its preset, no callbacks.
    pub fn sync_role(&mut self, new_role: Option<AudioTag>) {
        if new_role == self.role {
            return;
        }
        self.load_role(new_role);
    }

    fn load_role(&mut self, new_role: Option<AudioTag>) {
        self.role = new_role;
        self.load_values(TrackAudioPreset::starting_chain(new_role));
    }

    fn load_values(&mut self, p: TrackAudioPreset) {
        self.selected_preset_id = Some(p.id.clone());
        self.compressor = p.compressor;
        self.noise_reduction = p.noise_reduction;
        self.gate = p.gate;
        self.saturation = p.saturation;
        self.de_ess = p.de_ess;
        self.version += 1;
    }

    /// Follows the project's stored tweaks of this track (open, undo, redo, another view): `None` shows the role's own
    /// preset. No callbacks; nothing happens when the values already match.
    pub fn sync_preset(&mut self, stored: Option<&TrackAudioPreset>) {
        let wanted = stored.cloned().unwrap_or_else(|| TrackAudioPreset::starting_chain(self.role));
        if !self.current_values().same_chain(&wanted) {
            self.load_values(wanted);
        }
    }

    /// Saves the current values as a new user preset and selects it.
    pub fn save_as_user_preset(&mut self, name: &str) {
        let trimmed = trim_whitespaces(name);
        if trimmed.is_empty() {
            return;
        }
        self.begin_change();
        let mut preset =
            TrackAudioPreset::new("", trimmed, self.compressor.clone()).with_noise_reduction(self.noise_reduction);
        preset.gate = self.gate;
        preset.saturation = self.saturation;
        let saved = self.library.save_user(&preset, self.ids.as_mut());
        self.selected_preset_id = Some(saved.id);
        self.version += 1;
        self.events.push(TrackAudioEvent::Change(Box::new(self.current_values())));
        self.end_change();
    }

    pub fn rename_selected_preset(&mut self, name: &str) {
        let trimmed = trim_whitespaces(name);
        if !self.can_edit_selected_preset() || trimmed.is_empty() {
            return;
        }
        let Some(id) = self.selected_preset_id.clone() else { return };
        self.begin_change();
        self.library.rename(&id, trimmed);
        self.version += 1;
        self.end_change();
    }

    /// Deletes the selected user preset; the values stay as custom.
    pub fn delete_selected_preset(&mut self) {
        if !self.can_edit_selected_preset() {
            return;
        }
        let Some(id) = self.selected_preset_id.clone() else { return };
        self.begin_change();
        self.library.remove(&id);
        self.selected_preset_id = None;
        self.version += 1;
        self.end_change();
    }

    // MARK: Values

    pub fn set_noise_reduction_percent(&mut self, percent: f64) {
        let v = clamped(percent, 0.0..=100.0).round() / 100.0;
        self.edit(|m| m.noise_reduction = v);
    }

    /// Clean Voice = the denoiser (`noise_reduction` is its wet mix): on while the mix is above 0.
    pub fn clean_voice_on(&self) -> bool {
        self.noise_reduction > 0.0
    }

    /// Off sets the mix to 0 and remembers it; on brings the remembered amount back (60 % if none).
    pub fn set_clean_voice(&mut self, on: bool) {
        if on == self.clean_voice_on() {
            return;
        }
        if on {
            let v = if self.clean_voice_memory > 0.0 { self.clean_voice_memory } else { Self::DEFAULT_CLEAN_VOICE };
            self.edit(|m| m.noise_reduction = v);
        } else {
            self.clean_voice_memory = self.noise_reduction;
            self.edit(|m| m.noise_reduction = 0.0);
        }
    }

    /// "Learn Noise": the measured noise floor (dBFS) of a quiet stretch. The gate opens 6 dB above it and the denoiser
    /// switches on (at its remembered amount); one undo step.
    pub fn apply_learned_noise_floor(&mut self, floor_db: f64) {
        let threshold = NoiseGateLimits::THRESHOLD_DB;
        let t = (floor_db + 6.0).clamp(*threshold.start(), *threshold.end());
        let amount = if self.clean_voice_memory > 0.0 { self.clean_voice_memory } else { Self::DEFAULT_CLEAN_VOICE };
        self.edit(|m| {
            m.gate.threshold_db = t;
            m.gate.enabled = true;
            if m.noise_reduction <= 0.0 {
                m.noise_reduction = amount;
            }
        });
    }

    /// The EQ head's On switch (off: the band gains are not applied).
    pub fn set_eq_enabled(&mut self, on: bool) {
        self.edit(|m| m.compressor.eq_on = on);
    }

    pub fn set_bypass(&mut self, bypass: bool) {
        self.edit(|m| m.compressor.bypass = bypass);
    }

    pub fn set_crossover(&mut self, index: usize, hz: f64) {
        if index >= self.compressor.crossovers_hz.len() {
            return;
        }
        let v = CrossoverRules::clamp(hz, index, &self.compressor.crossovers_hz);
        self.edit(|m| m.compressor.crossovers_hz[index] = v);
    }

    /// Moves two neighboring crossovers (`lo_index` and the next) together, as one edit: a bell's two edges. Order and
    /// spacing follow `CrossoverRules`; the pair never crosses its outer neighbors.
    pub fn set_crossover_pair(&mut self, lo_index: usize, lo_hz: f64, hi_hz: f64) {
        let hi_index = lo_index + 1;
        let x = &self.compressor.crossovers_hz;
        if hi_index >= x.len() {
            return;
        }
        let ratio = CrossoverRules::MIN_RATIO;
        let lower = if lo_index > 0 { x[lo_index - 1] * ratio } else { CrossoverRules::MIN_HZ };
        let upper = if hi_index + 1 < x.len() { x[hi_index + 1] / ratio } else { CrossoverRules::MAX_HZ };
        let lo = lo_hz.max(lower).min((upper / ratio).max(lower));
        let hi = hi_hz.max(lo * ratio).min(upper.max(lo * ratio));
        self.edit(|m| {
            m.compressor.crossovers_hz[lo_index] = lo;
            m.compressor.crossovers_hz[hi_index] = hi;
        });
    }

    /// Edits one band; all fields are clamped to `BandLimits` afterwards.
    pub fn set_band(&mut self, index: usize, body: impl FnOnce(&mut MultibandBand)) {
        let Some(&band) = self.compressor.bands.get(index) else { return };
        let mut b = band;
        body(&mut b);
        b.threshold_db = clamped(b.threshold_db, BandLimits::THRESHOLD_DB);
        b.ratio = clamped(b.ratio, BandLimits::RATIO);
        b.attack_ms = clamped(b.attack_ms, BandLimits::ATTACK_MS);
        b.release_ms = clamped(b.release_ms, BandLimits::RELEASE_MS);
        b.gain_db = clamped(b.gain_db, BandLimits::GAIN_DB);
        self.edit(|m| m.compressor.bands[index] = b);
    }

    /// Edits every band with the same change as one undo step (the Track tab's single compressor, all bands linked).
    pub fn set_all_bands(&mut self, body: impl Fn(&mut MultibandBand)) {
        self.edit(|m| {
            for i in 0..m.compressor.bands.len() {
                m.set_band(i, &body);
            }
        });
    }

    pub fn set_pre_gain_db(&mut self, db: f64) {
        let v = clamped(db, BandLimits::OVERALL_GAIN_DB);
        self.edit(|m| m.compressor.pre_gain_db = v);
    }

    pub fn set_makeup_gain_db(&mut self, db: f64) {
        let v = clamped(db, BandLimits::OVERALL_GAIN_DB);
        self.edit(|m| m.compressor.makeup_gain_db = v);
    }

    // MARK: Noise gate and warmth

    pub fn set_gate_enabled(&mut self, on: bool) {
        self.edit(|m| m.gate.enabled = on);
    }

    pub fn set_gate_threshold_db(&mut self, db: f64) {
        let v = clamped(db, NoiseGateLimits::THRESHOLD_DB);
        self.edit(|m| m.gate.threshold_db = v);
    }

    pub fn set_gate_attack_ms(&mut self, ms: f64) {
        let v = clamped(ms, NoiseGateLimits::ATTACK_MS);
        self.edit(|m| m.gate.attack_ms = v);
    }

    pub fn set_gate_hold_ms(&mut self, ms: f64) {
        let v = clamped(ms, NoiseGateLimits::HOLD_MS);
        self.edit(|m| m.gate.hold_ms = v);
    }

    pub fn set_gate_release_ms(&mut self, ms: f64) {
        let v = clamped(ms, NoiseGateLimits::RELEASE_MS);
        self.edit(|m| m.gate.release_ms = v);
    }

    pub fn set_warmth_enabled(&mut self, on: bool) {
        self.edit(|m| m.saturation.enabled = on);
    }

    pub fn set_warmth_drive_db(&mut self, db: f64) {
        let v = clamped(db, SaturationLimits::DRIVE_DB);
        self.edit(|m| m.saturation.drive_db = v);
    }

    pub fn set_warmth_mix_percent(&mut self, percent: f64) {
        let v = clamped(percent, 0.0..=100.0).round() / 100.0;
        self.edit(|m| m.saturation.mix = v);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use TrackAudioEvent::*;
    use sq_core_time::SequentialIds;

    fn model() -> TrackAudioInspectorModel {
        TrackAudioInspectorModel::new(PresetLibrary::new(), None, None, Box::new(SequentialIds::default()))
    }

    #[test]
    fn a_picked_preset_replaces_the_chain_and_the_role_chip_lets_go_until_it_is_clicked_again() {
        let mut m = TrackAudioInspectorModel::new(
            PresetLibrary::new(),
            None,
            Some(AudioTag::Dialogue),
            Box::new(SequentialIds::default()),
        );
        assert!(m.role_is_active(AudioTag::Dialogue));
        m.select_preset(&TrackAudioPreset::music().id);
        assert_eq!(m.selected_preset().map(|p| p.name), Some("Music".to_string()));
        assert!(!m.role_is_active(AudioTag::Dialogue), "the chip no longer claims the replaced chain");
        assert_eq!(m.role(), Some(AudioTag::Dialogue));
        m.take_events();
        m.set_role(Some(AudioTag::Dialogue));
        assert!(m.role_is_active(AudioTag::Dialogue), "the voiced preset is back");
        assert!(m.take_events().iter().any(|e| matches!(e, TrackAudioEvent::RoleChange(Some(AudioTag::Dialogue)))));
    }

    #[test]
    fn a_role_change_keeps_typed_eq_values_and_the_saved_preset_reopens_with_them() {
        let mut m = TrackAudioInspectorModel::new(
            PresetLibrary::new(),
            None,
            Some(AudioTag::Dialogue),
            Box::new(SequentialIds::default()),
        );
        m.set_eq_enabled(true);
        m.set_crossover(0, 200.0);
        m.set_band(0, |b| b.gain_db = 6.0);
        m.take_events();
        m.set_role(Some(AudioTag::Music));
        let (hz, db) = (m.compressor().crossovers_hz[0], m.compressor().bands[0].gain_db);
        assert_eq!((hz, db, m.role()), (200.0, 6.0, Some(AudioTag::Music)));
        assert!(!m.role_is_active(AudioTag::Music), "the chip lets go of a chain that is not its own");
        // What the project stores comes back into a fresh model unchanged.
        let saved = serde_json::to_string(&m.current_values()).expect("save");
        let stored: TrackAudioPreset = serde_json::from_str(&saved).expect("open");
        let reopened = TrackAudioInspectorModel::new(
            PresetLibrary::new(),
            Some(stored),
            Some(AudioTag::Music),
            Box::new(SequentialIds::default()),
        );
        assert!(reopened.compressor().eq_on);
        assert_eq!((reopened.compressor().crossovers_hz[0], reopened.compressor().bands[0].gain_db), (200.0, 6.0));
        // The role picked again brings its voiced preset back; an untouched chain follows a new role at once.
        m.set_role(Some(AudioTag::Music));
        assert!(m.role_is_active(AudioTag::Music) && m.compressor().crossovers_hz[0] != 200.0);
        m.set_role(Some(AudioTag::Sfx));
        assert!(m.role_is_active(AudioTag::Sfx));
    }

    #[test]
    fn selects_built_in_preset() {
        let mut m = model();
        m.select_preset(&TrackAudioPreset::voice().id);
        assert_eq!(*m.compressor(), TrackAudioPreset::voice().compressor);
        assert_eq!(m.noise_reduction_percent(), 80.0);
        assert!(!m.is_modified());
        let ids: Vec<String> = m.presets().into_iter().map(|p| p.id).collect();
        assert_eq!(ids, ["builtin.off", "builtin.voice", "builtin.music"]);
    }

    #[test]
    fn noise_reduction_clamps_and_marks_modified() {
        let mut m = model();
        m.select_preset(&TrackAudioPreset::voice().id);
        m.set_noise_reduction_percent(140.0);
        assert_eq!(m.noise_reduction_percent(), 100.0);
        assert!(m.is_modified());
        m.set_noise_reduction_percent(-5.0);
        assert_eq!(m.noise_reduction(), 0.0);
    }

    #[test]
    fn clean_voice_switch_remembers_and_learned_floor_sets_the_gate() {
        let mut m = model();
        assert!(!m.clean_voice_on());
        m.set_clean_voice(true);
        assert_eq!(m.noise_reduction_percent(), 60.0);
        m.set_noise_reduction_percent(30.0);
        m.set_clean_voice(false);
        assert_eq!(m.noise_reduction(), 0.0);
        m.set_clean_voice(true);
        assert_eq!(m.noise_reduction_percent(), 30.0);
        m.set_clean_voice(false);
        m.apply_learned_noise_floor(-50.0);
        assert!(m.gate().enabled);
        assert_eq!(m.gate().threshold_db, -44.0);
        assert!(m.clean_voice_on());
        m.apply_learned_noise_floor(-200.0);
        assert_eq!(m.gate().threshold_db, *NoiseGateLimits::THRESHOLD_DB.start());
    }

    #[test]
    fn crossovers_stay_ordered_and_clamped() {
        let mut m = model();
        m.select_preset(&TrackAudioPreset::music().id); // 150, 1000, 6000
        m.set_crossover(0, 5000.0);
        assert!(m.compressor().crossovers_hz[0] < m.compressor().crossovers_hz[1]);
        assert_eq!(m.compressor().crossovers_hz[1], 1000.0);
        m.set_crossover(2, 10.0);
        assert!(m.compressor().crossovers_hz[2] > m.compressor().crossovers_hz[1]);
        m.set_crossover(1, 1_000_000.0);
        assert!(m.compressor().crossovers_hz[1] < m.compressor().crossovers_hz[2]);
        m.set_crossover(0, 1.0);
        assert_eq!(m.compressor().crossovers_hz[0], CrossoverRules::MIN_HZ);
    }

    #[test]
    fn band_parameters_clamp() {
        let mut m = model();
        m.set_band(1, |b| {
            b.ratio = 99.0;
            b.threshold_db = 10.0;
            b.attack_ms = 0.0;
            b.release_ms = 1e6;
            b.gain_db = -99.0;
        });
        let b = m.compressor().bands[1];
        assert!(b.ratio == 20.0 && b.threshold_db == 0.0 && b.attack_ms == *BandLimits::ATTACK_MS.start());
        assert!(b.release_ms == *BandLimits::RELEASE_MS.end() && b.gain_db == -24.0);
        m.set_pre_gain_db(50.0);
        m.set_makeup_gain_db(-50.0);
        assert!(m.compressor().pre_gain_db == 24.0 && m.compressor().makeup_gain_db == -24.0);
        m.set_bypass(false);
        assert!(!m.compressor().bypass);
    }

    #[test]
    fn user_preset_save_rename_delete() {
        let mut m = model();
        m.select_preset(&TrackAudioPreset::voice().id);
        m.set_noise_reduction_percent(30.0);
        m.save_as_user_preset("Podcast");
        assert_eq!(m.presets().len(), 4);
        let id = m.selected_preset_id().map(str::to_string).unwrap_or_default();
        assert!(id.starts_with("user."));
        assert!(!m.is_modified());
        assert_eq!(m.noise_reduction_percent(), 30.0);
        m.rename_selected_preset("Podcast 2");
        assert_eq!(m.presets().last().map(|p| p.name.as_str()), Some("Podcast 2"));
        m.delete_selected_preset();
        assert_eq!(m.presets().len(), 3);
        assert_eq!(m.selected_preset_id(), None);
        assert_eq!(m.noise_reduction_percent(), 30.0); // values kept
    }

    #[test]
    fn built_ins_cannot_be_renamed_or_deleted() {
        let mut m = model();
        m.select_preset(&TrackAudioPreset::voice().id);
        assert!(!m.can_edit_selected_preset());
        m.rename_selected_preset("X");
        m.delete_selected_preset();
        assert_eq!(m.presets().len(), 3);
        assert_eq!(m.selected_preset_id(), Some(TrackAudioPreset::voice().id.as_str()));
    }

    fn kinds(m: &mut TrackAudioInspectorModel) -> Vec<&'static str> {
        m.take_events()
            .iter()
            .map(|e| match e {
                BeginChange => "begin",
                EndChange => "end",
                Change(_) => "change",
                RoleChange(_) => "role",
                LoudnessChange(_) => "loudness",
            })
            .collect()
    }

    #[test]
    fn discrete_changes_are_bracketed() {
        let mut m = model();
        m.set_bypass(false);
        assert_eq!(kinds(&mut m), ["begin", "change", "end"]);
    }

    #[test]
    fn drag_coalesces_into_one_bracket() {
        let mut m = model();
        m.begin_change();
        m.set_crossover(0, 200.0);
        m.set_crossover(0, 210.0);
        m.set_crossover(0, 220.0);
        m.end_change();
        assert_eq!(kinds(&mut m), ["begin", "change", "change", "change", "end"]);
    }

    #[test]
    fn unchanged_value_does_not_notify() {
        let mut m = model();
        m.set_noise_reduction_percent(m.noise_reduction_percent());
        let n = m.take_events().iter().filter(|e| matches!(e, Change(_))).count();
        assert_eq!(n, 0);
    }

    fn last_change(m: &mut TrackAudioInspectorModel) -> Option<TrackAudioPreset> {
        m.take_events().into_iter().rev().find_map(|e| if let Change(p) = e { Some(*p) } else { None })
    }

    #[test]
    fn gate_times_clamp_and_reach_the_preset() {
        let mut m = model();
        m.set_gate_attack_ms(0.0);
        m.set_gate_hold_ms(99_999.0);
        m.set_gate_release_ms(1.0);
        assert_eq!(m.gate().attack_ms, *NoiseGateLimits::ATTACK_MS.start());
        assert_eq!(m.gate().hold_ms, *NoiseGateLimits::HOLD_MS.end());
        assert_eq!(m.gate().release_ms, *NoiseGateLimits::RELEASE_MS.start());
        m.take_events();
        m.set_gate_attack_ms(5.0);
        m.set_gate_hold_ms(120.0);
        m.set_gate_release_ms(300.0);
        let seen = last_change(&mut m);
        let g = seen.map(|p| p.gate);
        assert!(g.is_some_and(|g| g.attack_ms == 5.0 && g.hold_ms == 120.0 && g.release_ms == 300.0));
    }

    #[test]
    fn gate_and_warmth_edits_clamp_report_and_reach_the_preset() {
        let mut m = model();
        m.set_gate_enabled(true);
        m.set_gate_threshold_db(-200.0);
        assert_eq!(m.gate().threshold_db, *NoiseGateLimits::THRESHOLD_DB.start());
        m.set_warmth_enabled(true);
        m.set_warmth_drive_db(99.0);
        m.set_warmth_mix_percent(50.0);
        assert!(m.saturation().drive_db == 24.0 && m.saturation().mix == 0.5);
        let seen = last_change(&mut m);
        assert!(seen.is_some_and(|p| p.gate.enabled && p.saturation.enabled));
        assert!(m.is_modified());
        m.select_preset(&TrackAudioPreset::off().id);
        assert!(m.gate() == NoiseGateSettings::OFF && m.saturation() == SaturationSettings::OFF && !m.is_modified());
    }
}

#[cfg(test)]
mod stored_tweaks_tests {
    use super::*;
    use sq_core_time::SequentialIds;

    fn model(role: Option<AudioTag>) -> TrackAudioInspectorModel {
        TrackAudioInspectorModel::new(PresetLibrary::default(), None, role, Box::new(SequentialIds::default()))
    }

    #[test]
    fn a_tweak_keeps_the_role_de_esser_and_follows_the_stored_value_silently() {
        let mut m = model(Some(AudioTag::Dialogue));
        m.take_events();
        m.set_eq_enabled(false);
        let changed = m.take_events().into_iter().find_map(|e| match e {
            TrackAudioEvent::Change(p) => Some(p),
            _ => None,
        });
        let p = changed.expect("a change is reported");
        assert!(p.de_ess && !p.compressor.eq_on, "the Voice de-esser survives the tweak");
        // Another view (undo) shows the stored values without a callback; None goes back to the role.
        let mut other = model(Some(AudioTag::Dialogue));
        other.take_events();
        other.sync_preset(Some(&p));
        assert!(!other.compressor().eq_on && other.take_events().is_empty());
        other.sync_preset(None);
        assert!(other.compressor().eq_on && other.take_events().is_empty());
    }
}
