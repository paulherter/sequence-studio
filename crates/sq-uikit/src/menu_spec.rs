// Swift: MenuSpec.swift
//! Menu structure. Key equivalents come from `CommandMap::binding_for`. Names and order follow Premiere Pro: File, Edit,
//! Clip, Sequence, Markers, View, Window (Help and the app menu are built by the app). Only commands that exist are
//! listed; the app hides the ones that are not wired yet.

use crate::editor_command::{
    DisplayViewChoice, EditorCommand, EditorCommand as C, EditorTool, ThumbnailModeChoice, ViewGammaChoice,
};
use crate::panel_id::PanelID;
use sq_core_edit::timeline_replace_modes::ReplaceMode;
use sq_core_effects::speed_ramp_preset::SpeedRampPreset;
use sq_core_graphics::split_layout::SplitLayoutPreset;
use sq_core_model::TrackKind;
use std::collections::HashSet;
use std::sync::OnceLock;

/// One entry of a menu.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Item {
    Command(EditorCommand),
    Separator,
    Submenu(String, Vec<Item>),
}

/// A menu: its title and items.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MenuSpec {
    pub title: String,
    pub items: Vec<Item>,
}

impl MenuSpec {
    /// Every command in the menu, submenus included.
    pub fn commands(&self) -> Vec<EditorCommand> {
        Self::flatten(&self.items)
    }

    fn flatten(items: &[Item]) -> Vec<EditorCommand> {
        items
            .iter()
            .flat_map(|item| match item {
                Item::Command(c) => vec![*c],
                Item::Separator => Vec::new(),
                Item::Submenu(_, sub) => Self::flatten(sub),
            })
            .collect()
    }
}

/// Concatenates lists (Swift `a + b`).
fn cat<T>(parts: Vec<Vec<T>>) -> Vec<T> {
    parts.into_iter().flatten().collect()
}

/// A menu section: a command, or a separator for `None`.
fn cmds(c: Vec<Option<EditorCommand>>) -> Vec<Item> {
    c.into_iter().map(|c| c.map_or(Item::Separator, Item::Command)).collect()
}

/// Title of the File submenu the app fills (Open Recent sits next to it).
pub const PROJECT_SUBMENU_TITLE: &str = "Project";

/// The menus of the app, as data.
pub enum EditorMenus {}

