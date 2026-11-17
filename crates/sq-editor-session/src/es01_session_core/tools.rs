//! Tool state: timeline tools, mask and create modes, gesture modifiers, the toggles that survive a relaunch, edge and
//! gap selections.

use std::collections::BTreeSet;

use sq_core_edit::timeline_beat_snap::BeatSnapLevel;

use sq_core_model::{ClipEdge, MaskShapeKind, ShapeKind};
use sq_core_time::{Id, TimeRange};
use sq_library::library_folder_store::SettingsStore;
use sq_uikit::editor_command::EditorTool;

/// Timeline tools (Premiere keys).
// Swift: ToolState.swift:4
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum TimelineTool {
    Selection,
    TrackSelectForward,
    RippleEdit,
    RollEdit,
    Slip,
    Slide,
    Razor,
    Hand,
    /// Rate Stretch (R): dragging a clip edge changes the speed instead of trimming.
    RateStretch,
    /// Zoom (Z): click zooms in, Option-click out, drag a box to zoom to it.
    Zoom,
    /// Position (Shift+V, Fast Cut): a dragged clip lands where it is dropped, overwrites what is there and leaves a
    /// hole behind instead of rippling. In Normal it behaves like Selection.
    Position,
    /// The Mask tool (Program monitor: Magic / Pen / Ellipse / Rectangle, `ToolState::mask_mode`).
    Mask,
    /// The Create slot (Program monitor: Text / Rectangle / Ellipse / Line / Draw, `ToolState::create_mode`).
    Type,
}

impl TimelineTool {
    /// All tools in declaration order (Swift `CaseIterable`).
    pub const ALL: [TimelineTool; 13] = [
        TimelineTool::Selection,
        TimelineTool::TrackSelectForward,
        TimelineTool::RippleEdit,
        TimelineTool::RollEdit,
        TimelineTool::Slip,
        TimelineTool::Slide,
        TimelineTool::Razor,
        TimelineTool::Hand,
        TimelineTool::RateStretch,
        TimelineTool::Zoom,
        TimelineTool::Position,
        TimelineTool::Mask,
        TimelineTool::Type,
    ];

    /// What the timeline does with this tool: the tools that only act in the monitor (Create, Mask) behave exactly
    /// like Selection there. The active tool itself does not change.
    // Swift: ToolState.swift:21
    pub fn effective_timeline_tool(self) -> TimelineTool {
        match self {
            TimelineTool::Mask | TimelineTool::Type => TimelineTool::Selection,
            other => other,
        }
    }

    // Swift: ToolState.swift:27
    pub fn from_key(key: char) -> Option<TimelineTool> {
        Some(match key.to_lowercase().next()? {
            'v' => TimelineTool::Selection,
            'a' => TimelineTool::TrackSelectForward,
            'b' => TimelineTool::RippleEdit,
            'n' => TimelineTool::RollEdit,
            'y' => TimelineTool::Slip,
            'u' => TimelineTool::Slide,
            'c' => TimelineTool::Razor,
            'h' => TimelineTool::Hand,
            't' => TimelineTool::Type,
            'r' => TimelineTool::RateStretch,
            'z' => TimelineTool::Zoom,
            'p' => TimelineTool::Mask,
            _ => return None,
        })
    }

    // Swift: ToolState.swift:45
    pub fn key(self) -> char {
        match self {
            TimelineTool::Selection => 'v',
            TimelineTool::TrackSelectForward => 'a',
            TimelineTool::RippleEdit => 'b',
            TimelineTool::RollEdit => 'n',
            TimelineTool::Slip => 'y',
            TimelineTool::Slide => 'u',
            TimelineTool::Razor => 'c',
            TimelineTool::Hand => 'h',
            // O is Mark Out; the Mask tool takes over the pen slot's P (decision 2026-10-05)
            TimelineTool::Mask => 'p',
            TimelineTool::Type => 't',
            TimelineTool::RateStretch => 'r',
            TimelineTool::Zoom => 'z',
            // Shift+V: `from_key` keeps V for Selection, the key map binds the shifted key
            TimelineTool::Position => 'v',
        }
    }
}

/// What the Mask tool makes with a click on the Program monitor.
// Swift: ToolState.swift:67
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum MaskToolMode {
    /// Hover highlights the object under the pointer; click picks it; Track follows the pick.
    Magic,
    /// Each click adds a corner point to the active path mask (Shift-click starts a new one).
    Pen,
    Ellipse,
    Rectangle,
}

