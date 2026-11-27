//! Tests ported from `TimelineItemLanesTests`, `SourcePatchTests` and `TransitionLayerTests`, and the band, Fast Cut,
//! keystone, caption and view command suites: a panel behind a real `EditorSession`, driven by input events, the actions
//! applied through the session bridge like the host does.

use crate::action::TimelineAction;
use crate::host::TimelineHost;
use crate::item_lanes::ItemLaneMetrics;
use crate::panel::{SessionView, TimelinePanel};
use crate::session_bridge;
use sq_core_effects::transition_layer::TimelineTransitionLayer as _;
use sq_core_model::{
    Clip, GraphicsLayer, LabelResolver, Project, SequenceFormat, ShapeKind, Timeline, Track, TrackKind,
};
use sq_core_time::{Id, IdSource, SequentialIds, Time, TimeRange};
use sq_draw::{DrawTheme, InputEvent, InputKey, InputModifiers, Rect, UiCx};
use sq_editor_session::{EditorSession, SessionDeps};
use sq_timeline_ui::TimelineGeometry;
use sq_uikit::controls_grid::{CGPoint, CGRect};
use std::cell::RefCell;
use std::collections::BTreeSet;
use std::rc::Rc;

pub(crate) fn uid(n: u128) -> Id {
    Id::from_u128((1 << 80) + n)
}

pub(crate) fn session_over(tl: Timeline) -> EditorSession {
    let project = Project::new(uid(7000), "P", Vec::new(), vec![tl]);
    let mut deps = SessionDeps::headless(std::env::temp_dir().join("sq-draw-timeline-tests"));
    deps.ids = Box::new(SequentialIds::default());
    EditorSession::new(project, deps)
}

/// The item selection the host hook last received.
pub(crate) type Picked = Rc<RefCell<Option<(Id, BTreeSet<Id>)>>>;

/// A panel of `w x h` points synced to a session, behind a host with an item selection hook.
pub(crate) struct Rig {
    pub p: TimelinePanel,
    pub s: EditorSession,
    pub host: TimelineHost,
    pub ui: UiCx,
    pub picked: Picked,
}

impl Rig {
    pub(crate) fn new(tl: Timeline, w: f32, h: f32) -> Rig {
        Rig::from_session(session_over(tl), w, h)
    }

    /// A panel over a session that is already set up (the panel fits the sequence on its first sync).
    pub(crate) fn from_session(s: EditorSession, w: f32, h: f32) -> Rig {
        let mut p = TimelinePanel::new(DrawTheme::default());
        p.layout_px(Rect::new(0.0, 0.0, w, h), 1.0);
        let picked = Rc::new(RefCell::new(None));
        let mut host = TimelineHost::new();
        let hook = Rc::clone(&picked);
        host.item_selection = Some(Box::new(move |clip, items| *hook.borrow_mut() = Some((clip, items.clone()))));
        let mut r = Rig { p, s, host, ui: UiCx::new(), picked };
        r.sync();
        r
    }

    pub(crate) fn sync(&mut self) {
        let Some(t) = self.s.active_timeline() else { return };
        self.p.sync(SessionView {
            timeline: t,
            selection: self.s.selection(),
            captions: self.s.caption_selection(),
            playhead: self.s.playhead(),
            selected_transition: None,
            labels: LabelResolver::default(),
            line_keys: BTreeSet::new(),
        });
    }

    pub(crate) fn run(&mut self, actions: Vec<TimelineAction>) -> Vec<String> {
        let lines = actions
            .into_iter()
            .filter_map(|a| session_bridge::apply(a, &mut self.s, &mut self.host, Some(&mut self.p)))
            .collect();
        self.sync();
        lines
    }

    pub(crate) fn send(&mut self, e: InputEvent) -> Vec<TimelineAction> {
        let actions = self.p.handle(&e, &mut self.ui);
        self.run(actions.clone());
        actions
    }

    pub(crate) fn key(&mut self, k: InputKey, m: InputModifiers) -> Option<Vec<TimelineAction>> {
        let out = self.p.key(k, m, &mut self.ui);
        if let Some(a) = &out {
            self.run(a.clone());
        }
        out
    }

    pub(crate) fn tl(&self) -> &Timeline {
        self.s.active_timeline().expect("timeline")
    }

    pub(crate) fn down(&mut self, x: f64, y: f64) -> Vec<TimelineAction> {
        self.send(InputEvent::MouseDown { x: x as f32, y: y as f32, modifiers: InputModifiers::NONE })
    }
    pub(crate) fn drag(&mut self, x: f64, y: f64) -> Vec<TimelineAction> {
        self.send(InputEvent::dragged(x as f32, y as f32))
    }
    pub(crate) fn up(&mut self, x: f64, y: f64) -> Vec<TimelineAction> {
        self.send(InputEvent::MouseUp { x: x as f32, y: y as f32 })
    }
}

fn pt(x: f64, y: f64) -> CGPoint {
    CGPoint { x, y }
}

// MARK: Item lanes

mod item_lanes {
    use super::*;
    use crate::item_lanes::{ItemLaneBarMode, ItemLaneHit};

    const FD: Time = Time::new(1, 30);

    fn item(ids: &mut dyn IdSource, name: &str, range: Option<TimeRange>) -> GraphicsLayer {
        let mut l = GraphicsLayer::shape(ids, ShapeKind::Rectangle, 1920, 1080);
        l.name = name.to_string();
        l.range = range;
        l
    }

    /// V1 with a 10 s Graphic at 2 s holding "low" (bottom) and "top", V2 empty, A1 below; a 1200 x 500 pt panel.
    struct Lanes {
        r: Rig,
        graphic: Id,
        tracks: Vec<Id>,
    }

    impl Lanes {
        fn new() -> Lanes {
            let (v, v2, a) = (
                Track::new(uid(1), TrackKind::Video),
                Track::new(uid(2), TrackKind::Video),
                Track::new(uid(3), TrackKind::Audio),
            );
            let tracks = vec![v.id, v2.id, a.id];
            let t = Timeline::new(uid(9000), "T", SequenceFormat::new(FD), vec![v, v2, a]);
            let mut s = session_over(t);
            let mut ids = SequentialIds::default();
            let layers = vec![
                item(&mut ids, "low", None),
                item(&mut ids, "top", Some(TimeRange::new(Time::new(2, 1), Time::new(2, 1)))),
            ];
            let graphic = s
                .add_graphics_clip(Some(Time::new(2, 1)), Some(tracks[0]), Time::new(10, 1), layers, false)
                .unwrap_or_else(|| panic!("graphic: {:?}", s.last_error()));
            Lanes { r: Rig::from_session(s, 1200.0, 500.0), graphic, tracks }
        }

        fn clip(&self) -> Clip {
            self.r
                .tl()
                .tracks
                .iter()
                .flat_map(|t| t.clips().iter())
                .find(|c| c.id == self.graphic)
                .cloned()
                .expect("clip")
        }
        fn layers(&self) -> Vec<GraphicsLayer> {
            self.clip().graphics().map(|g| g.layers.clone()).unwrap_or_default()
        }
        fn row(&self) -> sq_timeline_ui::TrackRow {
            self.r.p.rows().into_iter().find(|r| r.track == self.tracks[0]).expect("row")
        }
        fn x(&self, t: Time) -> f64 {
            self.r.p.geometry.x(t)
        }
        /// Middle of lane `index` (0 = the top item).
        fn lane_y(&self, index: usize) -> f64 {
            self.row().max_y() + (index as f64 + 0.5) * ItemLaneMetrics::LANE_HEIGHT
        }
        fn open(&mut self) {
            let c = self.clip();
            let rect = CGRect::new(
                self.r.p.geometry.x(c.timeline().start),
                self.row().y,
                self.r.p.geometry.width(c.timeline().duration),
                self.row().height,
            );
            let q = ItemLaneMetrics::chevron_rect(rect, self.r.p.item_lane_content()).expect("chevron");
            self.r.down(q.mid_x(), q.mid_y());
            self.r.up(q.mid_x(), q.mid_y());
        }
    }

    #[test]
    fn chevron_opens_the_lanes_and_makes_room() {
        let mut l = Lanes::new();
        assert!(l.r.p.open_item_lanes().is_empty() && l.row().lane_space == 0.0);
        l.open();
        assert_eq!(l.r.p.open_item_lanes(), &BTreeSet::from([l.graphic]));
        assert_eq!(l.row().lane_space, 2.0 * ItemLaneMetrics::LANE_HEIGHT);
        l.open();
        assert!(l.r.p.open_item_lanes().is_empty() && l.row().lane_space == 0.0);
    }

    #[test]
    fn bar_move_is_one_undo_step_and_selects_the_item() {
        let mut l = Lanes::new();
        l.open();
        let top = l.layers()[1].id;
        let y = l.lane_y(0);
        let start = l.x(Time::new(5, 1)); // middle of "top"'s bar (2 s...4 s in the clip)
        l.r.down(start, y);
        assert_eq!(*l.r.picked.borrow(), Some((l.graphic, BTreeSet::from([top]))));
        assert_eq!(l.r.s.selection(), &BTreeSet::from([l.graphic]));
        assert_eq!(l.r.p.item_selection().1, &BTreeSet::from([top]));
        let to = l.x(Time::new(8, 1));
        l.r.drag((start + to) / 2.0, y);
        l.r.drag(to, y);
        l.r.up(to, y);
        let moved = l.layers()[1].range.expect("range");
        assert_eq!(moved.duration, Time::new(2, 1));
        assert!(moved.start > Time::new(2, 1));
        assert!(l.r.s.undo());
        l.r.sync();
        assert_eq!(l.layers()[1].range, Some(TimeRange::new(Time::new(2, 1), Time::new(2, 1))));
    }

    #[test]
    fn escape_during_a_bar_drag_puts_the_range_back() {
        let mut l = Lanes::new();
        l.open();
        let y = l.lane_y(0);
        let start = l.x(Time::new(5, 1));
        l.r.down(start, y);
        l.r.drag(l.x(Time::new(8, 1)), y);
        let original = Some(TimeRange::new(Time::new(2, 1), Time::new(2, 1)));
        assert_ne!(l.layers()[1].range, original);
        l.r.key(InputKey::Escape, InputModifiers::NONE);
        assert_eq!(l.layers()[1].range, original);
        assert!(!l.r.p.is_dragging());
    }

    #[test]
    fn a_bar_drag_keeps_a_rename_the_session_got_meanwhile() {
        let mut l = Lanes::new();
        l.open();
        let (y, start) = (l.lane_y(0), l.x(Time::new(5, 1)));
        l.r.down(start, y);
        l.r.s.rename_selected_clip("renamed"); // no panel sync in between: the panel's copy still has the old name
        let to = l.x(Time::new(8, 1));
        l.r.drag((start + to) / 2.0, y);
        l.r.drag(to, y);
        l.r.up(to, y);
        assert_eq!(l.clip().name, "renamed", "the drag must not put the old name back");
        assert!(l.layers()[1].range.is_some_and(|r| r.start > Time::new(2, 1)), "and the bar still moved");
        assert!(l.r.s.undo());
        l.r.sync();
        assert_eq!(l.clip().name, "renamed", "one Undo reverts only the bar");
        assert_eq!(l.layers()[1].range, Some(TimeRange::new(Time::new(2, 1), Time::new(2, 1))));
    }

    #[test]
    fn escape_during_a_bar_drag_keeps_a_meanwhile_rename() {
        let mut l = Lanes::new();
        l.open();
        let (y, start) = (l.lane_y(0), l.x(Time::new(5, 1)));
        l.r.down(start, y);
        l.r.s.rename_selected_clip("renamed");
        l.r.drag(l.x(Time::new(8, 1)), y);
        l.r.key(InputKey::Escape, InputModifiers::NONE);
        assert_eq!(l.clip().name, "renamed");
        assert_eq!(l.layers()[1].range, Some(TimeRange::new(Time::new(2, 1), Time::new(2, 1))));
    }

