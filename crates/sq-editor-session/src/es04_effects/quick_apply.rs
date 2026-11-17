//! Quick Apply: the item catalog, ranking, target resolution, the palette model and the session command.

use std::collections::BTreeSet;

use sq_core_effects::effect_preset::ApplyMode;
use sq_core_effects::effect_stack_preset::EffectStackPresets;
use sq_core_effects::transition::TransitionKindExt;
use sq_core_model::{ClipEdge, ClipEffect, TrackKind, TransitionKind};
use sq_core_time::Id;
use sq_library::library_folder_store::SettingsStore;
use sq_library::preset_store::{PresetItem, PresetKind};

use super::effect_support::{EffectDragPayload, transition_kind_raw};
use super::transition_targets::TransitionDefaults;
use super::transitions::TransitionScope;
use sq_uikit::editor_command::EditorCommand;

use crate::{EdgeRef, EdgeSelection, EditorSession};

/// What picking a Quick Apply row does.
// Swift: QuickApplyModel.swift:6
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum QuickApplyAction {
    Effect(String),
    Transition(TransitionKind),
    Preset(Id, PresetKind),
    BuiltInPreset(String),
    Command(EditorCommand),
    SaveStackAsPreset,
    Macro(String),
}

/// One row of the Quick Apply palette.
// Swift: QuickApplyModel.swift:17
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct QuickApplyItem {
    // Swift: QuickApplyModel.swift:19
    pub id: String,
    // Swift: QuickApplyModel.swift:20
    pub title: String,
    // Swift: QuickApplyModel.swift:21
    pub category: String,
    // Swift: QuickApplyModel.swift:22
    pub action: QuickApplyAction,
}

impl QuickApplyItem {
    // Swift: QuickApplyModel.swift:23
    pub fn new(id: &str, title: &str, category: &str, action: QuickApplyAction) -> QuickApplyItem {
        QuickApplyItem { id: id.to_string(), title: title.to_string(), category: category.to_string(), action }
    }
}

/// A named list of palette rows run one after the other.
// Swift: QuickApplyModel.swift:28
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct QuickApplyMacro {
    // Swift: QuickApplyModel.swift:30
    pub id: String,
    // Swift: QuickApplyModel.swift:31
    pub name: String,
    // Swift: QuickApplyModel.swift:32
    pub steps: Vec<String>,
}

impl QuickApplyMacro {
    // Swift: QuickApplyModel.swift:33
    pub fn new(id: &str, name: &str, steps: Vec<String>) -> QuickApplyMacro {
        QuickApplyMacro { id: id.to_string(), name: name.to_string(), steps }
    }
    // Swift: QuickApplyModel.swift:36
    pub fn built_in() -> Vec<QuickApplyMacro> {
        vec![QuickApplyMacro::new(
            "cleanVoice",
            "Clean Voice",
            vec![
                format!("command.{}", EditorCommand::VoiceChain.id()),
                format!("command.{}", EditorCommand::MatchLoudness.id()),
            ],
        )]
    }
}

/// Builds the palette rows.
pub enum QuickApplyCatalog {}