impl MaskToolMode {
    pub const ALL: [MaskToolMode; 4] =
        [MaskToolMode::Magic, MaskToolMode::Pen, MaskToolMode::Ellipse, MaskToolMode::Rectangle];

    /// The stored raw value.
    pub fn raw_value(self) -> &'static str {
        match self {
            MaskToolMode::Magic => "magic",
            MaskToolMode::Pen => "pen",
            MaskToolMode::Ellipse => "ellipse",
            MaskToolMode::Rectangle => "rectangle",
        }
    }

    // Swift: ToolState.swift:73
    pub fn title(self) -> &'static str {
        match self {
            MaskToolMode::Magic => "Magic",
            MaskToolMode::Pen => "Pen",
            MaskToolMode::Ellipse => "Ellipse",
            MaskToolMode::Rectangle => "Rectangle",
        }
    }

    /// The shape a drag draws in this mode (Ellipse / Rectangle); `None` for Magic and Pen.
    // Swift: ToolState.swift:78
    pub fn shape_kind(self) -> Option<MaskShapeKind> {
        match self {
            MaskToolMode::Ellipse => Some(MaskShapeKind::Ellipse),
            MaskToolMode::Rectangle => Some(MaskShapeKind::Rectangle),
            MaskToolMode::Magic | MaskToolMode::Pen => None,
        }
    }

    // Swift: ToolState.swift:81
    pub fn symbol(self) -> &'static str {
        match self {
            MaskToolMode::Magic => "toolMask",
            MaskToolMode::Pen => "pen",
            MaskToolMode::Ellipse => "circleDashed",
            MaskToolMode::Rectangle => "squareDashed",
        }
    }
}

/// What the Create tool makes with a drag on the Program monitor: an item of a Graphic clip.
// Swift: ToolState.swift:92
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum CreateToolMode {
    /// Click places text and types into it (the Type tool).
    Text,
    Rectangle,
    Ellipse,
    Line,
    /// A freehand stroke, smoothed on release.
    Draw,
}

impl CreateToolMode {
    pub const ALL: [CreateToolMode; 5] = [
        CreateToolMode::Text,
        CreateToolMode::Rectangle,
        CreateToolMode::Ellipse,
        CreateToolMode::Line,
        CreateToolMode::Draw,
    ];

    /// The stored raw value.
    pub fn raw_value(self) -> &'static str {
        match self {
            CreateToolMode::Text => "text",
            CreateToolMode::Rectangle => "rectangle",
            CreateToolMode::Ellipse => "ellipse",
            CreateToolMode::Line => "line",
            CreateToolMode::Draw => "draw",
        }
    }

    // Swift: ToolState.swift:98
    pub fn title(self) -> &'static str {
        match self {
            CreateToolMode::Text => "Text",
            CreateToolMode::Rectangle => "Rectangle",
            CreateToolMode::Ellipse => "Ellipse",
            CreateToolMode::Line => "Line",
            CreateToolMode::Draw => "Draw",
        }
    }

    // Swift: ToolState.swift:102
    pub fn symbol(self) -> &'static str {
        match self {
            CreateToolMode::Text => "text",
            CreateToolMode::Rectangle => "shapeRectangle",
            CreateToolMode::Ellipse => "shapeEllipse",
            CreateToolMode::Line => "shapeLine",
            CreateToolMode::Draw => "draw",
        }
    }

    /// The key-map tool that selects this mode.
    // Swift: ToolState.swift:112
    pub fn editor_tool(self) -> EditorTool {
        match self {
            CreateToolMode::Text => EditorTool::Type,
            CreateToolMode::Rectangle => EditorTool::Rectangle,
            CreateToolMode::Ellipse => EditorTool::Ellipse,
            CreateToolMode::Line => EditorTool::Line,
            CreateToolMode::Draw => EditorTool::Draw,
        }
    }

    // Swift: ToolState.swift:115
    pub fn from_editor_tool(tool: EditorTool) -> Option<CreateToolMode> {
        Self::ALL.into_iter().find(|m| m.editor_tool() == tool)
    }

    /// The shape a drag makes in this mode; `None` for Text and Draw.
    // Swift: ToolState.swift:120
    pub fn shape_kind(self) -> Option<ShapeKind> {
        match self {
            CreateToolMode::Rectangle => Some(ShapeKind::Rectangle),
            CreateToolMode::Ellipse => Some(ShapeKind::Ellipse),
            CreateToolMode::Line => Some(ShapeKind::Line),
            CreateToolMode::Text | CreateToolMode::Draw => None,
        }
    }
}

