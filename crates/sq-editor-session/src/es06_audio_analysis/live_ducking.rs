// Swift: EditorSession+LiveDucking.swift
//! N8b live ducking in the session: the project's own setting, excluded tracks, baking to keys, and the choice lists of
//! "Live Ducking for This Project...".

use sq_core_audio::ducking::Ducking;
use sq_core_audio::live_ducking::{DefaultsStore, DialogueSilenceProvider, DuckTimingExt, LiveDucking};
use sq_core_model::{Clip, DuckTiming, ProjectLiveDucking, TrackKind};
use sq_core_time::{Id, TimeRange};

use crate::EditorSession;

const PROJECT_LIVE_DUCKING_UNDO_NAME: &str = "Set Project Live Ducking";

impl EditorSession {
    /// N8b: the project's own live ducking (`None` = follow Preferences > Audio), one undo step. Playback, scrub and
    /// export use it.
    // Swift: EditorSession+LiveDucking.swift:9
    pub fn set_project_live_ducking(&mut self, setting: Option<ProjectLiveDucking>) {
        if self.project().live_ducking == setting {
            return;
        }
        self.perform(PROJECT_LIVE_DUCKING_UNDO_NAME, None, |p| p.live_ducking = setting);
    }

    /// N8b: excludes an audio track from live ducking (or takes it back in), one undo step.
    // Swift: EditorSession+LiveDucking.swift:15
    pub fn set_track_excluded_from_live_ducking(&mut self, id: Id, excluded: bool) -> bool {
        let applies = self
            .active_timeline()
            .and_then(|t| t.tracks.iter().find(|tr| tr.id == id))
            .is_some_and(|tr| tr.kind == TrackKind::Audio && tr.is_excluded_from_live_ducking() != excluded);
        if !applies {
            return false;
        }
        let name = if excluded { "Exclude from Live Ducking" } else { "Include in Live Ducking" };
        self.attempt_ids(name, |t, _| {
            if let Some(i) = t.tracks.iter().position(|tr| tr.id == id) {
                t.tracks[i].set_excluded_from_live_ducking(excluded);
            }
            Ok(())
        })
    }

    /// N8b: bakes the live duck curve into volume keys (one undo step). The same path as Clip > Bake Live Duck to Keys,
    /// kept for the Live Ducking dialog: `ducking` default is the project's effective setting; off (`None` or amount 0)
    /// bakes nothing. Returns the number of keys written.
    // Swift: EditorSession+LiveDucking.swift:28
    pub fn bake_live_ducking(
        &mut self,
        ducking: Option<LiveDucking>,
        defaults: &dyn DefaultsStore,
        silences: Option<&dyn DialogueSilenceProvider>,
    ) -> usize {
        let Some(d) = ducking.or_else(|| self.effective_live_ducking(defaults)).filter(|d| !d.is_off()) else {
            return 0;
        };
        let none: &dyn Fn(&Clip) -> Vec<TimeRange> = &|_| Vec::new();
        self.bake_live_duck_to_keys(
            Some(d),
            defaults,
            silences,
            none,
            Ducking::DEFAULT_AMOUNT_DB,
            Ducking::DEFAULT_FADE,
        )
    }

    /// The live ducking the active project plays with now (its own setting, else Preferences).
    // Swift: EditorSession+LiveDucking.swift:35
    pub fn effective_live_ducking(&self, defaults: &dyn DefaultsStore) -> Option<LiveDucking> {
        LiveDucking::resolved(self.project().live_ducking.as_ref(), defaults)
    }
}

/// One row of the "Live Ducking for This Project..." list.
// Swift: EditorSession+LiveDucking.swift:41
#[derive(Clone, Debug, PartialEq)]
pub struct ProjectLiveDuckingChoice {
    // Swift: EditorSession+LiveDucking.swift:42
    pub title: String,
    // Swift: EditorSession+LiveDucking.swift:43
    pub setting: Option<ProjectLiveDucking>,
}

/// N8b: the choices of "Live Ducking for This Project...": follow Preferences, off, or one of the Preferences amounts
/// (plus the stored amount when it is not one of them).
// Swift: EditorSession+LiveDucking.swift:40
pub enum ProjectLiveDuckingChoices {}

impl ProjectLiveDuckingChoices {
    // Swift: EditorSession+LiveDucking.swift:45
    pub fn choices(
        current: Option<&ProjectLiveDucking>,
        preferences: Option<&LiveDucking>,
    ) -> Vec<ProjectLiveDuckingChoice> {
        let pref = preferences.map_or_else(|| "Off".to_string(), |p| format!("{} dB", Self::format(p.amount_db)));
        let mut out = vec![
            ProjectLiveDuckingChoice { title: format!("Use Preferences ({pref})"), setting: None },
            ProjectLiveDuckingChoice {
                title: "Off for This Project".to_string(),
                setting: Some(ProjectLiveDucking { is_on: false, amount_db: Ducking::DEFAULT_AMOUNT_DB, timing: None }),
            },
        ];
        let mut amounts = LiveDucking::AMOUNT_CHOICES.to_vec();
        if let Some(c) = current
            && c.is_on
            && !amounts.contains(&c.amount_db)
        {
            amounts.push(c.amount_db);
            amounts.sort_by(f64::total_cmp);
        }
        for db in amounts {
            out.push(ProjectLiveDuckingChoice {
                title: format!("Duck Music by {} dB", Self::format(db)),
                setting: Some(ProjectLiveDucking { is_on: true, amount_db: db, timing: None }),
            });
        }
        out
    }