    #[test]
    fn command_d_duplicates_the_selected_item() {
        let mut l = Lanes::new();
        l.open();
        let (x, y) = (l.x(Time::new(5, 1)), l.lane_y(0));
        l.r.down(x, y);
        l.r.up(x, y);
        assert!(l.r.key(InputKey::Character('d'), InputModifiers::COMMAND).is_some());
        assert_eq!(l.layers().len(), 3);
        assert_eq!(l.row().lane_space, 3.0 * ItemLaneMetrics::LANE_HEIGHT);
        let (_, items) = l.r.p.item_selection();
        assert!(items.len() == 1 && !items.contains(&l.layers()[1].id));
        assert!(l.r.key(InputKey::Character('d'), InputModifiers::NONE).is_none());
    }

    #[test]
    fn lane_name_drag_reorders() {
        let mut l = Lanes::new();
        l.open();
        let x = TimelineGeometry::TOOL_COLUMN_WIDTH + 30.0;
        let low = l.layers()[0].id;
        // "low" is the bottom lane (index 1); drag its name above the top lane.
        l.r.down(x, l.lane_y(1));
        l.r.drag(x, l.lane_y(1) - 10.0);
        l.r.drag(x, l.row().max_y() + 1.0);
        l.r.up(x, l.row().max_y() + 1.0);
        assert_eq!(l.layers().last().map(|g| g.id), Some(low));
    }

    #[test]
    fn lane_name_drag_onto_a_free_track_makes_a_new_graphic() {
        let mut l = Lanes::new();
        l.open();
        let x = TimelineGeometry::TOOL_COLUMN_WIDTH + 30.0;
        let v2 = l.r.p.rows().into_iter().find(|r| r.track == l.tracks[1]).expect("v2");
        let y = v2.y + v2.height / 2.0;
        l.r.down(x, l.lane_y(0));
        l.r.drag(l.x(Time::new(5, 1)), y);
        l.r.up(l.x(Time::new(5, 1)), y);
        let new_clips: Vec<Clip> = l.r.tl().tracks[1].clips().to_vec();
        assert!(new_clips.len() == 1 && new_clips[0].is_graphics());
        assert_eq!(l.layers().len(), 1);
        assert_eq!(l.r.s.selection(), &BTreeSet::from([new_clips[0].id]));
    }

    #[test]
    fn hits_name_the_part_under_the_pointer() {
        let mut l = Lanes::new();
        l.open();
        let bar = l.x(Time::new(4, 1)) + 1.0; // just inside the head of "top" (2 s into the clip)
        assert!(matches!(
            l.r.p.item_lane_hit(pt(bar, l.lane_y(0))),
            Some(ItemLaneHit::Bar { mode: ItemLaneBarMode::Head, .. })
        ));
        assert!(matches!(
            l.r.p.item_lane_hit(pt(TimelineGeometry::TOOL_COLUMN_WIDTH + 30.0, l.lane_y(0))),
            Some(ItemLaneHit::Header { .. })
        ));
    }
}

// MARK: Source patch

mod source_patch {
    use super::*;

    const FD: Time = Time::new(1, 25);

    /// A 1000 x 400 pt panel with V1, V2, A1 and a source with video and audio loaded.
    fn setup() -> Rig {
        let a = Clip::new(uid(10), "a", uid(11), TrackKind::Audio, TimeRange::new(Time::ZERO, FD * 50), Time::ZERO);
        let mut audio = Track::new(uid(3), TrackKind::Audio);
        audio.set_clips(vec![a]);
        let t = Timeline::new(
            uid(9000),
            "t",
            SequenceFormat::new(FD),
            vec![Track::new(uid(1), TrackKind::Video), Track::new(uid(2), TrackKind::Video), audio],
        );
        let mut r = Rig::new(t, 1000.0, 400.0);
        r.p.source_patch_streams = Some(vec![TrackKind::Video, TrackKind::Audio]);
        r
    }

    fn center(p: &TimelinePanel, track: Id) -> CGPoint {
        let row = p.rows().into_iter().find(|r| r.track == track).expect("row");
        let r = TimelinePanel::patch_rect(row.height);
        pt(TimelineGeometry::TOOL_COLUMN_WIDTH + r.mid_x(), row.y + r.mid_y())
    }

    #[test]
    fn chips_sit_on_the_patched_tracks_and_shift_the_target_chip() {
        let mut r = setup();
        let ids: Vec<Id> = r.tl().tracks.iter().map(|t| t.id).collect();
        assert_eq!(r.p.patch_chip(ids[0]).map(|c| c.0), Some(TrackKind::Video)); // V1 by default
        assert_eq!(r.p.patch_chip(ids[2]).map(|c| c.0), Some(TrackKind::Audio));
        assert!(r.p.patch_chip(ids[1]).is_none());
        let row = r.p.rows().into_iter().find(|x| x.track == ids[0]).expect("row");
        assert_eq!(
            r.p.target_chip_rect(row.height).min_x(),
            TimelinePanel::patch_rect(row.height).max_x() + TimelinePanel::PATCH_GAP
        );
        r.p.source_patch_streams = Some(vec![TrackKind::Audio]); // a sound file: no video chip
        assert!(r.p.patch_chip(ids[0]).is_none());
        r.p.source_patch_streams = None; // nothing in the Source view: no column
        assert!(r.p.patch_chip(ids[2]).is_none());
        assert_eq!(r.p.target_chip_rect(row.height), crate::header::TrackHeaderLayout::chip_rect(row.height));
    }

    #[test]
    fn click_toggles_option_solos_and_a_drag_patches_elsewhere() {
        let mut r = setup();
        let ids: Vec<Id> = r.tl().tracks.iter().map(|t| t.id).collect();
        let (v1, v2, a1) = (center(&r.p, ids[0]), center(&r.p, ids[1]), center(&r.p, ids[2]));

        assert!(r.down(v1.x, v1.y).is_empty());
        let click = r.up(v1.x, v1.y);
        assert_eq!(click, vec![TimelineAction::SourcePatchClick { kind: TrackKind::Video, solo: false }]);
        assert!(!r.s.source_patch().video.is_connected);
        assert_eq!(r.p.patch_chip(ids[0]).map(|c| c.1), Some(false)); // off, still shown where it was

        r.send(InputEvent::MouseDown { x: a1.x as f32, y: a1.y as f32, modifiers: InputModifiers::OPTION });
        assert_eq!(r.up(a1.x, a1.y), vec![TimelineAction::SourcePatchClick { kind: TrackKind::Audio, solo: true }]);

        r.send(InputEvent::MouseDown { x: v1.x as f32, y: v1.y as f32, modifiers: InputModifiers::SHIFT });
        r.drag(v2.x, v2.y);
        assert_eq!(r.p.patch_drop_track, Some(ids[1]));
        let moved = r.up(v2.x, v2.y);
        assert_eq!(moved, vec![TimelineAction::SourcePatchMove { kind: TrackKind::Video, to: ids[1], both: true }]);
        assert_eq!(r.p.patch_drop_track, None);
        assert_eq!(r.s.source_patch().video.track, Some(ids[1]));
        assert!(r.s.source_patch().video.is_connected);

        assert_eq!(r.p.patch_chip(ids[1]).map(|c| c.0), Some(TrackKind::Video));
        r.down(v2.x, v2.y);
        r.drag(a1.x, a1.y); // the other kind's row: no target
        assert_eq!(r.p.patch_drop_track, None);
        assert!(r.up(a1.x, a1.y).is_empty());
    }
}

// MARK: Transition layers

mod transition_layer {
    use super::*;
    use sq_core_model::TransitionKind;

    const FD: Time = Time::new(1, 25);

    /// V1 (a clip at 0-100), V2 with a 20-frame cross dissolve layer at frames 40-60 (cut at 50), on a 1000 x 400 pt panel.
    fn setup() -> (Rig, Id) {
        let c = Clip::new(uid(10), "c", uid(11), TrackKind::Video, TimeRange::new(Time::ZERO, FD * 100), Time::ZERO);
        let mut v1 = Track::new(uid(1), TrackKind::Video);
        v1.set_clips(vec![c]);
        let v2 = Track::new(uid(2), TrackKind::Video);
        let v2_id = v2.id;
        let t = Timeline::new(uid(9000), "t", SequenceFormat::new(FD), vec![v1, v2]);
        let mut r = Rig::new(t, 1000.0, 400.0);
        let id =
            r.s.add_transition_layer(TransitionKind::CrossDissolve, v2_id, FD * 40, FD * 20, FD * 50).expect("layer");
        r.p.tool_state_mut().snapping = false;
        r.sync();
        (r, id)
    }

    /// A press-drag-release, applying (and syncing) each step's actions like the host.
    fn drag(r: &mut Rig, a: f64, b: f64, y: f64, m: InputModifiers) -> Vec<TimelineAction> {
        let mut all = r.send(InputEvent::MouseDown { x: a as f32, y: y as f32, modifiers: m });
        for i in 0..=4 {
            let x = a + (b - a) * f64::from(i) / 4.0;
            all.extend(r.drag(x, y));
        }
        all.extend(r.up(b, y));
        all
    }

    fn cut_of(r: &Rig, id: Id) -> Option<Time> {
        r.tl().resolved_transition_layer(id).map(|l| l.cut)
    }

    #[test]
    fn an_adjustment_layer_dragged_over_a_clip_lands_on_the_track_above_and_on_an_empty_spot_in_place() {
        use crate::EffectDrop;
        let (mut r, _) = setup();
        let ids = vec![sq_editor_session::EffectDragPayload::ADJUSTMENT_LAYER_ID.to_string()];
        let five = Time::seconds(5);
        let (v1, v2) = (r.tl().tracks[0].id, r.tl().tracks[1].id);
        let y_of = |r: &Rig, t: Id| {
            let row = r.p.rows().into_iter().find(|x| x.track == t).expect("row");
            row.y + row.height / 2.0
        };
        let x = r.p.geometry.x(FD * 10);
        // Over the V1 clip: the free spot on V2 above.
        let y1 = y_of(&r, v1);
        assert!(r.p.effect_drop_hover(&ids, x as f32, y1 as f32, five));
        let Some(EffectDrop::Layer(l)) = r.p.effect_drop_take() else { panic!("layer target expected") };
        assert_eq!((l.track, l.adjustment), (v2, true));
        // On the empty spot of V2: V2 itself, no longer than the gap before the transition layer at frame 40.
        let y2 = y_of(&r, v2);
        assert!(r.p.effect_drop_hover(&ids, x as f32, y2 as f32, five));
        let Some(EffectDrop::Layer(l)) = r.p.effect_drop_take() else { panic!("layer target expected") };
        assert_eq!(l.track, v2);
        assert!(l.start + l.duration <= FD * 40);
    }

    #[test]
    fn the_cut_marker_moves_the_cut_as_one_undo_step() {
        let (mut r, id) = setup();
        let row = r.p.rows().into_iter().find(|x| x.track == r.tl().tracks[1].id).expect("row");
        let y = row.y + row.height / 2.0;
        let cx = r.p.geometry.x(FD * 50);
        r.s.select(BTreeSet::new(), BTreeSet::new());
        r.sync();
        let to = r.p.geometry.x(FD * 54); // 4 frames later
        let acts = drag(&mut r, cx, to, y, InputModifiers::NONE);
        assert_eq!(
            acts.first(),
            Some(&TimelineAction::Select { clips: BTreeSet::from([id]), captions: BTreeSet::new() })
        );
        assert_eq!(cut_of(&r, id), Some(FD * 54));
        r.s.undo();
        assert_eq!(cut_of(&r, id), Some(FD * 50));
    }