impl EditorMenus {
    /// The complete command catalog by menu area: the audit, the key ownership checks and Quick Apply (the command palette) read
    /// it. It is NOT what the menu bar shows: `visible` is (one entry per action, no scrolling).
    pub fn all() -> &'static [MenuSpec] {
        static ALL: OnceLock<Vec<MenuSpec>> = OnceLock::new();
        ALL.get_or_init(|| {
            vec![
                Self::file(),
                Self::edit(),
                Self::clip(),
                Self::sequence(),
                Self::markers(),
                Self::view(),
                Self::window(),
            ]
        })
    }

    /// What the menu bar builds, in order. Every command here is in `all`; the others stay reachable through their key,
    /// Quick Apply (Window > Quick Apply) and, for the import and export variants, the Import and Export dialogs.
    pub fn visible() -> &'static [MenuSpec] {
        static VISIBLE: OnceLock<Vec<MenuSpec>> = OnceLock::new();
        VISIBLE.get_or_init(|| {
            vec![
                visible_file(),
                visible_edit(),
                visible_clip(),
                visible_sequence(),
                visible_markers(),
                visible_view(),
                visible_window(),
            ]
        })
    }

    /// File. The app inserts "Open Recent" after Open Project.
    #[rustfmt::skip]
    pub fn file() -> MenuSpec {
        MenuSpec { title: "File".to_string(), items: cmds(vec![Some(C::NewProject), Some(C::NewSequence), Some(C::NewBin), None, Some(C::OpenProject), None, Some(C::Save), Some(C::SaveAs), Some(C::SaveCopy), Some(C::Revert), None, Some(C::CloseProject), None, Some(C::ProjectNotes), None, Some(C::ImportMedia), Some(C::ImportProject), Some(C::ImportTimeline), Some(C::ImportPremiereProject), Some(C::ImportPremierePresets), Some(C::ImportMotionGraphicsTemplate), Some(C::ImportLottie), None, Some(C::Export), Some(C::QuickExport), Some(C::ExportFrame), Some(C::ExportMarkersCSV), Some(C::ExportEDL), Some(C::ExportFCPXML), Some(C::ExportFinalCutXML), Some(C::ExportOpenTimelineIO)]) }
    }

    /// Edit.
    #[rustfmt::skip]
    pub fn edit() -> MenuSpec {
        MenuSpec { title: "Edit".to_string(), items: cmds(vec![Some(C::Undo), Some(C::Redo), None, Some(C::Cut), Some(C::Copy), Some(C::Paste), Some(C::PasteInsert), Some(C::PasteToTargets), Some(C::PasteAttached), Some(C::PasteAttributes), None, Some(C::Duplicate), None, Some(C::SelectAll), Some(C::DeselectAll), Some(C::SelectClipAtPlayhead), Some(C::SelectNextClip), Some(C::SelectPreviousClip), Some(C::SelectLeftEdge), Some(C::SelectRightEdge), Some(C::SelectLayerAbove), Some(C::SelectLayerBelow), None, Some(C::Delete), Some(C::RippleDelete), None, Some(C::Find)]) }
    }

    /// Clip.
    #[rustfmt::skip]
    pub fn clip() -> MenuSpec {
        MenuSpec { title: "Clip".to_string(), items: cat(vec![cmds(vec![Some(C::Insert), Some(C::Overwrite), Some(C::FitToFill), Some(C::ReplaceClipFromSource), Some(C::ReplaceClipFromProject), None, Some(C::SetPosterFrame), Some(C::ClearPosterFrame), None, Some(C::SpeedDuration), Some(C::ReverseClip), Some(C::ToggleTimeRemapping), Some(C::AddSpeedPoint), Some(C::RemoveTimeRemapping), None, Some(C::EnableClip), Some(C::Link), Some(C::Unlink), Some(C::DetachAudio), Some(C::SyncAudioToReference), Some(C::Solo), Some(C::MuteTracks), Some(C::TrimToRange), None, Some(C::Group), Some(C::Ungroup), Some(C::Bundle), Some(C::Unbundle), None, Some(C::ExtendToSequenceEnd), Some(C::SaveAsTemplate), Some(C::ToggleAnimationZones), None, Some(C::MakeSubclip), Some(C::EditOriginal), None, Some(C::SetToFrameSize), Some(C::SetToFillFrame), None]), vec![Item::Submenu("Replace Modes".to_string(), cmds(ReplaceMode::ALL.iter().map(|x| Some(C::ReplaceMode(*x))).collect::<Vec<_>>())), Item::Submenu("Audio Options".to_string(), cmds(vec![Some(C::AudioGain), Some(C::AudioGainDown), Some(C::AudioGainUp), Some(C::AudioGainDown6), Some(C::AudioGainUp6), None, Some(C::MatchLoudness), Some(C::AutoDuck), Some(C::ProjectLiveDucking), None, Some(C::RemoveSilences), Some(C::RemoveFillerWords), None, Some(C::ReviewProposedCuts), Some(C::AcceptProposedCuts), Some(C::RejectProposedCuts), Some(C::AcceptProposedCutAtPlayhead), Some(C::RejectProposedCutAtPlayhead), None, Some(C::Voiceover), Some(C::RecordVoiceOver), Some(C::VoiceChain), Some(C::DisguiseVoice), Some(C::TagDialogue), Some(C::TagMusic), Some(C::TagSFX)])), Item::Submenu("Video Options".to_string(), cmds(vec![Some(C::AddFrameHold), Some(C::InsertFrameHold), None, Some(C::VideoFadeIn), Some(C::VideoFadeOut), None, Some(C::FitBlurredFill), Some(C::FitCard), Some(C::RemoveBlurredFill), None, Some(C::TogglePunchIn), None, Some(C::AutoReframe), Some(C::DynamicZoomIn), Some(C::DynamicZoomOut), Some(C::EditDynamicZoom), Some(C::Stabilize), Some(C::MatchColorToClip), Some(C::AddSubjectMask), Some(C::Anonymize), None, Some(C::FindSceneChanges)])), Item::Submenu("Speed Ramp Presets".to_string(), cmds(cat(vec![SpeedRampPreset::ALL.iter().map(|x| Some(C::SpeedRampPreset(*x, false))).collect::<Vec<_>>(), vec![None], SpeedRampPreset::ALL.iter().map(|x| Some(C::SpeedRampPreset(*x, true))).collect::<Vec<_>>()]))), Item::Submenu("Beat Edits".to_string(), cmds(vec![Some(C::CutToBeats), Some(C::SnapToBeats), None, Some(C::FitMusicToLength)])), Item::Submenu("Angles".to_string(), cmds(cat(vec![vec![Some(C::CreateAnglesClip), None], (1..=9).map(|n| Some(C::SwitchAngle(n))).collect::<Vec<_>>()]))), Item::Submenu("Split Screen".to_string(), cmds(cat(vec![SplitLayoutPreset::ALL.iter().map(|x| Some(C::SplitScreen(*x, false))).collect::<Vec<_>>(), vec![None], SplitLayoutPreset::ALL.iter().map(|x| Some(C::SplitScreen(*x, true))).collect::<Vec<_>>()]))), Item::Separator], cmds(vec![Some(C::EaseLinear), Some(C::EasyEase), Some(C::EaseIn), Some(C::EaseOut), Some(C::ToggleHoldInterpolation)])]) }
    }

    /// Sequence.
    #[rustfmt::skip]
    pub fn sequence() -> MenuSpec {
        MenuSpec { title: "Sequence".to_string(), items: cat(vec![cmds(vec![Some(C::SequenceSettings), None, Some(C::Lift), Some(C::Extract), Some(C::Bleep), None, Some(C::NewTone), Some(C::ToneSettings), None, Some(C::AddEdit), Some(C::AddEditAllTracks), Some(C::JoinCuts), Some(C::JumpCutAlternate), Some(C::SplitEditAudio), Some(C::SplitEditVideo), Some(C::CutOut), Some(C::PlaceOnTop), Some(C::AttachBacktimed), Some(C::CloseGapAtPlayhead), Some(C::JCut), Some(C::LCut), Some(C::JCutByOffset), Some(C::LCutByOffset), Some(C::NudgeAudioEditLeft), Some(C::NudgeAudioEditRight), Some(C::NudgeVideoEditLeft), Some(C::NudgeVideoEditRight), Some(C::RippleTrimPrevious), Some(C::RippleTrimNext), Some(C::TrimPrevious), Some(C::TrimNext), Some(C::RollTrimPrevious), Some(C::RollTrimNext), Some(C::ExtendEdit), Some(C::ToggleTrimType), Some(C::ToggleTrimMode), None, Some(C::AppendToMainTrack), Some(C::InsertSpacer), Some(C::LiftOffMainTrack), Some(C::PutOnMainTrack), Some(C::SetAttachPoint), Some(C::CreateStoryline), Some(C::StorylineRippleDelete), Some(C::MoveClipLeft), Some(C::MoveClipRight), Some(C::DeleteSelectionOnly), None]), vec![Item::Submenu("Nudge".to_string(), cmds(vec![Some(C::NudgeLeft), Some(C::NudgeRight), Some(C::NudgeLeft10), Some(C::NudgeRight10), None, Some(C::SlideLeft), Some(C::SlideRight), Some(C::SlideLeft5), Some(C::SlideRight5), None, Some(C::SlipLeft), Some(C::SlipRight), Some(C::SlipLeft5), Some(C::SlipRight5), None, Some(C::MoveSelectionUp), Some(C::MoveSelectionDown)])), Item::Submenu("Trim Selected Edit".to_string(), cmds(vec![Some(C::TrimBackward), Some(C::TrimForward), Some(C::TrimBackward5), Some(C::TrimForward5)])), Item::Submenu("Track Targets".to_string(), cmds(cat(vec![vec![Some(C::ToggleLockOfTargets), None], (1..=9).map(|n| Some(C::ToggleTrackTarget(TrackKind::Video, n))).collect::<Vec<_>>(), vec![None], (1..=9).map(|n| Some(C::ToggleTrackTarget(TrackKind::Audio, n))).collect::<Vec<_>>()]))), Item::Separator], cmds(vec![Some(C::ApplyVideoTransition), Some(C::ApplyAudioTransition), Some(C::ApplyDefaultTransitions), None, Some(C::AddVideoTrack), Some(C::AddAudioTrack), Some(C::RemoveEmptyTracks), Some(C::DeleteTrack), None, Some(C::ToggleSnapping), Some(C::ToggleLinkedSelection), Some(C::ToggleAllTargets), Some(C::ToggleVideoTargets), Some(C::ToggleAudioTargets), Some(C::ToggleSelectionFollowsPlayhead), Some(C::ToggleMagnetic), None, Some(C::MatchFrame), Some(C::ReverseMatchFrame), None, Some(C::CheckCuts), Some(C::WhooshAtCuts), Some(C::PunchInCuts), Some(C::FillReel), None, Some(C::AddTitle), Some(C::AutoCaptions), None, Some(C::ZoomIn), Some(C::ZoomOut), Some(C::ZoomFit), None, Some(C::PreviousEditPoint), Some(C::NextEditPoint), Some(C::PreviousEditPointAnyTrack), Some(C::NextEditPointAnyTrack), Some(C::GoToStart), Some(C::GoToEnd), Some(C::GoToSelectedClipStart), Some(C::GoToSelectedClipEnd), Some(C::NextSplitPoint), Some(C::PreviousSplitPoint), Some(C::GoToTimecode)])]) }
    }

    /// Premiere's Markers menu: In/Out marking and sequence markers.
    #[rustfmt::skip]
    pub fn markers() -> MenuSpec {
        MenuSpec { title: "Markers".to_string(), items: cmds(vec![Some(C::MarkIn), Some(C::MarkOut), Some(C::MarkClip), None, Some(C::GoToIn), Some(C::GoToOut), None, Some(C::ClearIn), Some(C::ClearOut), Some(C::ClearInOut), None, Some(C::AddMarker), Some(C::AddAndEditMarker), Some(C::EditMarker), Some(C::NextMarker), Some(C::PreviousMarker), Some(C::ClearMarker), Some(C::ClearAllMarkers), None, Some(C::AddBeatMarkers), Some(C::AddMarkersOnDownbeats), None, Some(C::NextWeakTracking), None, Some(C::MarkSelection), Some(C::MarkOverhang), None, Some(C::KeywordAtPlayhead)]) }
    }

    /// View.
    #[rustfmt::skip]
    pub fn view() -> MenuSpec {
        MenuSpec { title: "View".to_string(), items: vec![Item::Submenu("Playback".to_string(), cmds(vec![Some(C::PlayPause), Some(C::PlayFromStart), Some(C::PlayInToOut), Some(C::PlayToOut), Some(C::PlayInToOutRoll), Some(C::PlayAround), Some(C::ToggleLoop), None, Some(C::ShuttleReverse), Some(C::ShuttleStop), Some(C::ShuttleForward), Some(C::ShuttleSlowReverse), Some(C::ShuttleSlowForward), None, Some(C::StepBackward), Some(C::StepForward), Some(C::StepBackward5), Some(C::StepForward5), None, Some(C::AddKeyframe), Some(C::PreviousKeyframe), Some(C::NextKeyframe)])), Item::Separator, Item::Command(C::ToggleAudioScrubbing), Item::Command(C::ToggleHoverScrub), Item::Command(C::ToggleCaptionsInMonitor), Item::Command(C::ToggleSafeAreas), Item::Command(C::ToggleOverlays), Item::Submenu("View Gamma".to_string(), cmds(ViewGammaChoice::ALL.iter().map(|x| Some(C::ViewGamma(*x))).collect::<Vec<_>>())), Item::Submenu("Display".to_string(), cmds(DisplayViewChoice::ALL.iter().map(|x| Some(C::DisplayView(*x))).collect::<Vec<_>>())), Item::Separator, Item::Submenu("Timeline Thumbnails".to_string(), cmds(ThumbnailModeChoice::ALL.iter().map(|x| Some(C::ThumbnailMode(*x))).collect::<Vec<_>>())), Item::Submenu("Project Panel".to_string(), cmds(vec![Some(C::ProjectListView), Some(C::ProjectIconView), None, Some(C::ProjectThumbnailSmaller), Some(C::ProjectThumbnailLarger)])), Item::Separator, Item::Submenu("Track Height".to_string(), cmds(vec![Some(C::AllTracksTaller), Some(C::AllTracksShorter), Some(C::ToggleFitTracks), None, Some(C::VideoTracksTaller), Some(C::VideoTracksShorter), Some(C::AudioTracksTaller), Some(C::AudioTracksShorter), None, Some(C::MinimizeAllTracks), Some(C::ExpandAllTracks), None, Some(C::TrackHeightSmall), Some(C::TrackHeightMedium), Some(C::TrackHeightLarge), Some(C::TrackHeightAuto)])), Item::Separator, Item::Command(C::UiScaleLarger), Item::Command(C::UiScaleSmaller), Item::Command(C::UiScaleReset), Item::Separator, Item::Submenu("Tools".to_string(), cmds(vec![Some(C::Tool(EditorTool::Selection)), Some(C::Tool(EditorTool::TrackForward)), Some(C::Tool(EditorTool::TrackBackward)), Some(C::Tool(EditorTool::Ripple)), Some(C::Tool(EditorTool::Rolling)), Some(C::Tool(EditorTool::Slip)), Some(C::SlipKeyframesStayTool), Some(C::Tool(EditorTool::Slide)), Some(C::Tool(EditorTool::RateStretch)), Some(C::Tool(EditorTool::Razor)), Some(C::Tool(EditorTool::Hand)), Some(C::Tool(EditorTool::Zoom)), Some(C::Tool(EditorTool::Type)), Some(C::Tool(EditorTool::Rectangle)), Some(C::Tool(EditorTool::Ellipse)), Some(C::Tool(EditorTool::Line)), Some(C::Tool(EditorTool::Draw)), Some(C::Tool(EditorTool::Mask)), Some(C::Tool(EditorTool::Position))]))] }
    }

    /// Panels in the Window menu, in menu order: one checkable item each (check = visible in the workspace).
    pub fn window_panels() -> &'static [PanelID] {
        &[
            PanelID::EffectControls,
            PanelID::Text,
            PanelID::Graphics,
            PanelID::ProgramMonitor,
            PanelID::SourceMonitor,
            PanelID::Library,
            PanelID::Effects,
            PanelID::MarkerList,
            PanelID::Project,
            PanelID::Timeline,
            PanelID::Tools,
            PanelID::AudioMeter,
            PanelID::ColorClips,
            PanelID::Steps,
            PanelID::ColorInspector,
            PanelID::Scopes,
        ]
    }

    /// The panel items and the workspace list are added by the app (they carry state); the spec keeps the plain commands.
    pub fn window() -> MenuSpec {
        MenuSpec {
            title: "Window".to_string(),
            items: cmds(vec![
                Some(C::MaximizePanel),
                Some(C::MaximizeActivePanel),
                Some(C::SelectNextPanel),
                Some(C::SelectPreviousPanel),
                Some(C::QuickApply),
            ]),
        }
    }

    /// Keyed commands without an item of their own: the Project panel's Delete is the Edit menu's Delete in that scope
    /// (same key, so a second item would be dead).
    pub fn scope_aliases() -> &'static HashSet<EditorCommand> {
        static SET: OnceLock<HashSet<EditorCommand>> = OnceLock::new();
        SET.get_or_init(|| HashSet::from([C::DeleteProjectItems]))
    }

    /// Commands that stay visible in their menu even when not wired (the standard text editing commands: a text field
    /// handles them).
    pub fn always_shown() -> &'static HashSet<EditorCommand> {
        static SET: OnceLock<HashSet<EditorCommand>> = OnceLock::new();
        SET.get_or_init(|| HashSet::from([C::Undo, C::Redo, C::Cut, C::Copy, C::Paste, C::Delete]))
    }

    /// Commands that are menu-only (no default key in Premiere).
    pub fn menu_only() -> &'static HashSet<EditorCommand> {
        static SET: OnceLock<HashSet<EditorCommand>> = OnceLock::new();
        SET.get_or_init(|| {
            let mut set = base_menu_only();
            set.extend(SplitLayoutPreset::ALL.iter().flat_map(|p| [false, true].map(|a| C::SplitScreen(*p, a))));
            set.extend(SpeedRampPreset::ALL.iter().flat_map(|p| [false, true].map(|b| C::SpeedRampPreset(*p, b))));
            set.extend(ThumbnailModeChoice::ALL.iter().map(|m| C::ThumbnailMode(*m)));
            set.extend(ViewGammaChoice::ALL.iter().map(|g| C::ViewGamma(*g)));
            set.extend(DisplayViewChoice::ALL.iter().map(|g| C::DisplayView(*g)));
            set.extend(ReplaceMode::ALL.iter().map(|m| C::ReplaceMode(*m)));
            set
        })
    }

    /// Panels the Window menu lists directly; the rest sit in "More Panels" (added by the app).
    pub fn primary_window_panels() -> &'static [PanelID] {
        &[
            PanelID::EffectControls,
            PanelID::ProgramMonitor,
            PanelID::SourceMonitor,
            PanelID::Project,
            PanelID::Timeline,
            PanelID::Tools,
            PanelID::Library,
            PanelID::Effects,
            PanelID::AudioMeter,
        ]
    }

    /// The panels of the Window menu that sit in "More Panels".
    pub fn secondary_window_panels() -> Vec<PanelID> {
        Self::window_panels().iter().copied().filter(|p| !Self::primary_window_panels().contains(p)).collect()
    }
}