impl QuickApplyCatalog {
    /// Effects, built-in presets, saved presets, commands and macros as palette rows.
    /// `commands` are the supported menu commands in menu order (Swift reads `EditorMenus`).
    // Swift: QuickApplyModel.swift:46
    pub fn items(
        effects: &[(String, String)],
        built_in_presets: &[(String, String)],
        presets: &[PresetItem],
        commands: &[EditorCommand],
    ) -> Vec<QuickApplyItem> {
        let mut out: Vec<QuickApplyItem> = Vec::new();
        let mut titles: BTreeSet<String> = BTreeSet::new();
        // A title is listed once, except presets (their names may repeat an effect's).
        fn push(out: &mut Vec<QuickApplyItem>, titles: &mut BTreeSet<String>, item: QuickApplyItem) {
            let fresh = titles.insert(item.title.to_lowercase());
            if fresh || item.category == "Preset" || item.category == "Transition Preset" {
                out.push(item);
            }
        }
        for (id, title) in effects {
            if let Some(k) = EffectDragPayload::transition_kind(id) {
                let category = if k.track_kind() == TrackKind::Video { "Video Transition" } else { "Audio Transition" };
                push(
                    &mut out,
                    &mut titles,
                    QuickApplyItem::new(
                        &format!("transition.{}", transition_kind_raw(k)),
                        title,
                        category,
                        QuickApplyAction::Transition(k),
                    ),
                );
            } else {
                let category = if ClipEffect::is_audio_kind(id) { "Audio Effect" } else { "Effect" };
                push(
                    &mut out,
                    &mut titles,
                    QuickApplyItem::new(&format!("effect.{id}"), title, category, QuickApplyAction::Effect(id.clone())),
                );
            }
        }
        for (id, title) in built_in_presets {
            let bare = id.strip_prefix(EffectStackPresets::ROW_PREFIX).unwrap_or(id);
            push(
                &mut out,
                &mut titles,
                QuickApplyItem::new(id, title, "Preset", QuickApplyAction::BuiltInPreset(bare.to_string())),
            );
        }
        for p in presets {
            let category = if p.kind == PresetKind::Transition { "Transition Preset" } else { "Preset" };
            push(
                &mut out,
                &mut titles,
                QuickApplyItem::new(
                    &format!("preset.{}", p.id),
                    &p.name,
                    category,
                    QuickApplyAction::Preset(p.id, p.kind),
                ),
            );
        }
        for c in commands.iter().filter(|c| **c != EditorCommand::QuickApply) {
            push(
                &mut out,
                &mut titles,
                QuickApplyItem::new(
                    &format!("command.{}", c.id()),
                    &c.title(),
                    "Command",
                    QuickApplyAction::Command(*c),
                ),
            );
        }
        for m in QuickApplyMacro::built_in() {
            if m.steps.iter().all(|s| out.iter().any(|i| &i.id == s)) {
                push(
                    &mut out,
                    &mut titles,
                    QuickApplyItem::new(
                        &format!("macro.{}", m.id),
                        &m.name,
                        "Macro",
                        QuickApplyAction::Macro(m.id.clone()),
                    ),
                );
            }
        }
        push(
            &mut out,
            &mut titles,
            QuickApplyItem::new(
                "macro.saveStackAsPreset",
                "Save Effect Stack as Preset\u{2026}",
                "Command",
                QuickApplyAction::SaveStackAsPreset,
            ),
        );
        out
    }
}

/// Fuzzy ranking of palette rows.
pub enum QuickApplyRanking {}

impl QuickApplyRanking {
    // Swift: QuickApplyModel.swift:86
    pub fn score(query: &str, title: &str) -> Option<i64> {
        let q: Vec<char> = query.to_lowercase().chars().filter(|c| !c.is_whitespace()).collect();
        let t: Vec<char> = title.to_lowercase().chars().collect();
        if q.is_empty() {
            return Some(0);
        }
        let (mut score, mut ti, mut last) = (0i64, 0usize, -1i64);
        for qc in q {
            let hit = t.get(ti..)?.iter().position(|c| *c == qc)? + ti;
            let word_start = hit == 0 || !(t[hit - 1].is_alphabetic() || t[hit - 1].is_numeric());
            if hit == 0 {
                score += 15;
            }
            if word_start {
                score += 10;
            }
            if hit as i64 == last + 1 {
                score += 5;
            } else if last >= 0 {
                score -= hit as i64 - last - 1;
            }
            last = hit as i64;
            ti = hit + 1;
        }
        Some(score)
    }
    // Swift: QuickApplyModel.swift:102
    pub fn rank(items: &[QuickApplyItem], query: &str, recents: &[String], limit: usize) -> Vec<QuickApplyItem> {
        const RECENT_BONUS: i64 = 6;
        let q = query.trim();
        let recent_index = |id: &str| recents.iter().position(|r| r == id);
        if q.is_empty() {
            let head = recents.iter().filter_map(|r| items.iter().find(|i| &i.id == r));
            let rest = items.iter().filter(|i| recent_index(&i.id).is_none());
            return head.chain(rest).take(limit).cloned().collect();
        }
        let mut scored: Vec<(usize, i64, &QuickApplyItem)> = items
            .iter()
            .enumerate()
            .filter_map(|(i, item)| {
                let s = Self::score(q, &item.title)?;
                Some((i, s + if recent_index(&item.id).is_some() { RECENT_BONUS } else { 0 }, item))
            })
            .collect();
        scored.sort_by(|a, b| {
            b.1.cmp(&a.1)
                .then_with(|| {
                    recent_index(&a.2.id).unwrap_or(usize::MAX).cmp(&recent_index(&b.2.id).unwrap_or(usize::MAX))
                })
                .then_with(|| a.2.title.chars().count().cmp(&b.2.title.chars().count()))
                .then_with(|| a.0.cmp(&b.0))
        });
        scored.into_iter().take(limit).map(|(_, _, item)| item.clone()).collect()
    }
}