    #[test]
    fn an_end_resizes_symmetrically_and_alt_moves_only_that_end() {
        let (mut r, id) = setup();
        let row = r.p.rows().into_iter().find(|x| x.track == r.tl().tracks[1].id).expect("row");
        let y = row.y + row.height / 2.0;
        let tail = r.p.geometry.x(FD * 60) - 1.0;
        let out = r.p.geometry.x(FD * 63) - 1.0;
        drag(&mut r, tail, out, y, InputModifiers::NONE); // 3 frames out on both sides
        let l = r.tl().resolved_transition_layer(id).expect("layer");
        assert_eq!(l.span, TimeRange::new(FD * 37, FD * 26));
        r.s.undo();
        r.sync();
        r.p.last_click = None; // a new press, not a double-click
        drag(&mut r, tail, out, y, InputModifiers::OPTION);
        let one = r.tl().resolved_transition_layer(id).expect("layer");
        assert_eq!(one.span, TimeRange::new(FD * 40, FD * 23));
    }
}

fn draw_count(p: &mut TimelinePanel, w: f32, h: f32) -> usize {
    let mut cv = sq_draw::Canvas::with_size(w, h, None, 1.0);
    p.draw_timeline(&mut cv);
    cv.list.quads().len()
}

fn clip_of(r: &Rig, track: usize) -> Clip {
    r.tl().tracks[track].clips()[0].clone()
}

// MARK: Bands

mod bands {
    use super::*;
    use sq_core_model::SpeedKeys;
    use sq_core_model::fades_curve::FadeCurve;
    use sq_editor_session::{SpeedBand, SpeedEditPhase};
    use sq_timeline_ui::{ClipBodyMetrics, OpacityLine, VolumeLine};

    const FD: Time = Time::new(1, 25);

    fn clip100(n: u128, kind: TrackKind) -> Clip {
        Clip::new(uid(n), "c", uid(n + 500), kind, TimeRange::new(Time::ZERO, FD * 100), Time::ZERO)
    }

    /// V1 with one 100-frame clip, A1 with one; a 1000 x 400 pt panel synced to the session.
    pub(super) fn setup() -> Rig {
        let mut v = Track::new(uid(1), TrackKind::Video);
        v.set_clips(vec![clip100(10, TrackKind::Video)]);
        let mut a = Track::new(uid(2), TrackKind::Audio);
        a.set_clips(vec![clip100(11, TrackKind::Audio)]);
        Rig::new(Timeline::new(uid(9000), "t", SequenceFormat::new(FD), vec![v, a]), 1000.0, 400.0)
    }

    /// The clip on track `i` and its drawn rectangle.
    pub(super) fn target(r: &Rig, i: usize) -> (Clip, CGRect) {
        let tr = &r.tl().tracks[i];
        let c = tr.clips()[0].clone();
        let row = r.p.rows().into_iter().find(|x| x.track == tr.id).expect("row");
        let (x0, x1) = (r.p.geometry.x(c.start), r.p.geometry.x(c.timeline().end()));
        (c, CGRect::new(x0, row.y, x1 - x0, row.height))
    }

    #[test]
    fn volume_line_drag_is_one_undo_step() {
        let mut r = setup();
        let (c, rect) = target(&r, 1);
        assert!(VolumeLine::is_available(rect.height));
        let lane = VolumeLine::lane(&rect);
        let (x, y) = (rect.mid_x().round(), VolumeLine::y_for_db(0.0, &lane).round());
        let a = r.down(x, y);
        assert_eq!(
            a.first(),
            Some(&TimelineAction::Select { clips: BTreeSet::from([c.id]), captions: BTreeSet::new() })
        );
        assert!(r.p.is_dragging());
        r.drag(x, y + 10.0);
        let last = r.up(x, y + 20.0);
        assert_eq!(last.last(), Some(&TimelineAction::EndGesture));
        let after = clip_of(&r, 1);
        assert!(after.animation.volume.value_at_local(Time::ZERO) < 0.9); // the line went down
        r.s.undo();
        r.sync();
        assert_eq!(
            clip_of(&r, 1).animation.volume.value_at_local(Time::ZERO),
            c.animation.volume.value_at_local(Time::ZERO)
        ); // one step back to the start
    }

    #[test]
    fn esc_during_band_drag_puts_the_session_back() {
        let mut r = setup();
        let (c, rect) = target(&r, 1);
        let lane = VolumeLine::lane(&rect);
        let (x, y) = (rect.mid_x().round(), VolumeLine::y_for_db(0.0, &lane).round());
        r.down(x, y);
        r.drag(x, y + 20.0);
        assert_ne!(clip_of(&r, 1), c); // the drag reached the session
        let esc = r.key(InputKey::Escape, InputModifiers::NONE).unwrap_or_default();
        assert_eq!(esc.last(), Some(&TimelineAction::EndGesture));
        assert!(!r.p.is_dragging());
        assert_eq!(clip_of(&r, 1), c); // back to the start
        assert!(!r.s.can_undo()); // and no empty step left behind
    }

    fn volume_at_start(c: &Clip) -> f64 {
        c.animation.volume.value_at_local(Time::ZERO)
    }

    /// Presses the volume band of the audio clip; another panel renames the clip in the session before the first step.
    fn press_then_rename(r: &mut Rig, rect: &CGRect) -> (f64, f64) {
        let lane = VolumeLine::lane(rect);
        let (x, y) = (rect.mid_x().round(), VolumeLine::y_for_db(0.0, &lane).round());
        r.down(x, y);
        r.s.rename_selected_clip("renamed"); // no panel sync in between: the panel's copy still has the old name
        (x, y)
    }

    #[test]
    fn a_band_drag_keeps_a_rename_the_session_got_meanwhile() {
        let mut r = setup();
        let (c, rect) = target(&r, 1);
        let (x, y) = press_then_rename(&mut r, &rect);
        r.drag(x, y + 10.0);
        r.drag(x, y + 20.0);
        r.up(x, y + 20.0);
        let after = clip_of(&r, 1);
        assert_eq!(after.name, "renamed", "the drag must not put the old name back");
        assert!(volume_at_start(&after) < 0.9, "and the line still went down");
        r.s.undo();
        r.sync();
        let undone = clip_of(&r, 1);
        assert_eq!((undone.name.as_str(), volume_at_start(&undone)), ("renamed", volume_at_start(&c)));
        r.s.undo();
        r.sync();
        assert_eq!(clip_of(&r, 1).name, c.name); // the second step is the rename
    }

    #[test]
    fn esc_during_a_band_drag_restores_the_volume_and_keeps_a_meanwhile_rename() {
        let mut r = setup();
        let (c, rect) = target(&r, 1);
        let (x, y) = press_then_rename(&mut r, &rect);
        r.drag(x, y + 20.0);
        assert!(volume_at_start(&clip_of(&r, 1)) < 0.9);
        r.key(InputKey::Escape, InputModifiers::NONE);
        let back = clip_of(&r, 1);
        assert_eq!((back.name.as_str(), volume_at_start(&back)), ("renamed", volume_at_start(&c)));
        r.s.undo();
        r.sync();
        assert_eq!(clip_of(&r, 1).name, c.name, "no step of the drag is left: the one Undo is the rename");
    }

    #[test]
    fn fade_handle_drag_and_its_menu() {
        let mut r = setup();
        let (c, rect) = target(&r, 1);
        let h = VolumeLine::fade_handle_points(&c, &rect).0;
        assert_eq!(r.p.fade_handle_hit(h).map(|f| f.1), Some(sq_timeline_ui::FadeHandle::Head));
        let out = crate::timeline_menus::new_outbox();
        let mut host = TimelineHost::new();
        let items = crate::timeline_menus::TimelineMenus::items(
            h,
            &mut r.p,
            &mut r.s,
            &mut host,
            &sq_uikit::command_map::CommandMap::current(),
            &out,
        )
        .unwrap_or_default();
        assert_eq!(
            items.iter().map(|i| i.title.clone()).collect::<Vec<_>>(),
            FadeCurve::ALL.iter().map(|c| c.title().to_string()).collect::<Vec<_>>()
        );
        r.sync();
        r.down(h.x, h.y);
        r.drag(h.x + 100.0, h.y);
        assert_eq!(r.up(h.x + 100.0, h.y).last(), Some(&TimelineAction::EndGesture));
        assert!(clip_of(&r, 1).audio_fade_in() > Time::ZERO);
    }

    #[test]
    fn fade_drag_keeps_the_left_right_cursor_and_line_drag_the_up_down_one() {
        let mut r = setup();
        let (c, rect) = target(&r, 1);
        let h = VolumeLine::fade_handle_points(&c, &rect).0;
        r.down(h.x, h.y);
        assert_eq!(
            r.p.cursor_at(h.x as f32, h.y as f32, InputModifiers::NONE),
            Some(sq_draw::ui_cx::DrawCursor::ResizeLeftRight)
        );
        r.up(h.x, h.y);
        let lane = VolumeLine::lane(&rect);
        let (x, y) = (rect.mid_x().round(), VolumeLine::y_for_db(0.0, &lane).round());
        r.down(x, y);
        assert_eq!(
            r.p.cursor_at(x as f32, y as f32, InputModifiers::NONE),
            Some(sq_draw::ui_cx::DrawCursor::ResizeUpDown)
        );
    }

    #[test]
    fn opacity_line_shows_off_full_and_drags() {
        let mut r = setup();
        let (mut c, rect) = target(&r, 0);
        let lane = OpacityLine::lane(&rect);
        let full = pt(rect.mid_x().round(), OpacityLine::y_for_opacity(1.0, &lane).round());
        r.send(InputEvent::MouseDown { x: full.x as f32, y: full.y as f32, modifiers: InputModifiers::COMMAND });
        assert!(
            !matches!(r.p.gesture, Some(crate::panel::Gesture::Band(_))),
            "a plain 100 % clip shows no line to take"
        );
        r.up(full.x, full.y);
        c.animation.opacity.value = 0.5;
        r.s.replace_clip(&c, "Opacity", false);
        r.sync();
        let half = pt(rect.mid_x().round(), OpacityLine::y_for_opacity(0.5, &lane).round());
        r.down(half.x, half.y);
        assert!(matches!(r.p.gesture, Some(crate::panel::Gesture::Band(_))), "the 50 % line missed the press");
        r.drag(half.x, half.y + 8.0);
        assert_eq!(r.up(half.x, half.y + 8.0).last(), Some(&TimelineAction::EndGesture));
        assert!(clip_of(&r, 0).animation.opacity.value < 0.5);
    }

    fn speed_point(r: &mut Rig) -> (Clip, CGPoint) {
        let (c, rect) = target(r, 0);
        r.p.speed_band_clips = BTreeSet::from([c.id]);
        let lane = ClipBodyMetrics::waveform_rect(&rect);
        let g = r.p.geometry.clone();
        let pts = SpeedBand::line_points(&SpeedKeys::of(&c), c.start, lane, |t| g.x(t));
        (c, pt(rect.mid_x().round(), pts[0].y.round()))
    }

    #[test]
    fn speed_band_drag_and_menus() {
        let mut r = setup();
        let (c, p) = speed_point(&mut r);
        assert_eq!(r.p.speed_segment_clip(p), Some(c.id));
        let out = crate::timeline_menus::new_outbox();
        let mut host = TimelineHost::new();
        let items = crate::timeline_menus::TimelineMenus::items(
            p,
            &mut r.p,
            &mut r.s,
            &mut host,
            &sq_uikit::command_map::CommandMap::current(),
            &out,
        )
        .unwrap_or_default();
        assert_eq!(items.iter().map(|i| i.title.as_str()).collect::<Vec<_>>(), vec!["Add Speed Point"]);
        assert!(draw_count(&mut r.p, 1000.0, 400.0) > 0);
        let a = r.down(p.x, p.y);
        assert!(matches!(a.last(), Some(TimelineAction::SpeedEdit { phase: SpeedEditPhase::Began, .. })));
        r.drag(p.x, p.y - 15.0);
        let end = r.up(p.x, p.y - 15.0);
        assert!(matches!(end.last(), Some(TimelineAction::SpeedEdit { phase: SpeedEditPhase::Ended, .. })));
        assert!(clip_of(&r, 0).duration() < c.duration()); // dragged up: faster, so shorter
    }