/// Modifier keys held during a gesture (Swift `OptionSet`).
// Swift: ToolState.swift:125
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub struct GestureModifiers {
    // Swift: ToolState.swift:126
    pub raw_value: i64,
}

impl GestureModifiers {
    // Swift: ToolState.swift:128
    pub const SHIFT: GestureModifiers = GestureModifiers { raw_value: 1 };
    // Swift: ToolState.swift:129
    pub const COMMAND: GestureModifiers = GestureModifiers { raw_value: 2 };
    // Swift: ToolState.swift:130
    pub const OPTION: GestureModifiers = GestureModifiers { raw_value: 4 };
    // Swift: ToolState.swift:131
    pub const CONTROL: GestureModifiers = GestureModifiers { raw_value: 8 };

    // Swift: ToolState.swift:127
    pub const fn new(raw_value: i64) -> GestureModifiers {
        GestureModifiers { raw_value }
    }

    /// Whether every flag of `other` is set.
    pub const fn contains(self, other: GestureModifiers) -> bool {
        self.raw_value & other.raw_value == other.raw_value
    }
}

impl std::ops::BitOr for GestureModifiers {
    type Output = GestureModifiers;
    fn bitor(self, rhs: GestureModifiers) -> GestureModifiers {
        GestureModifiers { raw_value: self.raw_value | rhs.raw_value }
    }
}

/// Tool column state: active tool plus the toggles that change gesture behavior.
// Swift: ToolState.swift:134
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ToolState {
    // Swift: ToolState.swift:136
    pub tool: TimelineTool,
    /// `S`: clip edges, playhead and markers attract moves and trims.
    // Swift: ToolState.swift:140
    pub snapping: bool,
    /// Linked selection: clicking a clip also selects (and razor also cuts) its linked partners.
    // Swift: ToolState.swift:142
    pub linked_selection: bool,
    /// Track Select tool direction: false = forward (A), true = backward (Shift+A).
    // Swift: ToolState.swift:144
    pub select_backward: bool,
    /// Slip variant: the clip's keyframes stay at their timeline position instead of moving with the content.
    // Swift: ToolState.swift:147
    pub slip_keyframes_stay: bool,
    /// Fast Cut "keep attached" override (hold ` during a delete or drag).
    // Swift: ToolState.swift:150
    pub keep_attached: bool,
    /// Sequences dropped or inserted land as their own clips instead of one combined clip. App setting
    /// `sq.placeSequencesAsClips`.
    // Swift: ToolState.swift:153
    pub place_sequences_as_clips: bool,
    /// Mask tool mode (long-press menu of the Mask slot); Magic by default.
    // Swift: ToolState.swift:155
    pub mask_mode: MaskToolMode,
    /// Create tool mode (long-press menu of the Create slot); Text by default.
    // Swift: ToolState.swift:157
    pub create_mode: CreateToolMode,
}

impl Default for ToolState {
    fn default() -> ToolState {
        ToolState::new(TimelineTool::Selection, true, true)
    }
}

impl ToolState {
    // Swift: ToolState.swift:158
    pub fn new(tool: TimelineTool, snapping: bool, linked_selection: bool) -> ToolState {
        ToolState {
            tool,
            snapping,
            linked_selection,
            select_backward: false,
            slip_keyframes_stay: false,
            keep_attached: false,
            place_sequences_as_clips: false,
            mask_mode: MaskToolMode::Magic,
            create_mode: CreateToolMode::Text,
        }
    }

    /// `tool` as the timeline sees it (`TimelineTool::effective_timeline_tool`).
    // Swift: ToolState.swift:138
    pub fn timeline_tool(&self) -> TimelineTool {
        self.tool.effective_timeline_tool()
    }

    // Swift: ToolState.swift:166
    pub const SNAPPING_DEFAULTS_KEY: &'static str = "sq.timeline.snapping";
    // Swift: ToolState.swift:167
    pub const LINKED_SELECTION_DEFAULTS_KEY: &'static str = "sq.timeline.linkedSelection";

    /// Takes the two remembered toggles (a missing value keeps the default on).
    // Swift: ToolState.swift:170
    pub fn apply_stored_toggles(&mut self, defaults: &dyn SettingsStore) {
        self.snapping = read_bool(defaults, Self::SNAPPING_DEFAULTS_KEY).unwrap_or(true);
        self.linked_selection = read_bool(defaults, Self::LINKED_SELECTION_DEFAULTS_KEY).unwrap_or(true);
    }