/// Which transition end(s) a Quick Apply transition goes on.
// Swift: QuickApplyModel.swift:172
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TransitionEnd {
    Start,
    End,
    Both,
}

/// What a row resolves to for the current selection.
// Swift: QuickApplyModel.swift:131
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum QuickApplyResolution {
    Effect { kind: String, clips: BTreeSet<Id> },
    Transition(TransitionKind),
    Preset(Id, PresetKind),
    BuiltInPreset(String),
    Command(EditorCommand),
    SaveStackAsPreset,
    Macro(QuickApplyMacro),
    Refused(String),
}

/// Resolves rows against the selection.
pub enum QuickApplyTarget {}

impl QuickApplyTarget {
    // Swift: QuickApplyModel.swift:142
    pub fn edges(clips: &BTreeSet<Id>, end: TransitionEnd) -> EdgeSelection {
        let sides: &[ClipEdge] = match end {
            TransitionEnd::Start => &[ClipEdge::Head],
            TransitionEnd::End => &[ClipEdge::Tail],
            TransitionEnd::Both => &[ClipEdge::Head, ClipEdge::Tail],
        };
        // Sorted by the uppercase uuid string, as the Swift version does.
        let mut sorted: Vec<Id> = clips.iter().copied().collect();
        sorted.sort_by_key(|c| c.to_string().to_uppercase());
        EdgeSelection {
            ripple: false,
            linked: true,
            edges: sorted.into_iter().flat_map(|c| sides.iter().map(move |e| EdgeRef { clip: c, edge: *e })).collect(),
        }
    }
    // Swift: QuickApplyModel.swift:152
    pub fn resolve(
        item: &QuickApplyItem,
        selected_video_clips: &BTreeSet<Id>,
        audio_targets: &BTreeSet<Id>,
    ) -> QuickApplyResolution {
        match &item.action {
            QuickApplyAction::Effect(kind) if ClipEffect::is_audio_kind(kind) => {
                if audio_targets.is_empty() {
                    QuickApplyResolution::Refused(format!("Select an audio clip to apply {}.", item.title))
                } else {
                    QuickApplyResolution::Effect { kind: kind.clone(), clips: audio_targets.clone() }
                }
            }
            QuickApplyAction::Effect(kind) => {
                if selected_video_clips.is_empty() {
                    QuickApplyResolution::Refused(format!("Select a video clip to apply {}.", item.title))
                } else {
                    QuickApplyResolution::Effect { kind: kind.clone(), clips: selected_video_clips.clone() }
                }
            }
            QuickApplyAction::Transition(k) => QuickApplyResolution::Transition(*k),
            QuickApplyAction::Preset(id, kind) => QuickApplyResolution::Preset(*id, *kind),
            QuickApplyAction::BuiltInPreset(id) => QuickApplyResolution::BuiltInPreset(id.clone()),
            QuickApplyAction::Command(c) => QuickApplyResolution::Command(*c),
            QuickApplyAction::Macro(id) => QuickApplyMacro::built_in().into_iter().find(|m| &m.id == id).map_or_else(
                || QuickApplyResolution::Refused("This macro no longer exists.".to_string()),
                QuickApplyResolution::Macro,
            ),
            QuickApplyAction::SaveStackAsPreset => {
                if selected_video_clips.len() == 1 {
                    QuickApplyResolution::SaveStackAsPreset
                } else {
                    QuickApplyResolution::Refused("Select one video clip to save its effects as a preset.".to_string())
                }
            }
        }
    }
}