    #[test]
    fn esc_during_speed_band_drag_puts_the_session_back() {
        let mut r = setup();
        let start = r.tl().clone();
        let (c, p) = speed_point(&mut r);
        r.down(p.x, p.y);
        let depth = r.s.undo_depth();
        r.drag(p.x, p.y - 15.0);
        assert!(clip_of(&r, 0).duration() < c.duration()); // the drag reached the session
        r.key(InputKey::Escape, InputModifiers::NONE);
        assert!(!r.p.is_dragging());
        let clips = |t: &Timeline| t.tracks.iter().map(|x| x.clips().to_vec()).collect::<Vec<_>>();
        assert_eq!(clips(r.tl()), clips(&start)); // back to the start
        assert_eq!(r.s.undo_depth(), depth); // and no step left behind
        assert_eq!(r.p.timeline.tracks[0].clips()[0].duration(), c.duration());
    }

    struct FakeKeyLanes {
        time: Time,
        drawn: RefCell<Vec<Id>>,
    }

    impl crate::lanes::TimelineKeyLaneSource for FakeKeyLanes {
        fn key_lane(
            &self,
            clip: &Clip,
            clip_rect: CGRect,
            _visible: CGRect,
            selected: bool,
            geometry: &TimelineGeometry,
        ) -> Option<crate::lanes::TimelineKeyLane> {
            if !selected {
                return None;
            }
            self.drawn.borrow_mut().push(clip.id);
            let lane = CGRect::new(clip_rect.min_x(), clip_rect.max_y() - 11.0, clip_rect.width, 10.0);
            Some(crate::lanes::TimelineKeyLane {
                lane,
                glyphs: vec![crate::lanes::KeyLaneGlyph {
                    center: pt(geometry.x(self.time), lane.mid_y()),
                    selected: false,
                }],
                glyph_size: 7.0,
            })
        }
        fn key_lane_hit(
            &self,
            _clip: &Clip,
            clip_rect: CGRect,
            p: CGPoint,
            geometry: &TimelineGeometry,
        ) -> Option<Time> {
            ((geometry.x(self.time) - p.x).abs() <= 5.5 && p.y >= clip_rect.max_y() - 13.0).then_some(self.time)
        }
    }

    #[test]
    fn key_lane_press_picks_the_key_through_the_host() {
        let mut r = setup();
        let (c, rect) = target(&r, 0);
        let lanes = Rc::new(FakeKeyLanes { time: c.start + FD * 50, drawn: RefCell::new(Vec::new()) });
        r.p.key_lanes = Some(Rc::clone(&lanes) as Rc<dyn crate::lanes::TimelineKeyLaneSource>);
        r.s.select(BTreeSet::from([c.id]), BTreeSet::new());
        r.sync();
        draw_count(&mut r.p, 1000.0, 400.0);
        assert_eq!(*lanes.drawn.borrow(), vec![c.id]);
        let p = pt(r.p.geometry.x(c.start + FD * 50), rect.max_y() - 6.0);
        let a = r.send(InputEvent::MouseDown { x: p.x as f32, y: p.y as f32, modifiers: InputModifiers::SHIFT });
        assert_eq!(a, vec![TimelineAction::KeyLaneClick { clip: c.id, time: c.start + FD * 50, extend: true }]);
        let asked = Rc::new(RefCell::new(None));
        let hook = Rc::clone(&asked);
        r.host.open = Some(Box::new(move |req| {
            *hook.borrow_mut() = Some(req.clone());
            true
        }));
        assert_eq!(session_bridge::apply(a[0].clone(), &mut r.s, &mut r.host, None), None);
        assert_eq!(
            *asked.borrow(),
            Some(crate::host::TimelineEditorRequest::KeyLaneKey { clip: c.id, time: c.start + FD * 50, extend: true })
        );
    }
}

// MARK: Fast Cut

mod fast_cut {
    use super::*;
    use sq_core_model::ClipAttachment;
    use sq_timeline_ui::AttachPointDrag;

    const FD: Time = Time::new(1, 25);

    fn vclip(n: u128, start: i64, frames: i64) -> Clip {
        Clip::new(uid(n), "c", uid(n + 500), TrackKind::Video, TimeRange::new(Time::ZERO, FD * frames), FD * start)
    }

    /// Fast Cut: V1 host (0...100), V2 title attached to it at its own start (20...60).
    fn setup() -> (Rig, Id, Id) {
        let host = vclip(10, 0, 100);
        let mut title = vclip(11, 20, 40);
        title.attachment = Some(ClipAttachment::new(host.id, Time::ZERO));
        let (hid, tid) = (host.id, title.id);
        let mut v1 = Track::new(uid(1), TrackKind::Video);
        v1.set_clips(vec![host]);
        let mut v2 = Track::new(uid(2), TrackKind::Video);
        v2.set_clips(vec![title]);
        let mut t = Timeline::new(uid(9000), "t", SequenceFormat::new(FD), vec![v1, v2]);
        t.edit_mode_store = Some(sq_core_model::TimelineEditMode::Magnetic);
        (Rig::new(t, 1000.0, 400.0), hid, tid)
    }

    #[test]
    fn attach_thread_drag_sets_the_attach_point_as_one_undo_step() {
        let (mut r, _, title) = setup();
        let tl = r.p.timeline.clone();
        let row = r.p.rows().into_iter().find(|x| x.track == tl.tracks[1].id).expect("row");
        let x = r.p.geometry.x(FD * 20);
        // The thread's grab zone (the Mac `AttachPointDrag.hit`), then a drag 10 frames right.
        let zone: Vec<f64> = (0..(row.height as i64 + 8))
            .map(|i| row.y + i as f64)
            .filter(|y| AttachPointDrag::hit(pt(x, *y), &tl, &r.p.geometry) == Some(title))
            .collect();
        // The middle of the grab zone, which reaches 6 pt into the host row (a press on the title's own head would trim it).
        let y = *zone.get(zone.len() / 2).expect("a grab point");
        r.p.handle(&InputEvent::MouseDown { x: x as f32, y: y as f32, modifiers: InputModifiers::NONE }, &mut r.ui);
        assert!(r.p.is_dragging());
        let x2 = r.p.geometry.x(FD * 30);
        r.p.handle(&InputEvent::dragged(x2 as f32, y as f32), &mut r.ui);
        let a = r.p.handle(&InputEvent::MouseUp { x: x2 as f32, y: y as f32 }, &mut r.ui);
        let Some(TimelineAction::SetAttachPoint { clip, time }) = a.first().cloned() else {
            panic!(
                "no attach action: {:?}",
                a.iter().map(|x| format!("{x:?}").chars().take(40).collect::<String>()).collect::<Vec<_>>()
            )
        };
        assert_eq!(clip, title);
        assert_eq!(
            session_bridge::apply(a[0].clone(), &mut r.s, &mut r.host, None),
            Some("Attach point set.".to_string())
        );
        assert_eq!(r.tl().tracks[1].clips()[0].attachment.as_ref().map(|a| a.point), Some(time - FD * 20));
        r.s.undo();
        assert_eq!(r.tl().tracks[1].clips()[0].attachment.as_ref().map(|a| a.point), Some(Time::ZERO));
    }

    #[test]
    fn command_option_click_sets_the_attach_point_at_the_click() {
        let (mut r, _, title) = setup();
        let row = r.p.rows().into_iter().find(|x| x.track == r.p.timeline.tracks[1].id).expect("row");
        let x = r.p.geometry.x(FD * 45);
        let a = r.send(InputEvent::MouseDown {
            x: x as f32,
            y: (row.y + row.height / 2.0) as f32,
            modifiers: InputModifiers::COMMAND | InputModifiers::OPTION,
        });
        assert!(a.contains(&TimelineAction::SetAttachPoint { clip: title, time: r.p.geometry.time(x) }));
    }

    #[test]
    fn fast_cut_marks_and_overlays_draw() {
        let (mut r, host, title) = setup();
        let empty = draw_count(&mut r.p, 1000.0, 400.0);
        r.s.select(BTreeSet::from([title]), BTreeSet::new());
        r.sync();
        r.p.grade_outline = BTreeSet::from([host]);
        r.p.analysis_progress.insert(host, 0.5);
        let marked = draw_count(&mut r.p, 1000.0, 400.0);
        // Host tint and bracket, grade outline and progress strip add geometry.
        assert!(marked > empty);
    }

    #[test]
    fn show_time_remapping_toggles_the_band_on_the_selection() {
        let (mut r, host, _) = setup();
        let c = sq_uikit::editor_command::EditorCommand::ToggleTimeRemapping;
        assert_eq!(r.p.run_speed_command(&c, &mut r.s), Some("Select a video clip first.".to_string()));
        r.s.select(BTreeSet::from([host]), BTreeSet::new());
        assert_eq!(r.p.run_speed_command(&c, &mut r.s), Some(String::new()));
        assert_eq!(r.p.speed_band_clips, BTreeSet::from([host]));
        assert_eq!(r.p.run_speed_command(&c, &mut r.s), Some(String::new()));
        assert!(r.p.speed_band_clips.is_empty());
        assert_eq!(r.p.run_speed_command(&sq_uikit::editor_command::EditorCommand::PlayPause, &mut r.s), None);
    }
}

// MARK: Keystones

mod keystones {
    use super::*;
    use sq_core_effects::keystone::Keystone;
    use sq_core_effects::keystone::KeystoneSpan;
    use sq_timeline_ui::{KeystoneBar, KeystoneDrag, KeystoneEdge};

    const FD: Time = Time::new(1, 25);

    /// V1 with one 100-frame clip, A1 below; a 1000 x 400 pt panel synced to the session.
    fn rig() -> Rig {
        let v = Clip::new(uid(10), "v", uid(11), TrackKind::Video, TimeRange::new(Time::ZERO, FD * 100), Time::ZERO);
        let a = Clip::new(uid(12), "a", uid(13), TrackKind::Audio, TimeRange::new(Time::ZERO, FD * 100), Time::ZERO);
        let mut vt = Track::new(uid(1), TrackKind::Video);
        vt.set_clips(vec![v]);
        let mut at = Track::new(uid(2), TrackKind::Audio);
        at.set_clips(vec![a]);
        Rig::new(Timeline::new(uid(9000), "t", SequenceFormat::new(FD), vec![vt, at]), 1000.0, 400.0)
    }

    fn row_of(r: &Rig) -> sq_timeline_ui::TrackRow {
        r.p.rows().into_iter().find(|x| x.track == r.tl().tracks[0].id).expect("row")
    }

    fn punch_in() -> Keystone {
        Keystone::built_in_named("Punch In").expect("built in")
    }

    #[test]
    fn payload_string_round_trips() {
        let k = punch_in();
        let s = KeystoneDrag::string(&k).expect("string");
        assert_eq!(KeystoneDrag::keystone(&s), Some(k));
        assert_eq!(KeystoneDrag::keystone("not a keystone"), None);
    }

    #[test]
    fn bar_edges_stay_inside_the_clip() {
        let span = KeystoneSpan { start: FD * 10, duration: FD * 10, properties: BTreeSet::new() };
        let end = KeystoneBar::dragged(&span, KeystoneEdge::End, FD * 200, FD * 100, FD);
        assert!(end.start == FD * 10 && end.end() == FD * 100);
        let start = KeystoneBar::dragged(&span, KeystoneEdge::Start, FD * 30, FD * 100, FD);
        assert!(start.start == FD * 19 && start.end() == FD * 20);
        let r = CGRect::new(100.0, 50.0, 80.0, 12.0);
        assert_eq!(KeystoneBar::edge(pt(103.0, 55.0), &r), Some(KeystoneEdge::Start));
        assert_eq!(KeystoneBar::edge(pt(178.0, 55.0), &r), Some(KeystoneEdge::End));
        assert_eq!(KeystoneBar::edge(pt(140.0, 55.0), &r), None);
    }