    /// Remembers the two toggles for the next launch.
    // Swift: ToolState.swift:176
    pub fn store_toggles(&self, defaults: &mut dyn SettingsStore) {
        write_bool(defaults, Self::SNAPPING_DEFAULTS_KEY, self.snapping);
        write_bool(defaults, Self::LINKED_SELECTION_DEFAULTS_KEY, self.linked_selection);
    }

    /// The Tools menu and the tool commands: the key-map tool as the timeline's tool state. The Slip slot's variant is
    /// off again (Y = plain slip), the Create slot takes the mode of its key.
    // Swift: ToolState.swift:334
    pub fn select(&mut self, t: EditorTool) -> bool {
        let mapped = match t {
            EditorTool::Selection => TimelineTool::Selection,
            EditorTool::TrackForward | EditorTool::TrackBackward => TimelineTool::TrackSelectForward,
            EditorTool::Ripple => TimelineTool::RippleEdit,
            EditorTool::Rolling => TimelineTool::RollEdit,
            EditorTool::Slip => TimelineTool::Slip,
            EditorTool::Slide => TimelineTool::Slide,
            EditorTool::Razor => TimelineTool::Razor,
            EditorTool::Hand => TimelineTool::Hand,
            EditorTool::Type | EditorTool::Rectangle | EditorTool::Ellipse | EditorTool::Line | EditorTool::Draw => {
                TimelineTool::Type
            }
            EditorTool::RateStretch => TimelineTool::RateStretch,
            EditorTool::Zoom => TimelineTool::Zoom,
            EditorTool::Mask => TimelineTool::Mask,
            EditorTool::Position => TimelineTool::Position,
        };
        self.select_backward = t == EditorTool::TrackBackward;
        if t == EditorTool::Slip {
            self.slip_keyframes_stay = false;
        }
        self.tool = mapped;
        if mapped == TimelineTool::Type
            && let Some(mode) = CreateToolMode::from_editor_tool(t)
        {
            self.create_mode = mode;
        }
        true
    }

    /// Tools > Slip Tool (Keyframes Stay): the slip tool with the variant on.
    // Swift: ToolState.swift:360
    pub fn select_slip_keyframes_stay(&mut self) -> bool {
        self.select(EditorTool::Slip);
        self.slip_keyframes_stay = true;
        true
    }
}

fn read_bool(defaults: &dyn SettingsStore, key: &str) -> Option<bool> {
    match defaults.data(key)?.as_slice() {
        b"true" => Some(true),
        b"false" => Some(false),
        _ => None,
    }
}

fn write_bool(defaults: &mut dyn SettingsStore, key: &str, v: bool) {
    defaults.set_data(key, if v { b"true".to_vec() } else { b"false".to_vec() });
}

/// One clip edge picked with the Selection tool (click on a clip's head or tail).
// Swift: ToolState.swift:182
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct EdgeRef {
    // Swift: ToolState.swift:184
    pub clip: Id,
    // Swift: ToolState.swift:185
    pub edge: ClipEdge,
}

impl EdgeRef {
    // Swift: ToolState.swift:186
    pub fn new(clip: Id, edge: ClipEdge) -> EdgeRef {
        EdgeRef { clip, edge }
    }
}

/// Selected clip edges. `ripple` (Cmd-click) makes trims ripple; both sides of one edit selected make a rolling edit.
/// `linked` false (Option-click, or Linked Selection off): only these edges' clips trim, linked partners stay.
// Swift: ToolState.swift:190
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EdgeSelection {
    // Swift: ToolState.swift:192
    pub edges: Vec<EdgeRef>,
    // Swift: ToolState.swift:193
    pub ripple: bool,
    // Swift: ToolState.swift:194
    pub linked: bool,
}

impl EdgeSelection {
    /// `ripple` false and `linked` true are the Swift defaults.
    // Swift: ToolState.swift:195
    pub fn new(edges: Vec<EdgeRef>, ripple: bool, linked: bool) -> EdgeSelection {
        EdgeSelection { edges, ripple, linked }
    }

    /// Clips an unlinked edge edit is limited to; `None` when linked partners follow.
    // Swift: ToolState.swift:199
    pub fn scope(&self) -> Option<BTreeSet<Id>> {
        (!self.linked).then(|| self.edges.iter().map(|e| e.clip).collect())
    }
}

/// A selected gap (click on empty space between clips): Delete closes it.
// Swift: ToolState.swift:202
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct GapSelection {
    // Swift: ToolState.swift:204
    pub track: Id,
    // Swift: ToolState.swift:205
    pub range: TimeRange,
}