/// What the palette does after the command ran.
// Swift: EditorSession+QuickApply.swift:6
#[derive(Clone, Debug, PartialEq)]
pub enum QuickApplyOutcome {
    Status { text: Option<String>, seconds: f64 },
    Command(EditorCommand),
    SaveStackAsPreset,
    Macro(QuickApplyMacro),
}

/// The result of `QuickApplyModel::confirm`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum QuickApplyModelOutcome {
    None,
    Apply { item: QuickApplyItem, end: Option<TransitionEnd> },
    AskEnd(QuickApplyItem),
}

/// The palette's state: query, ranked results, selection and recents (Swift `QuickApplyModel`).
pub struct QuickApplyModel {
    pub(crate) items: Vec<QuickApplyItem>,
    pub(crate) recents: Vec<String>,
    pub(crate) results: Vec<QuickApplyItem>,
    pub(crate) selected_index: usize,
    pub(crate) query: String,
    pub(crate) pending_transition: Option<QuickApplyItem>,
    pub(crate) transition_end: TransitionEnd,
    pub(crate) defaults: Box<dyn SettingsStore>,
    pub(crate) version: u64,
}

impl QuickApplyModel {
    // Swift: QuickApplyModel.swift:176
    pub const MAX_RECENTS: usize = 8;
    // Swift: QuickApplyModel.swift:177
    pub const RECENTS_KEY: &'static str = "sq.palette.recents";

    const LEGACY_RECENTS_KEY: &'static str = "sq.quickApply.recents";
    const LAST_QUERY_KEY: &'static str = "sq.quickApply.lastQuery";
    const RESULT_LIMIT: usize = 40;

    fn store_recents(d: &mut dyn SettingsStore, recents: &[String]) {
        if let Ok(bytes) = serde_json::to_vec(recents) {
            d.set_data(Self::RECENTS_KEY, bytes);
        }
    }

    /// Ranks again, selects the first row and tells the view.
    fn refresh(&mut self) {
        self.results = QuickApplyRanking::rank(&self.items, &self.query, &self.recents, Self::RESULT_LIMIT);
        self.selected_index = 0;
        self.version += 1;
    }