    #[test]
    fn drop_shows_the_ghost_then_applies_with_the_bar() {
        let mut r = rig();
        let row = row_of(&r);
        let (x, y) = (r.p.geometry.x(FD * 50) as f32, (row.y + row.height / 2.0) as f32);
        let k = punch_in();
        assert!(r.p.keystone_hover(&k, x, y));
        let ghost = r.p.keystone_ghost.clone().expect("ghost");
        assert!(ghost.clip == clip_of(&r, 0).id && ghost.span.duration > Time::ZERO);
        // Off the clips (the audio row, empty space) there is no target; leaving drops the ghost.
        assert!(!r.p.keystone_hover(&k, r.p.geometry.x(FD * 150) as f32, y));
        assert!(r.p.keystone_ghost.is_none());
        let actions = r.p.keystone_drop(&k, x, y);
        assert_eq!(
            actions,
            vec![TimelineAction::DropKeystone { keystone: Box::new(k), clip: clip_of(&r, 0).id, span: ghost.span }]
        );
        assert!(r.p.keystone_ghost.is_none());
        assert!(r.run(actions).is_empty());
        assert!(clip_of(&r, 0).animation.scale.track.keys.len() >= 2);
        assert_eq!(
            r.p.keystone_bar.as_ref().map(|b| (b.clip, b.name.clone())),
            Some((clip_of(&r, 0).id, "Punch In".to_string()))
        );
    }

    #[test]
    fn bar_edge_drag_restretches_in_one_undo_step() {
        let mut r = rig();
        let row = row_of(&r);
        let y = (row.y + row.height / 2.0) as f32;
        let drop = r.p.keystone_drop(&punch_in(), r.p.geometry.x(FD * 20) as f32, y);
        r.run(drop);
        let bar = r.p.keystone_bar.clone().expect("bar");
        assert!(row.height >= KeystoneBar::MINIMUM_ROW_HEIGHT);
        let rect = KeystoneBar::rect(&bar.span, clip_of(&r, 0).start, &row, &r.p.geometry);
        let keys_before: Vec<Time> = clip_of(&r, 0).animation.scale.track.keys.iter().map(|k| k.time).collect();
        let undo_before = r.s.can_undo();
        let mut out = r.p.handle(
            &InputEvent::MouseDown { x: rect.max_x() as f32, y: rect.mid_y() as f32, modifiers: InputModifiers::NONE },
            &mut r.ui,
        );
        assert!(out.is_empty() && r.p.is_dragging());
        let to = r.p.geometry.x(clip_of(&r, 0).start + bar.span.end() + FD * 20) as f32;
        out.extend(r.p.handle(&InputEvent::dragged(to, rect.mid_y() as f32), &mut r.ui));
        assert!(r.p.keystone_bar.as_ref().is_some_and(|b| b.span.end() > bar.span.end())); // the preview follows live
        out.extend(r.p.handle(&InputEvent::MouseUp { x: to, y: rect.mid_y() as f32 }, &mut r.ui));
        let Some(TimelineAction::RestretchKeystone { clip, from, to: new, .. }) = out.last().cloned() else {
            panic!("no restretch: {out:?}")
        };
        assert!(clip == clip_of(&r, 0).id && from == bar.span && new.end() > bar.span.end());
        assert!(r.run(out).is_empty());
        assert_eq!(r.p.keystone_bar.as_ref().map(|b| b.span.clone()), Some(new));
        let keys_now: Vec<Time> = clip_of(&r, 0).animation.scale.track.keys.iter().map(|k| k.time).collect();
        assert_ne!(keys_now, keys_before);
        assert!(undo_before && r.s.undo());
        r.sync();
        let keys_undone: Vec<Time> = clip_of(&r, 0).animation.scale.track.keys.iter().map(|k| k.time).collect();
        assert_eq!(keys_undone, keys_before);
        assert!(r.p.keystone_bar.is_none()); // undo changed its clip: the bar goes
    }

    #[test]
    fn draws_the_bar_and_the_ghost() {
        let mut r = rig();
        let row = row_of(&r);
        let y = (row.y + row.height / 2.0) as f32;
        let bare = draw_count(&mut r.p, 1000.0, 400.0);
        let drop = r.p.keystone_drop(&punch_in(), r.p.geometry.x(FD * 20) as f32, y);
        r.run(drop);
        r.p.keystone_hover(&punch_in(), r.p.geometry.x(FD * 60) as f32, y);
        assert!(draw_count(&mut r.p, 1000.0, 400.0) > bare);
    }
}

// MARK: Captions

mod captions {
    use super::*;
    use crate::captions::Part;
    use sq_core_model::{CaptionItem, CaptionTrack, CaptionWord};
    use sq_timeline_ui::{CaptionWordLayout, CaptionWordRef};

    const FD: Time = Time::new(1, 25);

    pub(super) fn caption_item(lines: &[&str], range: TimeRange, words: Vec<CaptionWord>, n: u128) -> CaptionItem {
        serde_json::from_value(serde_json::json!({
            "id": uid(n).to_string(),
            "lines": lines,
            "range": serde_json::to_value(range).expect("range"),
            "words": serde_json::to_value(words).expect("words"),
        }))
        .expect("caption item")
    }

    pub(super) fn caption_track(items: Vec<CaptionItem>) -> CaptionTrack {
        serde_json::from_value(serde_json::json!({
            "id": uid(40).to_string(),
            "name": "Subtitles",
            "items": serde_json::to_value(items).expect("items"),
        }))
        .expect("caption track")
    }

    fn word(text: &str, start: i64, frames: i64) -> CaptionWord {
        CaptionWord { text: text.to_string(), range: TimeRange::new(FD * start, FD * frames), confidence: None }
    }

    /// V1 with one clip and one caption track with two captions (the second with word timings).
    fn setup() -> Rig {
        let items = vec![
            caption_item(&["First line"], TimeRange::new(Time::ZERO, FD * 50), Vec::new(), 41),
            caption_item(
                &["Hello there"],
                TimeRange::new(FD * 60, FD * 25),
                vec![word("Hello", 0, 12), word("there", 13, 12)],
                42,
            ),
        ];
        let c = Clip::new(uid(10), "c", uid(11), TrackKind::Video, TimeRange::new(Time::ZERO, FD * 100), Time::ZERO);
        let mut v = Track::new(uid(1), TrackKind::Video);
        v.set_clips(vec![c]);
        let mut t = Timeline::new(uid(9000), "t", SequenceFormat::new(FD), vec![v]);
        t.caption_tracks = vec![caption_track(items)];
        Rig::new(t, 1000.0, 400.0)
    }

    fn type_chars(r: &mut Rig, text: &str) {
        for ch in text.chars() {
            r.ui.typed_text = Some(ch.to_string());
            r.key(InputKey::Character(ch), InputModifiers::NONE);
        }
        r.ui.typed_text = None;
    }

    fn items(r: &Rig) -> Vec<sq_core_model::CaptionItem> {
        r.tl().caption_tracks[0].items().to_vec()
    }

    #[test]
    fn caption_lane_and_header_draw() {
        let mut r = setup();
        let row = r.p.geometry.caption_rows(&r.p.timeline)[0].clone();
        assert_eq!(row.label, "C1");
        assert!(draw_count(&mut r.p, 1000.0, 400.0) > 0);
        assert!(TimelinePanel::caption_eye_rect(&row).max_x() <= TimelineGeometry::CONTENT_ORIGIN_X);
    }

    #[test]
    fn eye_press_toggles_the_track_as_one_undo_step() {
        let mut r = setup();
        let row = r.p.geometry.caption_rows(&r.p.timeline)[0].clone();
        let e = TimelinePanel::caption_eye_rect(&row);
        let a = r.p.handle(
            &InputEvent::MouseDown { x: e.mid_x() as f32, y: e.mid_y() as f32, modifiers: InputModifiers::NONE },
            &mut r.ui,
        );
        assert_eq!(a, vec![TimelineAction::ToggleCaptionTrackVisibility(row.track)]);
        r.run(a);
        assert!(!r.tl().caption_tracks[0].is_visible);
        r.s.undo();
        assert!(r.tl().caption_tracks[0].is_visible);
    }

    #[test]
    fn double_click_opens_the_word_field_and_return_types_it() {
        let mut r = setup();
        let row = r.p.geometry.caption_rows(&r.p.timeline)[0].clone();
        let id = items(&r)[0].id;
        // "First line" has no timings: its words are spread over the caption, "line" is the second half.
        let (x, y) = (r.p.geometry.x(FD * 38), row.y + row.height / 2.0);
        r.down(x, y);
        r.up(x, y);
        r.down(x, y);
        assert!(r.p.is_editing_word());
        assert_eq!(r.p.interaction.word_selection(), Some(CaptionWordRef::new(id, 1)));
        assert!(draw_count(&mut r.p, 1000.0, 400.0) > 0); // the field draws over its word
        let depth = r.s.undo_depth();
        type_chars(&mut r, "verse");
        let done = r.key(InputKey::Enter, InputModifiers::NONE).unwrap_or_default();
        assert!(done.iter().any(|a| matches!(a, TimelineAction::Commit(_))));
        assert!(!r.p.is_editing_word());
        assert_eq!(items(&r)[0].tokens(), vec!["First", "verse"]);
        assert_eq!(r.s.undo_depth(), depth + 1);
        r.s.undo();
        assert_eq!(items(&r)[0].tokens(), vec!["First", "line"]);
    }

    #[test]
    fn a_press_inside_the_word_field_places_the_caret_on_the_next_frame_and_the_caret_follows_the_clock() {
        let mut r = setup();
        let first = items(&r)[0].id;
        let a = r.p.begin_word_editing(CaptionWordRef::new(first, 1)).unwrap_or_default();
        r.run(a);
        assert!(r.p.is_editing_word());
        assert!(draw_count(&mut r.p, 1000.0, 400.0) > 0);
        let f = r.p.word_field_frame().expect("field frame");
        // The first press selected the word; a press inside keeps the field open and waits for a frame to measure.
        r.down(f.mid_x(), f.mid_y());
        r.up(f.mid_x(), f.mid_y());
        assert!(r.p.is_editing_word() && r.p.word_field_press_at.is_some());
        assert!(draw_count(&mut r.p, 1000.0, 400.0) > 0);
        assert!(r.p.word_field_press_at.is_none());
        let selected = r.p.word_field.as_ref().and_then(|f| f.control.editor()).is_some_and(|e| e.has_selection());
        assert!(!selected, "a single press places the caret");
        // The clock reaches the field's draw (`ui_now`): two frames half a second apart are both drawn.
        r.p.ui_now = 0.0;
        assert!(draw_count(&mut r.p, 1000.0, 400.0) > 0);
        r.p.ui_now = 0.6;
        assert!(draw_count(&mut r.p, 1000.0, 400.0) > 0);
    }

    #[test]
    fn dragging_inside_the_word_field_selects_from_the_press_to_the_pointer() {
        let mut r = setup();
        let first = items(&r)[0].id;
        let a = r.p.begin_word_editing(CaptionWordRef::new(first, 1)).unwrap_or_default();
        r.run(a);
        assert!(draw_count(&mut r.p, 1000.0, 400.0) > 0);
        let f = r.p.word_field_frame().expect("field frame");
        let selected =
            |r: &Rig| r.p.word_field.as_ref().and_then(|f| f.control.editor()).is_some_and(|e| e.has_selection());
        // The first press opens the editor with the word selected.
        r.down(f.mid_x(), f.mid_y());
        r.up(f.mid_x(), f.mid_y());
        assert!(draw_count(&mut r.p, 1000.0, 400.0) > 0);
        // Press at the left: the next frame places the caret there (no selection); then drag to the right.
        r.p.last_click = None; // a field this narrow would count the second press as a double click
        r.down(f.min_x() + 4.0, f.mid_y());
        assert!(draw_count(&mut r.p, 1000.0, 400.0) > 0);
        // Back on the press point the selection is empty again, so the pointer (not the press) decides it.
        r.drag(f.min_x() + 4.0, f.mid_y());
        assert!(draw_count(&mut r.p, 1000.0, 400.0) > 0);
        assert!(!selected(&r), "dragging back to the press leaves only the caret");
        r.drag(f.max_x() - 4.0, f.mid_y());
        assert!(r.p.word_field_drag.is_some());
        assert!(draw_count(&mut r.p, 1000.0, 400.0) > 0);
        assert!(selected(&r), "the drag selects");
        r.up(f.max_x() - 4.0, f.mid_y());
        assert!(r.p.word_field_drag.is_none());
        assert!(r.p.is_editing_word());
    }