// The trimmed menus (feedback 2026-10-17): one entry per action, at most about 15 entries per menu, no submenu over 8 entries.
// Everything left out stays reachable through its key and Quick Apply (Window > Quick Apply); the import and export
// variants live in the Import and Export dialogs. The app adds its stateful items (Open Recent, Style Kit, panels).

type Items = Vec<Item>;

fn c(list: Vec<Option<EditorCommand>>) -> Items {
    cmds(list)
}

fn sub(title: &str, parts: Vec<Items>) -> Items {
    vec![Item::Submenu(title.to_string(), parts.into_iter().flatten().collect())]
}

fn sub_cmds(title: &str, list: Vec<Option<EditorCommand>>) -> Items {
    vec![Item::Submenu(title.to_string(), cmds(list))]
}

fn sep() -> Items {
    vec![Item::Separator]
}

fn menu(title: &str, parts: Vec<Items>) -> MenuSpec {
    MenuSpec { title: title.to_string(), items: parts.into_iter().flatten().collect() }
}

fn speed_presets() -> Items {
    let plain: Vec<Option<EditorCommand>> =
        SpeedRampPreset::ALL.iter().map(|p| Some(C::SpeedRampPreset(*p, false))).collect();
    let beat: Vec<Option<EditorCommand>> =
        SpeedRampPreset::ALL.iter().map(|p| Some(C::SpeedRampPreset(*p, true))).collect();
    sub("Speed Ramp Presets", vec![c(plain), sub_cmds("On Beat", beat)])
}