    // Swift: QuickApplyModel.swift:192
    pub fn new(items: Vec<QuickApplyItem>, defaults: Box<dyn SettingsStore>) -> QuickApplyModel {
        let read = |d: &dyn SettingsStore, key: &str| -> Option<Vec<String>> {
            serde_json::from_slice::<Vec<String>>(&d.data(key)?).ok()
        };
        let mut defaults = defaults;
        let recents = if let Some(r) = read(defaults.as_ref(), Self::RECENTS_KEY) {
            r.into_iter().take(Self::MAX_RECENTS).collect()
        } else if let Some(old) = read(defaults.as_ref(), Self::LEGACY_RECENTS_KEY) {
            let r: Vec<String> = old.into_iter().take(Self::MAX_RECENTS).collect();
            Self::store_recents(defaults.as_mut(), &r);
            r
        } else {
            Vec::new()
        };
        let mut m = QuickApplyModel {
            items,
            recents,
            results: Vec::new(),
            selected_index: 0,
            query: String::new(),
            pending_transition: None,
            transition_end: TransitionEnd::Both,
            defaults,
            version: 0,
        };
        m.refresh();
        m
    }
    /// Bumped by every change the view reads.
    // Swift: QuickApplyModel.swift:190 (`onChange`)
    pub fn version(&self) -> u64 {
        self.version
    }
    pub fn items(&self) -> &[QuickApplyItem] {
        &self.items
    }
    pub fn recents(&self) -> &[String] {
        &self.recents
    }
    pub fn results(&self) -> &[QuickApplyItem] {
        &self.results
    }
    pub fn selected_index(&self) -> usize {
        self.selected_index
    }
    pub fn pending_transition(&self) -> Option<&QuickApplyItem> {
        self.pending_transition.as_ref()
    }
    pub fn transition_end(&self) -> TransitionEnd {
        self.transition_end
    }
    // Swift: QuickApplyModel.swift:186
    pub fn query(&self) -> &str {
        &self.query
    }
    /// Sets the query: remembers it and ranks again (Swift `query.didSet`).
    pub fn set_query(&mut self, q: &str) {
        self.query = q.to_string();
        self.defaults.set_data(Self::LAST_QUERY_KEY, q.as_bytes().to_vec());
        self.refresh();
    }
    // Swift: QuickApplyModel.swift:204
    pub fn selected(&self) -> Option<&QuickApplyItem> {
        self.results.get(self.selected_index)
    }
    // Swift: QuickApplyModel.swift:208
    pub fn is_recent_row(&self, item: &QuickApplyItem) -> bool {
        self.query.trim().is_empty() && self.recents.contains(&item.id)
    }
    // Swift: QuickApplyModel.swift:211
    pub fn set_items(&mut self, new: Vec<QuickApplyItem>) {
        self.items = new;
        self.refresh();
    }
    // Swift: QuickApplyModel.swift:213
    pub fn reset(&mut self) {
        self.set_query("");
        self.refresh();
    }
    // Swift: QuickApplyModel.swift:217
    pub fn reopen(&mut self) {
        self.pending_transition = None;
        self.transition_end = TransitionEnd::Both;
        let last = self.defaults.data(Self::LAST_QUERY_KEY).and_then(|b| String::from_utf8(b).ok()).unwrap_or_default();
        self.set_query(&last);
    }
    // Swift: QuickApplyModel.swift:232
    pub fn confirm(&mut self, can_choose_end: bool) -> QuickApplyModelOutcome {
        if let Some(item) = self.pending_transition.take() {
            let end = self.transition_end;
            return match self.commit() {
                Some(_) => QuickApplyModelOutcome::Apply { item, end: Some(end) },
                None => QuickApplyModelOutcome::None,
            };
        }
        let Some(item) = self.selected().cloned() else { return QuickApplyModelOutcome::None };
        if can_choose_end && matches!(item.action, QuickApplyAction::Transition(_)) {
            self.pending_transition = Some(item.clone());
            self.transition_end = TransitionEnd::Both;
            self.version += 1;
            return QuickApplyModelOutcome::AskEnd(item);
        }
        match self.commit() {
            Some(chosen) => QuickApplyModelOutcome::Apply { item: chosen, end: None },
            None => QuickApplyModelOutcome::None,
        }
    }
    // Swift: QuickApplyModel.swift:251
    pub fn choose_end(&mut self, end: TransitionEnd) {
        if self.pending_transition.is_none() {
            return;
        }
        self.transition_end = end;
        self.version += 1;
    }
    // Swift: QuickApplyModel.swift:256
    pub fn cancel_end_choice(&mut self) {
        if self.pending_transition.take().is_some() {
            self.version += 1;
        }
    }
    // Swift: QuickApplyModel.swift:262
    pub fn move_selection(&mut self, delta: i64) {
        if self.results.is_empty() {
            return;
        }
        let last = self.results.len() as i64 - 1;
        self.selected_index = (self.selected_index as i64 + delta).clamp(0, last) as usize;
        self.version += 1;
    }
    // Swift: QuickApplyModel.swift:268
    pub fn select(&mut self, index: usize) {
        if index < self.results.len() {
            self.selected_index = index;
            self.version += 1;
        }
    }
    // Swift: QuickApplyModel.swift:276
    pub fn commit(&mut self) -> Option<QuickApplyItem> {
        let item = self.selected()?.clone();
        self.recents = Self::push_recent(&item.id, &self.recents);
        Self::store_recents(self.defaults.as_mut(), &self.recents);
        Some(item)
    }
    // Swift: QuickApplyModel.swift:282
    pub fn push_recent(id: &str, list: &[String]) -> Vec<String> {
        std::iter::once(id.to_string())
            .chain(list.iter().filter(|r| r.as_str() != id).cloned())
            .take(Self::MAX_RECENTS)
            .collect()
    }
}