    #[test]
    fn esc_drops_the_field_tab_moves_on_and_a_press_elsewhere_takes_it() {
        let mut r = setup();
        let (first, second) = (items(&r)[0].id, items(&r)[1].id);
        let a = r.p.begin_word_editing(CaptionWordRef::new(first, 0)).unwrap_or_default();
        r.run(a);
        assert!(r.p.is_editing_word());
        type_chars(&mut r, "Zero");
        r.key(InputKey::Escape, InputModifiers::NONE);
        assert!(!r.p.is_editing_word() && !r.s.can_undo()); // nothing written
        // Tab takes the text and opens the next word, past the caption's end on the next caption.
        let a = r.p.begin_word_editing(CaptionWordRef::new(first, 1)).unwrap_or_default();
        r.run(a);
        type_chars(&mut r, "one");
        r.key(sq_draw::inspector::text_field_control::TAB, InputModifiers::NONE);
        assert_eq!(items(&r)[0].tokens(), vec!["First", "one"]);
        assert!(r.p.is_editing_word());
        assert_eq!(r.p.interaction.word_selection(), Some(CaptionWordRef::new(second, 0)));
        // A press away from the field takes what was typed.
        type_chars(&mut r, "Hi");
        r.down(990.0, 390.0);
        assert!(!r.p.is_editing_word());
        assert_eq!(items(&r)[1].tokens(), vec!["Hi", "there"]);
    }

    #[test]
    fn return_and_delete_act_on_the_selected_word() {
        let mut r = setup();
        let second = items(&r)[1].id;
        let word_ref = CaptionWordRef::new(second, 1);
        let a = r.p.begin_word_editing(word_ref).unwrap_or_default();
        r.run(a);
        r.key(InputKey::Escape, InputModifiers::NONE); // word level, the word selected, no field
        assert!(!r.p.is_editing_word() && r.p.interaction.word_selection() == Some(word_ref));
        r.key(InputKey::Enter, InputModifiers::NONE);
        assert!(r.p.is_editing_word());
        r.key(InputKey::Escape, InputModifiers::NONE);
        r.key(InputKey::Delete, InputModifiers::NONE);
        assert_eq!(items(&r)[1].tokens(), vec!["Hello"]);
        r.s.undo();
        assert_eq!(items(&r)[1].tokens(), vec!["Hello", "there"]);
    }

    #[test]
    fn word_menu_items_sit_above_the_caption_menu() {
        let mut r = setup();
        let second = items(&r)[1].id;
        let a = r.p.begin_word_editing(CaptionWordRef::new(second, 0)).unwrap_or_default();
        r.run(a);
        r.key(InputKey::Escape, InputModifiers::NONE);
        let asked = Rc::new(RefCell::new(Vec::new()));
        let hook = Rc::clone(&asked);
        r.host.open = Some(Box::new(move |req| {
            hook.borrow_mut().push(req.clone());
            true
        }));
        let b =
            CaptionWordLayout::box_of_word(&CaptionWordRef::new(second, 1), &r.p.timeline, &r.p.geometry).expect("box");
        let p = pt(b.mid_x(), b.mid_y());
        let out = crate::timeline_menus::new_outbox();
        let rows = crate::timeline_menus::TimelineMenus::items(
            p,
            &mut r.p,
            &mut r.s,
            &mut r.host,
            &sq_uikit::command_map::CommandMap::current(),
            &out,
        )
        .unwrap_or_default();
        let titles: Vec<&str> = rows.iter().map(|i| i.title.as_str()).collect();
        assert_eq!(titles[..4], ["Edit Word", "Insert Word Before", "Insert Word After", "Delete Word"]);
        assert!(
            titles.contains(&"Join with Previous Caption") && titles.contains(&"Find and Replace in Captions\u{2026}")
        );
        let run = |title: &str, r: &mut Rig, out: &crate::timeline_menus::MenuOutbox| {
            if let Some(a) = rows.iter().find(|i| i.title == title).and_then(|i| i.action.clone()) {
                a();
            }
            let Rig { p, s, host, .. } = r;
            crate::timeline_menus::TimelineMenus::run_all(out, s, host, p);
        };
        run("Split Caption Before This Word", &mut r, &out);
        let tokens: Vec<Vec<String>> = items(&r).iter().map(|i| i.tokens()).collect();
        assert_eq!(tokens, vec![vec!["First", "line"], vec!["Hello"], vec!["there"]]);
        run("Find and Replace in Captions\u{2026}", &mut r, &out);
        assert_eq!(*asked.borrow(), vec![crate::host::TimelineEditorRequest::CaptionFindReplace]);
    }

    #[test]
    fn fast_cut_skimmer_follows_the_pointer_and_ends_on_a_press() {
        let mut r = setup();
        let mut t = r.tl().clone();
        t.edit_mode_store = Some(sq_core_model::TimelineEditMode::Magnetic);
        r.p.sync(SessionView {
            timeline: &t,
            selection: &BTreeSet::new(),
            captions: &BTreeSet::new(),
            playhead: Time::ZERO,
            selected_transition: None,
            labels: LabelResolver::default(),
            line_keys: BTreeSet::new(),
        });
        let row = r.p.rows()[0].clone();
        let (x, y) = (r.p.geometry.x(FD * 40), row.y + row.height / 2.0);
        let moved = |x: f64, y: f64| InputEvent::MouseMoved { x: x as f32, y: y as f32 };
        assert_eq!(r.p.handle(&moved(x, y), &mut r.ui), vec![TimelineAction::Skim(Some(FD * 40))]);
        assert!(r.p.handle(&moved(x, y), &mut r.ui).is_empty()); // same frame: nothing to tell
        draw_count(&mut r.p, 1000.0, 400.0);
        r.p.is_playing = true;
        assert_eq!(r.p.handle(&moved(x + 30.0, y), &mut r.ui), vec![TimelineAction::Skim(None)]); // playback hides it
        r.p.is_playing = false;
        r.p.handle(&moved(x, y), &mut r.ui);
        let press =
            r.p.handle(&InputEvent::MouseDown { x: x as f32, y: y as f32, modifiers: InputModifiers::NONE }, &mut r.ui);
        assert_eq!(press.first(), Some(&TimelineAction::Skim(None)));
    }

    // MARK: Find and replace

    /// One caption track: "the cat" at 0, "the dog" at 60 frames (word timings on both).
    fn search_rig(captions: bool) -> Rig {
        let item = |a: &str, b: &str, f: i64, n: u128| {
            caption_item(
                &[&format!("{a} {b}")],
                TimeRange::new(FD * f, FD * 25),
                vec![word(a, f, 12), word(b, f + 13, 12)],
                n,
            )
        };
        // The words are relative to the item start.
        let rel = |mut i: sq_core_model::CaptionItem| {
            for w in &mut i.words {
                w.range = TimeRange::new(w.range.start - i.range.start, w.range.duration);
            }
            i
        };
        let mut t = Timeline::new(uid(9000), "t", SequenceFormat::new(FD), vec![Track::new(uid(1), TrackKind::Video)]);
        if captions {
            t.caption_tracks =
                vec![caption_track(vec![rel(item("the", "cat", 0, 50)), rel(item("the", "dog", 60, 51))])];
        }
        let mut r = Rig::new(t, 1000.0, 400.0);
        r.p.layout_px(Rect::new(0.0, 100.0, 1000.0, 400.0), 1.0);
        r.sync();
        r
    }

    fn send_search(r: &mut Rig, e: InputEvent) -> Option<Vec<TimelineAction>> {
        let a = r.p.handle_caption_search(&e, &mut r.ui)?;
        r.run(a.clone());
        Some(a)
    }

    fn type_search(r: &mut Rig, text: &str) {
        for ch in text.chars() {
            r.ui.typed_text = Some(ch.to_string());
            send_search(r, InputEvent::KeyDown { key: InputKey::Character(ch), modifiers: InputModifiers::NONE });
        }
        r.ui.typed_text = None;
    }

    fn click_part(r: &mut Rig, part: Part) {
        let Some(c) = &r.p.caption_search else { return };
        let q = c.rect(part);
        send_search(
            r,
            InputEvent::MouseDown { x: q.mid_x() as f32, y: q.mid_y() as f32, modifiers: InputModifiers::NONE },
        );
        send_search(r, InputEvent::MouseUp { x: q.mid_x() as f32, y: q.mid_y() as f32 });
    }

    #[test]
    fn opens_under_the_first_caption_row() {
        let mut r = search_rig(true);
        assert!(r.p.show_caption_search(sq_uikit::controls_grid::CGSize { width: 1440.0, height: 900.0 }));
        let row = r.p.geometry.caption_rows(&r.p.timeline)[0].clone();
        let f = r.p.caption_search.as_ref().expect("card").frame();
        assert_eq!(f.min_x(), TimelineGeometry::CONTENT_ORIGIN_X + 12.0);
        assert_eq!(f.min_y(), 100.0 + row.y.max(TimelineGeometry::RULER_HEIGHT) + row.height + 4.0);
        assert!(f.width == 356.0 && f.height == 12.0 + 22.0 + 8.0 + 22.0 + 8.0 + 22.0 + 12.0);
        assert!(r.p.caption_search.as_ref().is_some_and(|c| c.is_editing()));
        let mut q = search_rig(false);
        assert!(!q.p.show_caption_search(sq_uikit::controls_grid::CGSize { width: 1440.0, height: 900.0 }));
        assert!(!q.p.is_caption_search_shown());
    }

    #[test]
    fn typing_highlights_return_steps_esc_closes() {
        let mut r = search_rig(true);
        r.p.show_caption_search(sq_uikit::controls_grid::CGSize { width: 1440.0, height: 900.0 });
        type_search(&mut r, "the");
        assert_eq!(r.p.caption_search.as_ref().map(|c| c.count_text()), Some("1 of 2".to_string()));
        let first = items(&r)[0].id;
        assert_eq!(r.s.caption_selection(), &BTreeSet::from([first]));
        assert_eq!(r.s.playhead(), Time::ZERO);
        send_search(&mut r, InputEvent::KeyDown { key: InputKey::Enter, modifiers: InputModifiers::NONE });
        assert!(
            r.s.playhead() == Time::ZERO
                && r.p.caption_search.as_ref().map(|c| c.count_text()) == Some("1 of 2".to_string())
        );
        send_search(&mut r, InputEvent::KeyDown { key: InputKey::Enter, modifiers: InputModifiers::NONE });
        assert_eq!(r.p.caption_search.as_ref().map(|c| c.count_text()), Some("2 of 2".to_string()));
        assert_eq!(r.s.playhead(), FD * 60);
        send_search(&mut r, InputEvent::KeyDown { key: InputKey::Escape, modifiers: InputModifiers::NONE });
        assert!(!r.p.is_caption_search_shown());
    }

    #[test]
    fn replace_all_is_one_undo_step_and_shows_the_count() {
        let mut r = search_rig(true);
        r.p.show_caption_search(sq_uikit::controls_grid::CGSize { width: 1440.0, height: 900.0 });
        type_search(&mut r, "the");
        send_search(
            &mut r,
            InputEvent::KeyDown { key: sq_draw::inspector::text_field_control::TAB, modifiers: InputModifiers::NONE },
        );
        type_search(&mut r, "a");
        click_part(&mut r, Part::ReplaceAll);
        let lines = |r: &Rig| items(r).iter().map(|i| i.lines.clone()).collect::<Vec<_>>();
        assert_eq!(lines(&r), vec![vec!["a cat".to_string()], vec!["a dog".to_string()]]);
        assert_eq!(r.p.caption_search.as_ref().map(|c| c.count_text()), Some("2 replaced".to_string()));
        r.s.undo();
        r.sync();
        assert_eq!(lines(&r), vec![vec!["the cat".to_string()], vec!["the dog".to_string()]]);
        let outside =
            send_search(&mut r, InputEvent::MouseDown { x: 990.0, y: 490.0, modifiers: InputModifiers::NONE });
        assert!(outside.is_none());
        assert!(r.p.is_caption_search_shown());
        click_part(&mut r, Part::Close);
        assert!(!r.p.is_caption_search_shown());
    }