fn split_screens() -> Items {
    let plain: Vec<Option<EditorCommand>> =
        SplitLayoutPreset::ALL.iter().map(|p| Some(C::SplitScreen(*p, false))).collect();
    let anim: Vec<Option<EditorCommand>> =
        SplitLayoutPreset::ALL.iter().map(|p| Some(C::SplitScreen(*p, true))).collect();
    sub("Split Screen", vec![c(plain), sub_cmds("Animated", anim)])
}

fn angles() -> Items {
    let mut list = vec![Some(C::CreateAnglesClip), None];
    list.extend((1..=6).map(|n| Some(C::SwitchAngle(n))));
    sub_cmds("Angles", list)
}

#[rustfmt::skip]
fn visible_file() -> MenuSpec {
    menu("File", vec![c(vec![Some(C::NewProject), Some(C::NewSequence), Some(C::NewBin), None, Some(C::OpenProject), None, Some(C::Save), Some(C::SaveAs), None, Some(C::CloseProject), None, Some(C::ImportMedia), Some(C::Export), Some(C::QuickExport), None]), sub_cmds(PROJECT_SUBMENU_TITLE, vec![Some(C::SaveCopy), Some(C::Revert), Some(C::ProjectNotes)])])
}

#[rustfmt::skip]
fn visible_edit() -> MenuSpec {
    menu("Edit", vec![c(vec![Some(C::Undo), Some(C::Redo), None, Some(C::Cut), Some(C::Copy), Some(C::Paste)]), sub_cmds("Paste Special", vec![Some(C::PasteInsert), Some(C::PasteToTargets), Some(C::PasteAttached), Some(C::PasteAttributes)]), sep(), c(vec![Some(C::Duplicate), Some(C::Delete), Some(C::RippleDelete), None, Some(C::SelectAll), Some(C::DeselectAll)]), sub_cmds("Select", vec![Some(C::SelectClipAtPlayhead), Some(C::SelectNextClip), Some(C::SelectPreviousClip), Some(C::SelectLeftEdge), Some(C::SelectRightEdge)]), sep(), c(vec![Some(C::Find)])])
}