impl GapSelection {
    // Swift: ToolState.swift:206
    pub fn new(track: Id, range: TimeRange) -> GapSelection {
        GapSelection { track, range }
    }
}

/// Which beat markers snap is a per-Mac view preference, never part of a project.
pub enum BeatSnapSetting {}

impl BeatSnapSetting {
    // Swift: ToolState.swift:322
    pub const DEFAULTS_KEY: &'static str = "sq.timeline.beatSnapLevel";

    // Swift: ToolState.swift:323
    pub fn stored(defaults: &dyn SettingsStore) -> BeatSnapLevel {
        defaults
            .data(Self::DEFAULTS_KEY)
            .and_then(|d| String::from_utf8(d).ok())
            .and_then(|s| BeatSnapLevel::from_raw(&s))
            .unwrap_or(BeatSnapLevel::EveryBeat)
    }

    // Swift: ToolState.swift:327
    pub fn store(level: BeatSnapLevel, defaults: &mut dyn SettingsStore) {
        defaults.set_data(Self::DEFAULTS_KEY, level.raw_value().as_bytes().to_vec());
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_library::library_folder_store::MemorySettings;

    #[test]
    fn keys_map_to_tools_and_back() {
        for t in TimelineTool::ALL {
            if t != TimelineTool::Position {
                assert_eq!(TimelineTool::from_key(t.key()), Some(t));
            }
        }
        assert_eq!(TimelineTool::from_key('V'), Some(TimelineTool::Selection));
        assert_eq!(TimelineTool::from_key('q'), None);
    }

    #[test]
    fn monitor_tools_act_as_selection_in_the_timeline() {
        let mut s = ToolState::default();
        s.select(EditorTool::Mask);
        assert_eq!((s.tool, s.timeline_tool()), (TimelineTool::Mask, TimelineTool::Selection));
        s.select(EditorTool::Line);
        assert_eq!((s.tool, s.create_mode), (TimelineTool::Type, CreateToolMode::Line));
        assert_eq!(s.timeline_tool(), TimelineTool::Selection);
        s.select(EditorTool::Ripple);
        assert_eq!(s.timeline_tool(), TimelineTool::RippleEdit);
    }

    #[test]
    fn slip_variant_and_track_direction_follow_the_selection() {
        let mut s = ToolState::default();
        s.select(EditorTool::TrackBackward);
        assert!(s.select_backward && s.tool == TimelineTool::TrackSelectForward);
        s.select_slip_keyframes_stay();
        assert!(s.slip_keyframes_stay && !s.select_backward);
        s.select(EditorTool::Slip);
        assert!(!s.slip_keyframes_stay);
    }

    #[test]
    fn toggles_survive_through_the_settings_store() {
        let mut store = MemorySettings::default();
        let mut s = ToolState::default();
        s.apply_stored_toggles(&store);
        assert!(s.snapping && s.linked_selection);
        s.snapping = false;
        s.store_toggles(&mut store);
        let mut again = ToolState::default();
        again.apply_stored_toggles(&store);
        assert!(!again.snapping && again.linked_selection);
        assert_eq!(BeatSnapSetting::stored(&store), BeatSnapLevel::EveryBeat);
        BeatSnapSetting::store(BeatSnapLevel::BarsOnly, &mut store);
        assert_eq!(BeatSnapSetting::stored(&store), BeatSnapLevel::BarsOnly);
    }

    #[test]
    fn modes_expose_shapes_and_edge_scope() {
        assert_eq!(MaskToolMode::Ellipse.shape_kind(), Some(MaskShapeKind::Ellipse));
        assert_eq!(MaskToolMode::Pen.shape_kind(), None);
        assert_eq!(CreateToolMode::from_editor_tool(EditorTool::Draw), Some(CreateToolMode::Draw));
        assert_eq!(CreateToolMode::from_editor_tool(EditorTool::Razor), None);
        assert_eq!(CreateToolMode::Text.shape_kind(), None);
        let a = Id::from_u128(1);
        let e = EdgeSelection::new(vec![EdgeRef::new(a, ClipEdge::Head)], false, false);
        assert_eq!(e.scope(), Some([a].into_iter().collect()));
        assert_eq!(EdgeSelection::new(vec![], false, true).scope(), None);
        assert!((GestureModifiers::SHIFT | GestureModifiers::OPTION).contains(GestureModifiers::OPTION));
    }
}