    #[test]
    fn draws_the_card() {
        let mut r = search_rig(true);
        r.p.show_caption_search(sq_uikit::controls_grid::CGSize { width: 1440.0, height: 900.0 });
        let mut c = sq_draw::Canvas::with_size(1440.0, 900.0, None, 1.0);
        r.p.draw_caption_search(&mut c, &mut r.ui);
        assert!(c.list.quads().len() > 10);
    }
}

// MARK: View commands

mod view_commands {
    use super::*;
    use sq_core_model::{ClipEdge, TimelineEditMode};
    use sq_editor_session::{EdgeRef, ToolState};
    use sq_library::library_folder_store::{MemorySettings, SettingsStore};
    use sq_timeline_ui::{ThumbnailMode, TrackHeightMode};
    use sq_uikit::editor_command::{EditorCommand as C, EditorTool, ThumbnailModeChoice};

    const FD: Time = Time::new(1, 25);

    fn vclip(n: u128, start: i64, frames: i64) -> Clip {
        Clip::new(uid(n), "c", uid(n + 500), TrackKind::Video, TimeRange::new(Time::ZERO, FD * frames), FD * start)
    }

    /// V1 with two clips, V2, A1 in a session; a 1000 x 400 pt panel synced to it.
    fn setup() -> (Rig, MemorySettings) {
        let mut v1 = Track::new(uid(1), TrackKind::Video);
        v1.set_clips(vec![vclip(10, 0, 50), vclip(11, 100, 50)]);
        let t = Timeline::new(
            uid(9000),
            "t",
            SequenceFormat::new(FD),
            vec![v1, Track::new(uid(2), TrackKind::Video), Track::new(uid(3), TrackKind::Audio)],
        );
        (Rig::new(t, 1000.0, 400.0), MemorySettings::default())
    }

    fn run(r: &mut Rig, d: &mut MemorySettings, c: &C) -> Option<String> {
        let out = r.p.run_view_command(c, &mut r.s, true, None, true, d);
        r.sync();
        out
    }

    fn read_bool(d: &MemorySettings, key: &str) -> Option<bool> {
        match d.data(key)?.as_slice() {
            b"true" => Some(true),
            b"false" => Some(false),
            _ => None,
        }
    }

    #[test]
    fn the_tools_menu_picks_the_tool_and_the_slip_variant() {
        let (mut r, mut d) = setup();
        assert_eq!(
            run(&mut r, &mut d, &C::Tool(EditorTool::Razor)),
            Some(sq_uikit::localization::SQL10n::string(&C::Tool(EditorTool::Razor).title()))
        );
        assert_eq!(r.p.tool_state().tool, sq_editor_session::TimelineTool::Razor);
        assert!(run(&mut r, &mut d, &C::SlipKeyframesStayTool).is_some());
        assert!(r.p.tool_state().tool == sq_editor_session::TimelineTool::Slip && r.p.tool_state().slip_keyframes_stay);
        run(&mut r, &mut d, &C::Tool(EditorTool::Slip));
        assert!(!r.p.tool_state().slip_keyframes_stay);
    }

    #[test]
    fn add_marker_twice_opens_the_marker_editor() {
        let (mut r, mut d) = setup();
        let opened = Rc::new(RefCell::new(Vec::new()));
        let hook = Rc::clone(&opened);
        let mut host = TimelineHost::new();
        host.open = Some(Box::new(move |req| {
            hook.borrow_mut().push(req.clone());
            true
        }));
        let out = r.p.run_view_command(&C::AddMarker, &mut r.s, true, Some(&mut host), true, &mut d);
        assert_eq!(out, Some(String::new()));
        assert!(r.tl().markers.len() == 1 && opened.borrow().is_empty());
        r.p.run_view_command(&C::AddMarker, &mut r.s, true, Some(&mut host), true, &mut d);
        assert!(r.tl().markers.len() == 1 && opened.borrow().len() == 1);
    }

    #[test]
    fn snapping_toggle_is_saved_with_the_sequence_and_undo_brings_it_back() {
        let (mut r, mut d) = setup();
        assert!(r.p.tool_state().snapping);
        assert_eq!(run(&mut r, &mut d, &C::ToggleSnapping), Some("Snapping off".to_string()));
        assert!(!r.p.tool_state().snapping && r.tl().snapping_off_store == Some(true));
        assert_eq!(read_bool(&d, ToolState::SNAPPING_DEFAULTS_KEY), Some(false));
        r.s.undo();
        r.sync();
        r.p.sync_toggles(&r.s);
        assert!(r.p.tool_state().snapping);
    }

    #[test]
    fn linked_selection_toggle_reaches_the_session() {
        let (mut r, mut d) = setup();
        assert_eq!(run(&mut r, &mut d, &C::ToggleLinkedSelection), Some("Linked Selection off".to_string()));
        assert!(
            !r.s.linked_selection()
                && r.tl().linked_selection_off_store == Some(true)
                && !r.p.tool_state().linked_selection
        );
    }

    #[test]
    fn fast_cut_toggle_says_the_mode() {
        let (mut r, mut d) = setup();
        assert!(run(&mut r, &mut d, &C::ToggleMagnetic).is_some_and(|s| s.starts_with("Fast Cut:")));
        assert_eq!(r.tl().edit_mode(), TimelineEditMode::Magnetic);
        assert_eq!(run(&mut r, &mut d, &C::ToggleMagnetic), Some("Normal: classic tracks".to_string()));
    }

    #[test]
    fn edge_commands_select_trim_and_cycle() {
        let (mut r, mut d) = setup();
        assert_eq!(run(&mut r, &mut d, &C::TrimBackward), Some(TimelinePanel::need_edit_line()));
        assert_eq!(run(&mut r, &mut d, &C::SelectRightEdge), Some("Select a clip first.".to_string()));
        let first = r.tl().tracks[0].clips()[0].id;
        r.s.select(BTreeSet::from([first]), BTreeSet::new());
        r.sync();
        assert_eq!(run(&mut r, &mut d, &C::SelectRightEdge), Some(String::new()));
        assert_eq!(
            r.p.interaction.edge_selection().and_then(|e| e.edges.first().copied()),
            Some(EdgeRef { clip: first, edge: ClipEdge::Tail })
        );
        assert_eq!(run(&mut r, &mut d, &C::TrimBackward), Some(sq_core_time::step_status::line("Trim", -1)));
        assert_eq!(r.tl().tracks[0].clips()[0].duration(), FD * 49);
        let before = r.p.interaction.edge_selection().cloned();
        assert_eq!(run(&mut r, &mut d, &C::ToggleTrimType), Some(String::new()));
        assert_ne!(r.p.interaction.edge_selection().cloned(), before);
    }

    #[test]
    fn height_commands_turn_fit_off_and_keep_the_preset() {
        let (mut r, mut d) = setup();
        r.p.geometry.fit_all_tracks = true;
        let v1 = r.tl().tracks[0].id;
        let height = |r: &Rig| r.p.rows().into_iter().find(|x| x.track == v1).map(|x| x.height).unwrap_or(0.0);
        let h = height(&r);
        assert_eq!(run(&mut r, &mut d, &C::VideoTracksTaller), Some(String::new()));
        assert!(!r.p.geometry.fit_all_tracks && read_bool(&d, TimelinePanel::FIT_TRACKS_DEFAULTS_KEY) == Some(false));
        assert!(height(&r) > h);
        assert_eq!(run(&mut r, &mut d, &C::TrackHeightSmall), Some(String::new()));
        assert!(r.p.geometry.height_mode == TrackHeightMode::Small && r.p.geometry.height_overrides.is_empty());
        assert_eq!(d.data(TimelinePanel::HEIGHT_MODE_DEFAULTS_KEY), Some(b"small".to_vec()));
        assert_eq!(run(&mut r, &mut d, &C::ToggleFitTracks), Some(String::new()));
        assert!(r.p.geometry.fit_all_tracks);
        let mut q = TimelinePanel::new(DrawTheme::default());
        q.load_height_prefs(&d);
        assert!(q.geometry.height_mode == TrackHeightMode::Small && q.geometry.fit_all_tracks);
        // Opening a sequence keeps the app-wide preset (a fresh geometry used to fall back to auto stretch).
        q.layout_px(Rect::new(0.0, 0.0, 1000.0, 400.0), 1.0);
        q.sync(SessionView {
            timeline: r.tl(),
            selection: &BTreeSet::new(),
            captions: &BTreeSet::new(),
            playhead: Time::ZERO,
            selected_transition: None,
            labels: LabelResolver::default(),
            line_keys: BTreeSet::new(),
        });
        assert!(q.geometry.height_mode == TrackHeightMode::Small && q.geometry.fit_all_tracks);
    }

    #[test]
    fn zoom_commands_pass_on_when_another_panel_zooms() {
        let (mut r, mut d) = setup();
        assert_eq!(r.p.run_view_command(&C::ZoomIn, &mut r.s, false, None, true, &mut d), None);
        let pps = r.p.geometry.points_per_second;
        assert_eq!(run(&mut r, &mut d, &C::ZoomIn), Some(String::new()));
        assert!(r.p.geometry.points_per_second > pps);
        assert_eq!(run(&mut r, &mut d, &C::Copy), None);
    }

    #[test]
    fn thumbnail_mode_command_sets_the_panel_the_preference_and_the_checks() {
        let (mut r, mut d) = setup();
        assert_eq!(run(&mut r, &mut d, &C::ThumbnailMode(ThumbnailModeChoice::Continuous)), Some(String::new()));
        assert!(r.p.thumbnail_mode == ThumbnailMode::Continuous);
        assert_eq!(d.data(sq_timeline_ui::ThumbnailPrefs::MODE_KEY), Some(b"continuous".to_vec()));
        let checks = r.p.view_checks(&r.s);
        assert!(checks.contains(&C::ThumbnailMode(ThumbnailModeChoice::Continuous)));
        assert!(!checks.contains(&C::ThumbnailMode(ThumbnailModeChoice::Head)));
        assert!(checks.contains(&C::ToggleSnapping) && checks.contains(&C::ToggleLinkedSelection));
        run(&mut r, &mut d, &C::ToggleSnapping);
        assert!(!r.p.view_checks(&r.s).contains(&C::ToggleSnapping));
        assert!(!r.p.view_checks(&r.s).contains(&C::ToggleMagnetic));
        run(&mut r, &mut d, &C::ToggleMagnetic);
        assert!(r.p.view_checks(&r.s).contains(&C::ToggleMagnetic));
    }

    #[test]
    fn without_live_keys_the_keys_of_the_press_count() {
        let (mut r, _) = setup();
        r.send(InputEvent::MouseDown { x: 400.0, y: 10.0, modifiers: InputModifiers::SHIFT });
        assert_eq!(r.p.drag_modifiers(), InputModifiers::SHIFT);
        r.p.live_modifiers = Some(Box::new(|| InputModifiers::NONE));
        assert_eq!(r.p.drag_modifiers(), InputModifiers::NONE);
    }

    #[test]
    fn the_header_state_reads_the_session_and_the_panel() {
        let (mut r, mut d) = setup();
        let st = crate::header::TimelineHeaderState::make(&r.s, &r.p);
        assert!(st.tabs.len() == 1 && st.tabs[0].active && st.tabs[0].title == "t");
        assert_eq!(st.edit_mode, TimelineEditMode::Normal);
        assert_eq!(st.timecode, "00:00:00:00");
        assert!(st.snapping && st.linked_selection && st.verbs_enabled.is_empty());
        run(&mut r, &mut d, &C::ToggleMagnetic);
        let fast = crate::header::TimelineHeaderState::make(&r.s, &r.p);
        assert_eq!(fast.edit_mode, TimelineEditMode::Magnetic);
        assert_eq!(fast.verbs_enabled.len(), sq_timeline_ui::FastCutVerb::all().len());
    }
}