impl EditorSession {
    // Swift: EditorSession+QuickApply.swift:21
    pub fn quick_apply_transition_clips(&self, item: Option<&QuickApplyItem>) -> BTreeSet<Id> {
        let Some(QuickApplyAction::Transition(kind)) = item.map(|i| &i.action) else { return BTreeSet::new() };
        self.command_clips_for_menu(Some(kind.track_kind()))
            .iter()
            .map(|c| c.id)
            .filter(|id| self.selection.contains(id))
            .collect()
    }
    // Swift: EditorSession+QuickApply.swift:28
    pub fn apply_quick_apply(
        &mut self,
        item: &QuickApplyItem,
        end: Option<TransitionEnd>,
        presets: &[PresetItem],
        timeline_edges: Option<&EdgeSelection>,
        apply_mode: ApplyMode,
        transition_defaults: &TransitionDefaults,
    ) -> QuickApplyOutcome {
        self.flush_follow_selection();
        let selected = |s: &EditorSession, k: TrackKind| -> BTreeSet<Id> {
            s.command_clips_for_menu(Some(k)).iter().map(|c| c.id).filter(|id| s.selection.contains(id)).collect()
        };
        let video_ids = selected(self, TrackKind::Video);
        let audio_picked: BTreeSet<Id> = video_ids.iter().copied().chain(selected(self, TrackKind::Audio)).collect();
        let audio_targets = self.audio_effect_targets(&audio_picked);
        let failure = |s: &EditorSession| QuickApplyOutcome::Status {
            text: s.last_error().filter(|e| !e.is_empty()).map(str::to_string),
            seconds: 4.0,
        };
        let applied = |name: &str| QuickApplyOutcome::Status { text: Some(format!("{name} applied.")), seconds: 2.0 };
        match QuickApplyTarget::resolve(item, &video_ids, &audio_targets) {
            QuickApplyResolution::Effect { kind, clips } => {
                self.add_effect(&kind, &clips);
                failure(self)
            }
            QuickApplyResolution::Transition(kind) => {
                self.stop_playback();
                let clips = self.quick_apply_transition_clips(Some(item));
                let edges = end.map(|e| QuickApplyTarget::edges(&clips, e));
                let edges = edges.as_ref().or(timeline_edges);
                let scope =
                    if kind.track_kind() == TrackKind::Video { TransitionScope::Video } else { TransitionScope::Audio };
                let n = self.apply_default_transitions(scope, edges, Some(kind), transition_defaults);
                if n > 0 {
                    applied(kind.name())
                } else {
                    QuickApplyOutcome::Status { text: self.last_error().map(str::to_string), seconds: 4.0 }
                }
            }
            QuickApplyResolution::Preset(id, kind) => {
                let Some(preset) = presets.iter().find(|p| p.id == id) else {
                    return QuickApplyOutcome::Status { text: None, seconds: 0.0 };
                };
                self.stop_playback();
                let ok = if kind == PresetKind::Transition {
                    self.apply_transition_preset(preset, timeline_edges)
                } else {
                    self.apply_preset(preset, None, apply_mode)
                };
                if ok { applied(&preset.name) } else { failure(self) }
            }
            QuickApplyResolution::BuiltInPreset(id) => {
                self.stop_playback();
                if self.apply_stack_preset(&id, None) { applied(&item.title) } else { failure(self) }
            }
            QuickApplyResolution::Command(c) => QuickApplyOutcome::Command(c),
            QuickApplyResolution::SaveStackAsPreset => QuickApplyOutcome::SaveStackAsPreset,
            QuickApplyResolution::Macro(m) => QuickApplyOutcome::Macro(m),
            QuickApplyResolution::Refused(message) => QuickApplyOutcome::Status { text: Some(message), seconds: 3.0 },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_time::Timestamp;
    use sq_library::library_folder_store::MemorySettings;

    fn items() -> Vec<QuickApplyItem> {
        let effects = vec![
            (ClipEffect::GAUSSIAN_BLUR_KIND.to_string(), "Gaussian Blur".to_string()),
            (EffectDragPayload::transition_id(TransitionKind::CrossDissolve), "Cross Dissolve".to_string()),
        ];
        let preset = PresetItem::new(
            Id::from_u128(1),
            PresetKind::Effect,
            "Soft Glow",
            Timestamp::from_reference_seconds(0.0),
            Vec::new(),
            1,
        );
        QuickApplyCatalog::items(&effects, &[], &[preset], &[EditorCommand::VideoFadeIn, EditorCommand::QuickApply])
    }

    #[test]
    fn catalog_lists_effects_transitions_presets_and_commands_with_unique_ids() {
        let all = items();
        assert!(all.iter().any(|i| i.action == QuickApplyAction::Effect(ClipEffect::GAUSSIAN_BLUR_KIND.to_string())));
        assert!(all.iter().any(|i| i.title == "Soft Glow"));
        assert!(all.iter().any(|i| i.category.ends_with("Transition")));
        assert!(all.iter().any(|i| i.category == "Command"));
        assert!(!all.iter().any(|i| i.action == QuickApplyAction::Command(EditorCommand::QuickApply)));
        let ids: BTreeSet<&String> = all.iter().map(|i| &i.id).collect();
        assert_eq!(ids.len(), all.len());
    }

    #[test]
    fn fuzzy_search_finds_and_ranks_prefix_first() {
        let r = QuickApplyRanking::rank(&items(), "gblur", &[], 5);
        assert_eq!(r.first().map(|i| i.title.as_str()), Some("Gaussian Blur"));
        assert_eq!(QuickApplyRanking::score("zz", "Gaussian Blur"), None);
        assert_eq!(QuickApplyRanking::score("  ", "x"), Some(0));
    }

    #[test]
    fn return_on_a_transition_asks_start_or_end_when_clips_are_selected() {
        let mut m = QuickApplyModel::new(items(), Box::new(MemorySettings::default()));
        m.set_query("cross");
        let selected = m.selected().cloned();
        assert_eq!(m.confirm(true), QuickApplyModelOutcome::AskEnd(selected.unwrap_or_else(|| panic!("no row"))));
        m.choose_end(TransitionEnd::End);
        let QuickApplyModelOutcome::Apply { item, end } = m.confirm(true) else { panic!("no apply") };
        assert_eq!(end, Some(TransitionEnd::End));
        assert_eq!(item.action, QuickApplyAction::Transition(TransitionKind::CrossDissolve));
        assert_eq!(m.recents().first(), Some(&item.id));
    }

    #[test]
    fn recents_stay_eight_and_come_first_on_an_empty_query() {
        let mut m = QuickApplyModel::new(items(), Box::new(MemorySettings::default()));
        m.set_query("soft");
        assert!(m.commit().is_some());
        m.set_query("");
        assert_eq!(m.results().first().map(|i| i.title.as_str()), Some("Soft Glow"));
        assert!(m.is_recent_row(&m.results()[0].clone()));
        let long: Vec<String> = (0..10).map(|i| i.to_string()).collect();
        assert_eq!(QuickApplyModel::push_recent("x", &long).len(), QuickApplyModel::MAX_RECENTS);
        assert_eq!(QuickApplyModel::push_recent("3", &long)[0], "3");
    }

    #[test]
    fn effect_needs_a_video_clip_selection() {
        let blur = items()
            .into_iter()
            .find(|i| i.action == QuickApplyAction::Effect(ClipEffect::GAUSSIAN_BLUR_KIND.to_string()));
        let blur = blur.unwrap_or_else(|| panic!("no blur row"));
        let none = BTreeSet::new();
        assert!(matches!(QuickApplyTarget::resolve(&blur, &none, &none), QuickApplyResolution::Refused(_)));
        let one = BTreeSet::from([Id::from_u128(9)]);
        assert_eq!(
            QuickApplyTarget::resolve(&blur, &one, &none),
            QuickApplyResolution::Effect { kind: ClipEffect::GAUSSIAN_BLUR_KIND.to_string(), clips: one }
        );
    }
}