#[rustfmt::skip]
fn visible_clip() -> MenuSpec {
    menu("Clip", vec![c(vec![Some(C::Insert), Some(C::Overwrite), None, Some(C::SpeedDuration), Some(C::ReverseClip), Some(C::EnableClip), None]), sub_cmds("Link and Group", vec![Some(C::Link), Some(C::Unlink), None, Some(C::Group), Some(C::Ungroup), Some(C::Bundle), Some(C::Unbundle)]), sub("Replace and Fit", vec![c(vec![Some(C::FitToFill), Some(C::ReplaceClipFromSource), Some(C::ReplaceClipFromProject), Some(C::SetToFrameSize), Some(C::SetToFillFrame)]), sub_cmds("Replace Modes", ReplaceMode::ALL.iter().map(|x| Some(C::ReplaceMode(*x))).collect::<Vec<_>>())]), sub_cmds("Source", vec![Some(C::SetPosterFrame), Some(C::ClearPosterFrame), Some(C::MakeSubclip), Some(C::EditOriginal)]), sub_cmds("Arrange", vec![Some(C::DetachAudio), Some(C::SyncAudioToReference), Some(C::Solo), Some(C::MuteTracks), Some(C::TrimToRange), Some(C::ExtendToSequenceEnd), Some(C::SaveAsTemplate), Some(C::ToggleAnimationZones)]), sep(), sub("Timing", vec![c(vec![Some(C::ToggleTimeRemapping), Some(C::AddSpeedPoint), Some(C::RemoveTimeRemapping)]), speed_presets(), sub_cmds("Beat Edits", vec![Some(C::CutToBeats), Some(C::SnapToBeats), None, Some(C::FitMusicToLength)])]), sub("Audio Options", vec![c(vec![Some(C::AudioGain)]), sub_cmds("Gain Steps", vec![Some(C::AudioGainDown), Some(C::AudioGainUp), Some(C::AudioGainDown6), Some(C::AudioGainUp6)]), sub_cmds("Loudness and Ducking", vec![Some(C::MatchLoudness), Some(C::AutoDuck), Some(C::ProjectLiveDucking)]), sub("Clean Up", vec![c(vec![Some(C::RemoveSilences), Some(C::RemoveFillerWords)]), sub_cmds("Proposed Cuts", vec![Some(C::ReviewProposedCuts), Some(C::AcceptProposedCuts), Some(C::RejectProposedCuts), Some(C::AcceptProposedCutAtPlayhead), Some(C::RejectProposedCutAtPlayhead)])]), sub_cmds("Voice", vec![Some(C::Voiceover), Some(C::RecordVoiceOver), Some(C::VoiceChain), Some(C::DisguiseVoice)]), sub_cmds("Tag Role", vec![Some(C::TagDialogue), Some(C::TagMusic), Some(C::TagSFX)])]), sub("Video Options", vec![sub_cmds("Holds and Fades", vec![Some(C::AddFrameHold), Some(C::InsertFrameHold), Some(C::VideoFadeIn), Some(C::VideoFadeOut), Some(C::TogglePunchIn)]), sub_cmds("Fit Frame", vec![Some(C::FitBlurredFill), Some(C::FitCard), Some(C::RemoveBlurredFill), Some(C::AutoReframe)]), sub_cmds("Dynamic Zoom", vec![Some(C::DynamicZoomIn), Some(C::DynamicZoomOut), Some(C::EditDynamicZoom)]), c(vec![Some(C::Stabilize), Some(C::MatchColorToClip), Some(C::AddSubjectMask), Some(C::Anonymize), Some(C::FindSceneChanges)])]), sub("Multi-Clip", vec![angles(), split_screens()]), sub_cmds("Ease Keyframes", vec![Some(C::EaseLinear), Some(C::EasyEase), Some(C::EaseIn), Some(C::EaseOut), Some(C::ToggleHoldInterpolation)])])
}