// MARK: Menus

mod menus {
    use super::*;
    use crate::host::TimelineEditorRequest;
    use crate::timeline_menus::{TimelineMenus, new_outbox};
    use sq_uikit::command_map::CommandMap;
    use sq_uikit::editor_command::EditorCommand as C;

    const FD: Time = Time::new(1, 25);

    fn vclip(n: u128, start: i64, frames: i64) -> Clip {
        Clip::new(uid(n), "c", uid(n + 500), TrackKind::Video, TimeRange::new(Time::ZERO, FD * frames), FD * start)
    }

    /// A session on V1 (two clips), V2, A1 and a 1000 x 400 pt panel synced to it.
    fn setup() -> Rig {
        let mut v1 = Track::new(uid(1), TrackKind::Video);
        v1.set_clips(vec![vclip(10, 0, 50), vclip(11, 100, 50)]);
        let t = Timeline::new(
            uid(9000),
            "t",
            SequenceFormat::new(FD),
            vec![v1, Track::new(uid(2), TrackKind::Video), Track::new(uid(3), TrackKind::Audio)],
        );
        Rig::new(t, 1000.0, 400.0)
    }

    fn titles(items: &Option<Vec<sq_uikit::sqmenu_model::SQMenuItem>>) -> Vec<String> {
        items.iter().flatten().map(|i| i.title.clone()).collect()
    }

    #[test]
    fn right_press_asks_for_the_menu_without_a_gesture() {
        let mut r = setup();
        let v1 = r.tl().tracks[0].id;
        let row = r.p.rows().into_iter().find(|x| x.track == v1).expect("row");
        let c = r.tl().tracks[0].clips()[0].clone();
        let p = pt(
            ((r.p.geometry.x(c.start) + r.p.geometry.x(c.timeline().end())) / 2.0).round(),
            (row.y + row.height * 0.7).round(),
        );
        let a = r.p.handle(
            &InputEvent::MouseDown { x: p.x as f32, y: p.y as f32, modifiers: InputModifiers::SECONDARY },
            &mut r.ui,
        );
        assert_eq!(a, vec![TimelineAction::ContextMenu(p)]);
        assert!(!r.p.is_dragging());
        assert!(r.p.handle(&InputEvent::MouseUp { x: p.x as f32, y: p.y as f32 }, &mut r.ui).is_empty());
    }

    #[test]
    fn clip_menu_selects_the_clip_and_runs_commands_through_the_host() {
        let mut r = setup();
        let v1 = r.tl().tracks[0].id;
        let row = r.p.rows().into_iter().find(|x| x.track == v1).expect("row");
        let c = r.tl().tracks[0].clips()[0].clone();
        let p = pt((r.p.geometry.x(c.start) + r.p.geometry.x(c.timeline().end())) / 2.0, row.y + row.height * 0.7);
        let ran = Rc::new(RefCell::new(Vec::new()));
        let hook = Rc::clone(&ran);
        r.host.command = Some(Box::new(move |cmd| hook.borrow_mut().push(cmd)));
        let out = new_outbox();
        let items = TimelineMenus::items(p, &mut r.p, &mut r.s, &mut r.host, &CommandMap::current(), &out);
        assert_eq!(r.s.selection(), &BTreeSet::from([c.id]));
        assert!(titles(&items).contains(&"Cut".to_string()) && titles(&items).contains(&"Ripple Delete".to_string()));
        if let Some(a) = items.iter().flatten().find(|i| i.title == "Cut").and_then(|i| i.action.clone()) {
            a();
        }
        let Rig { p, s, host, .. } = &mut r;
        TimelineMenus::run_all(&out, s, host, p);
        assert_eq!(*ran.borrow(), vec![C::Cut]);
    }

    #[test]
    fn header_menu_adds_deletes_and_renames_tracks() {
        let mut r = setup();
        let target = r.tl().tracks[1].id;
        let row = r.p.rows().into_iter().find(|x| x.track == target).expect("row");
        let p = pt(TimelineGeometry::TOOL_COLUMN_WIDTH + 20.0, row.y + 4.0);
        // The prompt answers at once with "Titles".
        r.host.prompt = Some(Box::new(|_, done| done("Titles".to_string())));
        let out = new_outbox();
        let items =
            TimelineMenus::items(p, &mut r.p, &mut r.s, &mut r.host, &CommandMap::current(), &out).unwrap_or_default();
        let n = r.tl().tracks.len();
        let run = |title: &str, r: &mut Rig| {
            if let Some(a) = items.iter().find(|i| i.title.starts_with(title)).and_then(|i| i.action.clone()) {
                a();
            }
            let Rig { p, s, host, .. } = r;
            TimelineMenus::run_all(&out, s, host, p);
        };
        run("Add Video Track", &mut r);
        assert_eq!(r.tl().tracks.len(), n + 1);
        run("Rename", &mut r);
        assert_eq!(r.tl().track(target).map(|t| t.name.clone()), Some("Titles".to_string()));
        run("Delete Track", &mut r);
        assert!(r.tl().track(target).is_none());
    }

    #[test]
    fn ruler_menu_adds_a_marker_and_missing_editors_report_status() {
        let mut r = setup();
        let out = new_outbox();
        let items = TimelineMenus::items(
            pt(TimelineGeometry::CONTENT_ORIGIN_X + 100.0, 10.0),
            &mut r.p,
            &mut r.s,
            &mut r.host,
            &CommandMap::current(),
            &out,
        );
        assert_eq!(titles(&items).first().map(String::as_str), Some("Add Marker"));
        if let Some(a) = items.iter().flatten().next().and_then(|i| i.action.clone()) {
            a();
        }
        let Rig { p, s, host, .. } = &mut r;
        TimelineMenus::run_all(&out, s, host, p);
        assert_eq!(r.tl().markers.len(), 1);
        let id = r.tl().markers[0].id;
        assert_eq!(
            session_bridge::apply(TimelineAction::EditMarker(id), &mut r.s, &mut r.host, None),
            Some(TimelineEditorRequest::Marker(id).unavailable())
        );
        r.host.open = Some(Box::new(|_| true));
        assert_eq!(session_bridge::apply(TimelineAction::OpenInSource(uid(77)), &mut r.s, &mut r.host, None), None);
    }
}

// MARK: Header tips, duck curve, mix row

mod misc {
    use super::*;
    use crate::header::TrackHeaderLayout;
    use sq_core_audio::live_ducking::LiveDucking;
    use sq_core_time::TimeRange as TR;

    const FD: Time = Time::new(1, 25);

    fn vclip(n: u128, start: i64, frames: i64) -> Clip {
        Clip::new(uid(n), "c", uid(n + 500), TrackKind::Video, TR::new(Time::ZERO, FD * frames), FD * start)
    }

    fn rig() -> Rig {
        let mut v1 = Track::new(uid(1), TrackKind::Video);
        v1.set_clips(vec![vclip(10, 0, 50), vclip(11, 100, 50)]);
        let t = Timeline::new(
            uid(9000),
            "t",
            SequenceFormat::new(FD),
            vec![v1, Track::new(uid(2), TrackKind::Video), Track::new(uid(3), TrackKind::Audio)],
        );
        Rig::new(t, 1000.0, 400.0)
    }

    /// A new, empty sequence opens at about 30 seconds across, not at one second per point (about 13 minutes wide).
    #[test]
    fn an_empty_sequence_opens_zoomed_to_about_thirty_seconds() {
        let t = Timeline::new(
            uid(9001),
            "empty",
            SequenceFormat::new(FD),
            vec![Track::new(uid(1), TrackKind::Video), Track::new(uid(2), TrackKind::Audio)],
        );
        let r = Rig::new(t, 1000.0, 400.0);
        let width = r.p.content_viewport_width();
        let visible = width / r.p.geometry.points_per_second;
        assert!((25.0..=40.0).contains(&visible), "{visible} s visible across {width} pt");
    }

    #[test]
    fn shift_click_on_a_line_key_toggles_it_in_the_picked_set() {
        use sq_editor_session::{LineKeyProperty, LineKeyRef};
        let mut r = rig();
        r.s.select([uid(10)].into(), Default::default());
        let key = |n: u128| LineKeyRef { clip: uid(10), property: LineKeyProperty::Opacity, key: uid(n) };
        let click = |r: &mut Rig, k: LineKeyRef, extend: bool| {
            let a = TimelineAction::LineKeyClick { key: Some(k), extend };
            session_bridge::apply(a, &mut r.s, &mut r.host, None);
        };
        click(&mut r, key(1), false);
        click(&mut r, key(2), true);
        assert_eq!(r.s.selected_line_keys().len(), 2);
        click(&mut r, key(1), true);
        assert_eq!(r.s.selected_line_keys().iter().copied().collect::<Vec<_>>(), vec![key(2)]);
        click(&mut r, key(3), false);
        assert_eq!(r.s.selected_line_keys().iter().copied().collect::<Vec<_>>(), vec![key(3)]);
    }

    #[test]
    fn header_buttons_offer_their_tips() {
        let mut r = rig();
        let v1 = r.tl().tracks[0].id;
        let row = r.p.rows().into_iter().find(|x| x.track == v1).expect("row");
        let chip = TrackHeaderLayout::chip_rect(row.height);
        let (x, y) = (TimelineGeometry::TOOL_COLUMN_WIDTH + chip.mid_x(), row.y + chip.mid_y());
        let e = InputEvent::MouseMoved { x: x as f32, y: y as f32 };
        r.ui.hover.begin_event(&e);
        r.p.handle(&e, &mut r.ui);
        r.ui.hover.end_event(&e, 0.0);
        assert_eq!(r.ui.hover.tooltip.text.as_deref(), Some("Target Track"));
    }

    #[test]
    fn a_header_press_on_a_button_toggles_the_track() {
        let mut r = rig();
        let v1 = r.tl().tracks[0].id;
        let row = r.p.rows().into_iter().find(|x| x.track == v1).expect("row");
        let chip = TrackHeaderLayout::chip_rect(row.height);
        let (x, y) = (TimelineGeometry::TOOL_COLUMN_WIDTH + chip.mid_x(), row.y + chip.mid_y());
        let a = r.down(x, y);
        assert_eq!(
            a,
            vec![TimelineAction::ToggleTrack {
                track: v1,
                toggle: sq_editor_session::TrackToggle::Target,
                shift: false,
                option: false
            }]
        );
    }

    #[test]
    fn the_duck_curve_draws_a_dipping_line_only_on_tall_rows() {
        let mut r = rig();
        let d = LiveDucking::new(12.0, Time::new(1, 4));
        let ranges = vec![TR::new(FD * 20, FD * 30)];
        let rect = CGRect::new(190.0, 100.0, 600.0, 56.0);
        let visible = CGRect::new(190.0, 0.0, 800.0, 400.0);
        let count = |r: &mut Rig, rect: CGRect| {
            let mut cv = sq_draw::Canvas::with_size(1000.0, 400.0, None, 1.0);
            r.p.draw_duck_curve(&mut cv, rect, visible, &ranges, &d);
            cv.list.quads().len()
        };
        assert!(count(&mut r, rect) > 0);
        assert_eq!(count(&mut r, CGRect::new(190.0, 100.0, 600.0, 30.0)), 0); // a low row shows no curve
    }

    #[test]
    fn the_silence_preview_shades_the_ranges_across_the_lanes() {
        let mut r = rig();
        let plain = draw_count(&mut r.p, 1000.0, 400.0);
        r.p.silence_preview = vec![TR::new(FD * 10, FD * 20)];
        // One band and a 1 pt edge at each end.
        assert_eq!(draw_count(&mut r.p, 1000.0, 400.0), plain + 3);
    }

    #[test]
    fn the_mix_row_sits_under_the_last_track() {
        let r = rig();
        let rows = r.p.rows();
        let m = crate::lanes::MixRow::rect(&rows, r.p.geometry.caption_height(&r.p.timeline), r.p.track_area_height());
        assert_eq!(m.map(|m| m.min_y()), rows.last().map(|l| l.bottom()));
    }
}