    /// Index of `current` in `choices` (an "off" setting matches Off whatever amount it keeps).
    // Swift: EditorSession+LiveDucking.swift:57
    pub fn index(current: Option<&ProjectLiveDucking>, choices: &[ProjectLiveDuckingChoice]) -> usize {
        let Some(current) = current else { return 0 };
        if !current.is_on {
            return 1;
        }
        choices
            .iter()
            .position(|c| c.setting.as_ref().is_some_and(|s| s.is_on && s.amount_db == current.amount_db))
            .unwrap_or(0)
    }

    // Swift: EditorSession+LiveDucking.swift:62
    pub fn format(db: f64) -> String {
        if db == db.round() { format!("{}", db as i64) } else { format!("{db:.1}") }
    }
}

/// One timing preset of the live duck.
// Swift: EditorSession+LiveDucking.swift:68
#[derive(Clone, Debug, PartialEq)]
pub struct DuckTimingPreset {
    // Swift: EditorSession+LiveDucking.swift:69
    pub title: &'static str,
    // Swift: EditorSession+LiveDucking.swift:70
    pub timing: DuckTiming,
}

/// Timing presets of the live duck, shared by Preferences and "Live Ducking for This Project..." (one system, two places).
// Swift: EditorSession+LiveDucking.swift:67
pub enum DuckTimingChoices {}

impl DuckTimingChoices {
    // Swift: EditorSession+LiveDucking.swift:72
    pub fn presets() -> Vec<DuckTimingPreset> {
        vec![
            DuckTimingPreset { title: "Classic (300 ms fades)", timing: DuckTiming::classic() },
            DuckTimingPreset { title: "Ducker (15 / 10 / 150 / 750 ms)", timing: DuckTiming::resolve() },
            DuckTimingPreset { title: "Speech (bridges breaths)", timing: DuckTiming::speech() },
        ]
    }

    /// Shown when the five values match no preset.
    // Swift: EditorSession+LiveDucking.swift:79
    pub const CUSTOM_TITLE: &'static str = "Custom";

    /// Popup titles: the presets, then Custom.
    // Swift: EditorSession+LiveDucking.swift:82
    pub fn titles() -> Vec<&'static str> {
        Self::presets().iter().map(|p| p.title).chain([Self::CUSTOM_TITLE]).collect()
    }

    /// Popup index of `timing`: a preset, or `presets().len()` (Custom).
    // Swift: EditorSession+LiveDucking.swift:85
    pub fn index(timing: &DuckTiming) -> usize {
        let presets = Self::presets();
        let clamped = timing.clamped();
        presets.iter().position(|p| p.timing == clamped).unwrap_or(presets.len())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn choices_list_preferences_off_and_the_amounts() {
        let c = ProjectLiveDuckingChoices::choices(None, None);
        assert_eq!(c[0].title, "Use Preferences (Off)");
        assert_eq!(c[1].title, "Off for This Project");
        assert_eq!(c.len(), 2 + LiveDucking::AMOUNT_CHOICES.len());
        assert_eq!(c[2].title, "Duck Music by 6 dB");
        let with_pref =
            ProjectLiveDuckingChoices::choices(None, Some(&LiveDucking::new(12.0, sq_core_time::Time::new(3, 10))));
        assert_eq!(with_pref[0].title, "Use Preferences (12 dB)");
    }

    #[test]
    fn a_stored_odd_amount_joins_the_list_in_order() {
        let cur = ProjectLiveDucking { is_on: true, amount_db: 10.5, timing: None };
        let c = ProjectLiveDuckingChoices::choices(Some(&cur), None);
        let i = ProjectLiveDuckingChoices::index(Some(&cur), &c);
        assert_eq!(c[i].title, "Duck Music by 10.5 dB");
        assert_eq!(c[i - 1].title, "Duck Music by 9 dB");
    }

    #[test]
    fn index_follows_off_and_none() {
        let c = ProjectLiveDuckingChoices::choices(None, None);
        assert_eq!(ProjectLiveDuckingChoices::index(None, &c), 0);
        let off = ProjectLiveDucking { is_on: false, amount_db: 18.0, timing: None };
        assert_eq!(ProjectLiveDuckingChoices::index(Some(&off), &c), 1);
        assert_eq!(ProjectLiveDuckingChoices::format(9.0), "9");
        assert_eq!(ProjectLiveDuckingChoices::format(7.25), "7.2");
    }

    #[test]
    fn timing_index_finds_presets_and_custom() {
        assert_eq!(DuckTimingChoices::index(&DuckTiming::speech()), 2);
        let mut odd = DuckTiming::classic();
        odd.hold_ms = 123.0;
        assert_eq!(DuckTimingChoices::index(&odd), 3);
        assert_eq!(DuckTimingChoices::titles().last(), Some(&"Custom"));
    }
}