#[rustfmt::skip]
fn visible_sequence() -> MenuSpec {
    menu("Sequence", vec![c(vec![Some(C::SequenceSettings), None]), sub_cmds("New", vec![Some(C::NewTone), Some(C::ToneSettings), Some(C::AddTitle), Some(C::AutoCaptions), Some(C::Bleep)]), sep(), c(vec![Some(C::AddEdit), Some(C::AddEditAllTracks), Some(C::Lift), Some(C::Extract), None]), sub("Edit", vec![sub_cmds("Split and Join", vec![Some(C::JoinCuts), Some(C::JumpCutAlternate), Some(C::SplitEditAudio), Some(C::SplitEditVideo), Some(C::CutOut), Some(C::CloseGapAtPlayhead), Some(C::AttachBacktimed), Some(C::PlaceOnTop)]), sub_cmds("Split Edits", vec![Some(C::JCut), Some(C::LCut), Some(C::JCutByOffset), Some(C::LCutByOffset), Some(C::NudgeAudioEditLeft), Some(C::NudgeAudioEditRight), Some(C::NudgeVideoEditLeft), Some(C::NudgeVideoEditRight)]), sub_cmds("Trim", vec![Some(C::RippleTrimPrevious), Some(C::RippleTrimNext), Some(C::TrimPrevious), Some(C::TrimNext), Some(C::RollTrimPrevious), Some(C::RollTrimNext), Some(C::ExtendEdit)]), sub_cmds("Trim Selected Edit", vec![Some(C::TrimBackward), Some(C::TrimForward), Some(C::TrimBackward5), Some(C::TrimForward5), Some(C::ToggleTrimType), Some(C::ToggleTrimMode)]), sub_cmds("Nudge", vec![Some(C::NudgeLeft), Some(C::NudgeRight), Some(C::NudgeLeft10), Some(C::NudgeRight10), Some(C::MoveSelectionUp), Some(C::MoveSelectionDown)]), sub_cmds("Slip and Slide", vec![Some(C::SlideLeft), Some(C::SlideRight), Some(C::SlideLeft5), Some(C::SlideRight5), Some(C::SlipLeft), Some(C::SlipRight), Some(C::SlipLeft5), Some(C::SlipRight5)]), sub_cmds("Cut Tools", vec![Some(C::CheckCuts), Some(C::WhooshAtCuts), Some(C::PunchInCuts), Some(C::FillReel)])]), sub_cmds("Storyline", vec![Some(C::AppendToMainTrack), Some(C::InsertSpacer), Some(C::LiftOffMainTrack), Some(C::PutOnMainTrack), Some(C::SetAttachPoint), Some(C::CreateStoryline), Some(C::StorylineRippleDelete)]), sub_cmds("Fast Cut", vec![Some(C::MoveClipLeft), Some(C::MoveClipRight), Some(C::DeleteSelectionOnly)]), sub("Tracks and Transitions", vec![c(vec![Some(C::ApplyVideoTransition), Some(C::ApplyAudioTransition), Some(C::ApplyDefaultTransitions), None, Some(C::AddVideoTrack), Some(C::AddAudioTrack), Some(C::RemoveEmptyTracks), Some(C::DeleteTrack)]), sub_cmds("Track Targets", vec![Some(C::ToggleLockOfTargets), Some(C::ToggleAllTargets), Some(C::ToggleVideoTargets), Some(C::ToggleAudioTargets), Some(C::ToggleSelectionFollowsPlayhead)])]), sep(), c(vec![Some(C::ToggleSnapping), Some(C::ToggleLinkedSelection), Some(C::ToggleMagnetic), None]), sub("Go To", vec![c(vec![Some(C::GoToStart), Some(C::GoToEnd), Some(C::GoToSelectedClipStart), Some(C::GoToSelectedClipEnd), Some(C::GoToTimecode), Some(C::MatchFrame), Some(C::ReverseMatchFrame)]), sub_cmds("Edit Points", vec![Some(C::PreviousEditPoint), Some(C::NextEditPoint), Some(C::PreviousEditPointAnyTrack), Some(C::NextEditPointAnyTrack), Some(C::NextSplitPoint), Some(C::PreviousSplitPoint)])]), sub_cmds("Zoom", vec![Some(C::ZoomIn), Some(C::ZoomOut), Some(C::ZoomFit)])])
}

#[rustfmt::skip]
fn visible_markers() -> MenuSpec {
    menu("Markers", vec![c(vec![Some(C::MarkIn), Some(C::MarkOut), Some(C::MarkClip), Some(C::MarkSelection), None, Some(C::GoToIn), Some(C::GoToOut), None]), sub_cmds("Clear In and Out", vec![Some(C::ClearIn), Some(C::ClearOut), Some(C::ClearInOut)]), sep(), c(vec![Some(C::AddMarker), Some(C::NextMarker), Some(C::PreviousMarker)]), sub_cmds("Marker", vec![Some(C::AddAndEditMarker), Some(C::EditMarker), Some(C::ClearMarker), Some(C::ClearAllMarkers), Some(C::AddBeatMarkers), Some(C::AddMarkersOnDownbeats), Some(C::KeywordAtPlayhead), Some(C::MarkOverhang)]), c(vec![Some(C::NextWeakTracking)])])
}

#[rustfmt::skip]
fn visible_view() -> MenuSpec {
    menu("View", vec![sub("Playback", vec![c(vec![Some(C::PlayPause), Some(C::PlayFromStart), Some(C::PlayInToOut), Some(C::PlayAround), Some(C::ToggleLoop)]), sub_cmds("Shuttle", vec![Some(C::ShuttleReverse), Some(C::ShuttleStop), Some(C::ShuttleForward), Some(C::ShuttleSlowReverse), Some(C::ShuttleSlowForward)]), sub_cmds("Step and Keyframes", vec![Some(C::StepBackward), Some(C::StepForward), Some(C::StepBackward5), Some(C::StepForward5), None, Some(C::AddKeyframe), Some(C::PreviousKeyframe), Some(C::NextKeyframe)])]), sep(), c(vec![Some(C::ToggleAudioScrubbing), Some(C::ToggleHoverScrub)]), sub_cmds("Show", vec![Some(C::ToggleCaptionsInMonitor), Some(C::ToggleSafeAreas), Some(C::ToggleOverlays)]), sub_cmds("View Gamma", ViewGammaChoice::ALL.iter().map(|x| Some(C::ViewGamma(*x))).collect::<Vec<_>>()), sub_cmds("Display", DisplayViewChoice::ALL.iter().map(|x| Some(C::DisplayView(*x))).collect::<Vec<_>>()), sep(), sub_cmds("Timeline Thumbnails", ThumbnailModeChoice::ALL.iter().map(|x| Some(C::ThumbnailMode(*x))).collect::<Vec<_>>()), sub_cmds("Project Panel", vec![Some(C::ProjectListView), Some(C::ProjectIconView), None, Some(C::ProjectThumbnailSmaller), Some(C::ProjectThumbnailLarger)]), sub_cmds("Track Height", vec![Some(C::AllTracksTaller), Some(C::AllTracksShorter), Some(C::ToggleFitTracks), Some(C::MinimizeAllTracks), Some(C::ExpandAllTracks), Some(C::TrackHeightSmall), Some(C::TrackHeightMedium), Some(C::TrackHeightLarge)]), sub_cmds("Interface Scale", vec![Some(C::UiScaleLarger), Some(C::UiScaleSmaller), Some(C::UiScaleReset)]), sep(), sub_cmds("Tools", vec![Some(C::Tool(EditorTool::Selection)), Some(C::Tool(EditorTool::Ripple)), Some(C::Tool(EditorTool::Rolling)), Some(C::Tool(EditorTool::Slip)), Some(C::Tool(EditorTool::Slide)), Some(C::Tool(EditorTool::Razor)), Some(C::Tool(EditorTool::Hand)), Some(C::Tool(EditorTool::Zoom))])])
}

fn visible_window() -> MenuSpec {
    menu("Window", vec![c(vec![Some(C::MaximizePanel), Some(C::QuickApply)])])
}

fn base_menu_only() -> HashSet<EditorCommand> {
    HashSet::from([
        C::RemoveEmptyTracks,
        C::MarkOverhang,
        C::NextSplitPoint,
        C::PreviousSplitPoint,
        C::FillReel,
        C::ToggleAllTargets,
        C::FitToFill,
        C::SelectLeftEdge,
        C::SelectRightEdge,
        C::EditMarker,
        C::AddAndEditMarker,
        C::PlayToOut,
        C::Unlink,
        C::TrimToRange,
        C::CreateAnglesClip,
        C::SyncAudioToReference,
        C::Bleep,
        C::NewTone,
        C::ToneSettings,
        C::SetAttachPoint,
        C::KeywordAtPlayhead,
        C::SlipKeyframesStayTool,
        C::PasteToTargets,
        C::ExtendToSequenceEnd,
        C::ToggleAnimationZones,
        C::Revert,
        C::ProjectNotes,
        C::SequenceSettings,
        C::SetToFrameSize,
        C::SetToFillFrame,
        C::CheckCuts,
        C::WhooshAtCuts,
        C::PunchInCuts,
        C::ToggleSelectionFollowsPlayhead,
        C::ToggleAudioScrubbing,
        C::ToggleCaptionsInMonitor,
        C::ToggleSafeAreas,
        C::ToggleOverlays,
        C::ExportMarkersCSV,
        C::EaseLinear,
        C::ImportTimeline,
        C::ExportEDL,
        C::ExportFCPXML,
        C::ExportFinalCutXML,
        C::ExportOpenTimelineIO,
        C::ImportLottie,
        C::ImportMotionGraphicsTemplate,
        C::ImportPremiereProject,
        C::ImportPremierePresets,
        C::ImportProject,
        C::VideoFadeIn,
        C::VideoFadeOut,
        C::AddFrameHold,
        C::InsertFrameHold,
        C::AutoReframe,
        C::Anonymize,
        C::DynamicZoomIn,
        C::DynamicZoomOut,
        C::EditDynamicZoom,
        C::Stabilize,
        C::FindSceneChanges,
        C::MatchColorToClip,
        C::AddSubjectMask,
        C::FitBlurredFill,
        C::FitCard,
        C::RemoveBlurredFill,
        C::JoinCuts,
        C::ToggleTimeRemapping,
        C::RemoveTimeRemapping,
        C::AddSpeedPoint,
        C::ToggleHoldInterpolation,
        C::MatchLoudness,
        C::AutoDuck,
        C::AddBeatMarkers,
        C::AddMarkersOnDownbeats,
        C::CutToBeats,
        C::SnapToBeats,
        C::FitMusicToLength,
        C::ProjectLiveDucking,
        C::RemoveSilences,
        C::RemoveFillerWords,
        C::Voiceover,
        C::RecordVoiceOver,
        C::VoiceChain,
        C::DisguiseVoice,
        C::ReviewProposedCuts,
        C::AcceptProposedCuts,
        C::RejectProposedCuts,
        C::AcceptProposedCutAtPlayhead,
        C::RejectProposedCutAtPlayhead,
        C::TagDialogue,
        C::TagMusic,
        C::TagSFX,
        C::TrackHeightSmall,
        C::TrackHeightMedium,
        C::TrackHeightLarge,
        C::TrackHeightAuto,
    ])
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::command_support::CommandSupport;

    fn count(items: &[Item]) -> usize {
        items.iter().filter(|i| !matches!(i, Item::Separator)).count()
    }

    fn submenus(items: &[Item]) -> Vec<(&str, &[Item])> {
        items
            .iter()
            .flat_map(|item| match item {
                Item::Submenu(t, sub) => [vec![(t.as_str(), sub.as_slice())], submenus(sub)].concat(),
                _ => Vec::new(),
            })
            .collect()
    }

    #[test]
    fn visible_menus_are_a_subset_of_the_catalog() {
        let all: HashSet<EditorCommand> = EditorMenus::all().iter().flat_map(|m| m.commands()).collect();
        for m in EditorMenus::visible() {
            for c in m.commands() {
                assert!(all.contains(&c), "{} > {c:?} is not in the catalog", m.title);
            }
        }
        let visible: Vec<&String> = EditorMenus::visible().iter().map(|m| &m.title).collect();
        let catalog: Vec<&String> = EditorMenus::all().iter().map(|m| &m.title).collect();
        assert_eq!(visible, catalog);
    }

    /// Feedback 2026-10-17: the menu bar shows one entry per action, nothing scrolls.
    #[test]
    fn menus_fit_without_scrolling() {
        for m in EditorMenus::visible() {
            assert!(count(&m.items) <= 15, "{} has {} entries", m.title, count(&m.items));
            for (t, sub) in submenus(&m.items) {
                assert!(count(sub) <= 8, "{} > {t} has {} entries", m.title, count(sub));
            }
        }
    }

    #[test]
    fn one_import_and_one_export_entry() {
        use EditorCommand as C;
        let file = EditorMenus::visible().iter().find(|m| m.title == "File").map(|m| m.commands()).unwrap_or_default();
        assert!(file.contains(&C::ImportMedia) && file.contains(&C::Export));
        let variants = [
            C::ImportTimeline,
            C::ImportLottie,
            C::ImportMotionGraphicsTemplate,
            C::ImportPremiereProject,
            C::ImportPremierePresets,
            C::ImportProject,
            C::ExportFrame,
            C::ExportMarkersCSV,
            C::ExportEDL,
            C::ExportFCPXML,
            C::ExportFinalCutXML,
            C::ExportOpenTimelineIO,
        ];
        for c in variants {
            assert!(!file.contains(&c), "{c:?} should live in the Import / Export dialog");
        }
    }

    #[test]
    fn no_command_appears_twice() {
        for m in EditorMenus::visible() {
            let cmds = m.commands();
            let unique: HashSet<&EditorCommand> = cmds.iter().collect();
            assert_eq!(unique.len(), cmds.len(), "{} lists a command twice", m.title);
        }
    }

    #[test]
    fn window_menu_lists_the_marker_list() {
        assert!(EditorMenus::window_panels().contains(&PanelID::MarkerList));
        assert!(PanelID::dockable().contains(&PanelID::MarkerList));
        assert_eq!(EditorCommand::FocusPanel(PanelID::MarkerList).title(), "Show Markers");
        assert_eq!(EditorMenus::secondary_window_panels().len(), 7);
    }

    #[test]
    fn tools_is_listed_once_in_the_window_menu() {
        assert!(EditorMenus::primary_window_panels().contains(&PanelID::Tools));
        assert!(!EditorMenus::secondary_window_panels().contains(&PanelID::Tools));
        let mut all = EditorMenus::primary_window_panels().to_vec();
        all.extend(EditorMenus::secondary_window_panels());
        assert_eq!(all.iter().filter(|p| **p == PanelID::Tools).count(), 1);
    }

    #[test]
    fn file_menu_has_the_marker_csv_export() {
        assert!(EditorMenus::file().commands().contains(&EditorCommand::ExportMarkersCSV));
        assert!(CommandSupport::is_supported(&EditorCommand::ExportMarkersCSV));
        assert_eq!(EditorCommand::ExportMarkersCSV.title(), "Export Markers as CSV…");
    }

    #[test]
    fn view_menu_has_one_item_per_thumbnail_mode() {
        let cmds = EditorMenus::view().commands();
        for m in ThumbnailModeChoice::ALL {
            assert!(cmds.contains(&EditorCommand::ThumbnailMode(m)));
            assert!(CommandSupport::is_supported(&EditorCommand::ThumbnailMode(m)));
        }
    }

    #[test]
    fn view_menu_has_overlays_and_one_item_per_gamma() {
        let cmds = EditorMenus::view().commands();
        assert!(cmds.contains(&EditorCommand::ToggleOverlays));
        assert!(CommandSupport::is_supported(&EditorCommand::ToggleOverlays));
        for g in ViewGammaChoice::ALL {
            assert!(cmds.contains(&EditorCommand::ViewGamma(g)));
            assert!(CommandSupport::is_supported(&EditorCommand::ViewGamma(g)));
        }
        let raws: Vec<&str> = ViewGammaChoice::ALL.iter().map(|g| g.raw_value()).collect();
        assert_eq!(raws, ["mac", "web", "broadcast"]);
    }

    #[test]
    fn every_replace_mode_is_in_the_clip_menu_without_a_key() {
        let visible: Vec<EditorCommand> = EditorMenus::visible().iter().flat_map(|m| m.commands()).collect();
        for m in ReplaceMode::ALL {
            assert!(visible.contains(&EditorCommand::ReplaceMode(m)));
            assert_eq!(EditorCommand::ReplaceMode(m).title(), m.title());
        }
    }

    /// No menu row may reach the shell's "not available in this window yet" path (Swift `notYetShared` is empty):
    /// every command of every menu, on every platform (the menus have no platform switch), is in the supported set.
    #[test]
    fn no_menu_command_is_outside_the_supported_set() {
        for m in EditorMenus::all().iter().chain(EditorMenus::visible()) {
            for c in m.commands() {
                assert!(CommandSupport::is_supported(&c), "{} > {c:?} would answer \"not available\"", m.title);
            }
        }
    }

    /// Remove Silences, Remove Filler Words and Punch In Cuts must stay reachable (menus, supported, titled).
    #[test]
    fn shortform_commands_are_listed_supported_and_titled() {
        let listed: HashSet<EditorCommand> = EditorMenus::all().iter().flat_map(|m| m.commands()).collect();
        for c in [EditorCommand::RemoveSilences, EditorCommand::RemoveFillerWords, EditorCommand::PunchInCuts] {
            assert!(listed.contains(&c), "{c:?} missing from the menus");
            assert!(CommandSupport::is_supported(&c));
            assert!(!c.title().is_empty());
        }
    }

    #[test]
    fn scoped_command_sets_hold_their_members() {
        assert!(EditorMenus::scope_aliases().contains(&EditorCommand::DeleteProjectItems));
        assert!(EditorMenus::always_shown().contains(&EditorCommand::Undo));
        assert!(EditorMenus::menu_only().contains(&EditorCommand::ReplaceMode(ReplaceMode::ALL[0])));
        assert!(EditorMenus::menu_only().contains(&EditorCommand::RemoveEmptyTracks));
    }
}

#[cfg(test)]
mod row_limit {
    use super::*;

    /// A menu over 16 rows needs a "More" submenu with its rare rows (the design notes); today none does.
    #[test]
    fn no_menu_bar_menu_has_more_than_16_rows() {
        for m in EditorMenus::visible() {
            let rows = m.items.iter().filter(|i| !matches!(i, Item::Separator)).count();
            assert!(rows <= 16, "{} has {rows} rows: move the rare ones into a \"More\" submenu", m.title);
        }
    }
}
