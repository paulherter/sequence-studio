//! Accessibility of the panels that have no node code of their own: sequence tabs, the tool strip, timeline tracks, clips
//! and markers, and the monitor transport. It reads a snapshot of the session taken in `sync` (nodes are pushed without
//! the session at hand) and acts on the session in `run`, like the pointer would.

use accesskit::{Action, Node, NodeId, Role};
use sq_app_shell::A11yAction;
use sq_core_model::{Timeline, TrackKind};
use sq_core_time::{Id, Time};
use sq_draw::A11y;
use sq_draw_timeline::TimelineMediaSource;
use sq_editor_session::{EditorSession, ToolState};
use sq_uikit::editor_command::EditorTool;
use sq_uikit::sqaccessibility_text::SQAccessibilityText as Text;
use sq_uikit::timecode::Timecode;
use std::collections::BTreeSet;

const TIMELINE: &str = "timeline";
const TABS: &str = "tabs";
const TOOLS: &str = "tools";
const MONITOR: &str = "monitor";

/// The tool strip buttons in strip order.
const TOOL_BUTTONS: [(&str, EditorTool); 13] = [
    ("Selection Tool", EditorTool::Selection),
    ("Track Select Tool", EditorTool::TrackForward),
    ("Ripple Edit Tool", EditorTool::Ripple),
    ("Rolling Edit Tool", EditorTool::Rolling),
    ("Slip Tool", EditorTool::Slip),
    ("Slide Tool", EditorTool::Slide),
    ("Razor Tool", EditorTool::Razor),
    ("Hand Tool", EditorTool::Hand),
    ("Rate Stretch Tool", EditorTool::RateStretch),
    ("Zoom Tool", EditorTool::Zoom),
    ("Type Tool", EditorTool::Type),
    ("Mask Tool", EditorTool::Mask),
    ("Position Tool", EditorTool::Position),
];

/// What [`SessionAccess::run`] did.
#[derive(Debug, PartialEq)]
pub(crate) enum Outcome {
    /// The node is not one of this module's.
    Unknown,
    /// The session was changed (or the node needs nothing).
    Done,
    /// The timeline panel owns the tool state: the caller selects this tool there.
    Tool(EditorTool),
}

/// The session facts the nodes are made of.
pub(crate) struct SessionAccess {
    timeline: Option<Timeline>,
    selection: BTreeSet<Id>,
    playhead: Time,
    playing: bool,
    tabs: Vec<(Id, String)>,
    active_tab: Option<usize>,
    tool: Option<ToolState>,
    offline: BTreeSet<Id>,
}

fn id_key(prefix: &str, id: Id) -> String {
    format!("{prefix}:{id:?}")
}

impl Default for SessionAccess {
    fn default() -> SessionAccess {
        SessionAccess {
            timeline: None,
            selection: BTreeSet::new(),
            playhead: Time::seconds(0),
            playing: false,
            tabs: Vec::new(),
            active_tab: None,
            tool: None,
            offline: BTreeSet::new(),
        }
    }
}

impl SessionAccess {
    /// Takes the facts of `session`; `tool` is the timeline panel's tool state, `media` tells which clips are offline.
    pub(crate) fn sync(&mut self, session: &EditorSession, tool: ToolState, media: Option<&dyn TimelineMediaSource>) {
        self.timeline = session.active_timeline().cloned();
        self.selection = session.selection().clone();
        self.playhead = session.playhead();
        self.playing = session.is_playing();
        let tabs = session.sequence_tabs();
        self.tabs = tabs
            .tabs()
            .iter()
            .map(|t| (t.root(), session.project().timeline(t.root()).map(|x| x.name.clone()).unwrap_or_default()))
            .collect();
        self.active_tab = tabs.active_index();
        self.tool = Some(tool);
        self.offline = match (&self.timeline, media) {
            (Some(t), Some(m)) => t
                .tracks
                .iter()
                .flat_map(|tr| tr.clips())
                .filter(|c| c.generator.is_none() && c.sequence.is_none() && m.is_offline(c.media))
                .map(|c| c.id)
                .collect(),
            _ => BTreeSet::new(),
        };
    }

    fn timecode(&self) -> Timecode {
        Timecode::new(self.timeline.as_ref().map_or(Time::new(1, 30), Timeline::frame_duration), false)
    }

    /// Pushes tabs, tool buttons, the transport, and the tracks, clips and markers of the open sequence.
    pub(crate) fn push_nodes(&self, a: &mut A11y) {
        if !a.is_active() {
            return;
        }
        a.push(TABS, Role::TabList, "list", Node::new(Role::TabList));
        for (i, (root, name)) in self.tabs.iter().enumerate() {
            let mut n = Node::new(Role::Tab);
            n.set_label(name.as_str());
            n.set_selected(self.active_tab == Some(i));
            n.add_action(Action::Click);
            a.push(TABS, Role::Tab, &id_key("s", *root), n);
        }
        for (label, tool) in TOOL_BUTTONS {
            let mut n = Node::new(Role::Button);
            n.set_label(label);
            let on = self.tool.is_some_and(|s| tool_matches(s, tool));
            n.set_toggled(if on { accesskit::Toggled::True } else { accesskit::Toggled::False });
            n.add_action(Action::Click);
            a.push(TOOLS, Role::Button, label, n);
        }
        let tc = self.timecode();
        let now = tc.position(self.playhead);
        let mut play = Node::new(Role::Button);
        play.set_label(if self.playing { "Pause" } else { "Play" });
        play.add_action(Action::Click);
        a.push(MONITOR, Role::Button, "play", play);
        let mut code = Node::new(Role::Label);
        code.set_label(Text::timecode_label());
        code.set_value(Text::monitor_value(self.playing, &now));
        a.push(MONITOR, Role::Label, "timecode", code);
        let Some(t) = &self.timeline else { return };
        let mut head = Node::new(Role::Label);
        head.set_label(Text::timeline_playhead(&now));
        a.push(TIMELINE, Role::Label, "playhead", head);
        for track in t.tracks.iter() {
            let kind = if track.kind == TrackKind::Video { "Video" } else { "Audio" };
            let mut n = Node::new(Role::Group);
            n.set_label(Text::track(
                kind,
                &track.name,
                track.clips().len() as i64,
                track.is_locked,
                track.is_muted,
                !track.is_visible,
            ));
            a.push(TIMELINE, Role::Group, &id_key("t", track.id), n);
            for c in track.clips() {
                let mut n = Node::new(Role::ListItem);
                n.set_label(Text::clip(
                    &c.name,
                    &tc.position(c.start),
                    &tc.format(c.duration()),
                    self.offline.contains(&c.id),
                ));
                n.set_selected(self.selection.contains(&c.id));
                n.add_action(Action::Click);
                n.add_action(Action::Focus);
                a.push(TIMELINE, Role::ListItem, &id_key("c", c.id), n);
            }
        }
        for m in &t.markers {
            let mut n = Node::new(Role::ListItem);
            n.set_label(format!("Marker {}, at {}", m.name, tc.position(m.time)));
            n.add_action(Action::Click);
            n.add_action(Action::Focus);
            a.push(TIMELINE, Role::ListItem, &id_key("m", m.id), n);
        }
    }

    /// Runs `action` on the node `id` against `session`.
    pub(crate) fn run(&self, id: NodeId, action: A11yAction, session: &mut EditorSession) -> Outcome {
        let node = |panel, role, key: &str| A11y::node_id(panel, role, key) == id;
        if let Some((root, _)) = self.tabs.iter().find(|(r, _)| node(TABS, Role::Tab, &id_key("s", *r))) {
            if action == A11yAction::Click {
                session.select_sequence_tab(*root);
            }
            return Outcome::Done;
        }
        if let Some((_, tool)) = TOOL_BUTTONS.iter().find(|(l, _)| node(TOOLS, Role::Button, l)) {
            return if action == A11yAction::Click { Outcome::Tool(*tool) } else { Outcome::Done };
        }
        if node(MONITOR, Role::Button, "play") {
            if action == A11yAction::Click {
                session.play_pause();
            }
            return Outcome::Done;
        }
        let Some(t) = &self.timeline else { return Outcome::Unknown };
        for track in t.tracks.iter() {
            for c in track.clips() {
                if node(TIMELINE, Role::ListItem, &id_key("c", c.id)) {
                    match action {
                        A11yAction::Click => session.select_with_partners(BTreeSet::from([c.id])),
                        A11yAction::Focus => session.seek(c.start),
                        _ => {}
                    }
                    return Outcome::Done;
                }
            }
        }
        for m in &t.markers {
            if node(TIMELINE, Role::ListItem, &id_key("m", m.id)) {
                if matches!(action, A11yAction::Click | A11yAction::Focus) {
                    session.seek(m.time);
                }
                return Outcome::Done;
            }
        }
        Outcome::Unknown
    }
}

/// Whether `state` shows the strip button of `tool` as the active one.
fn tool_matches(state: ToolState, tool: EditorTool) -> bool {
    let mut probe = state;
    probe.select(tool);
    probe.tool == state.tool
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{Clip, Project, SequenceFormat, Track};
    use sq_core_time::{SequentialIds, TimeRange};
    use sq_editor_session::SessionDeps;

    fn session() -> (EditorSession, Id) {
        let (clip_id, track_id, tl_id) = (Id::from_u128(11), Id::from_u128(12), Id::from_u128(13));
        let mut track = Track::new(track_id, TrackKind::Video);
        let source = TimeRange::new(Time::seconds(0), Time::seconds(4));
        let clip = Clip::new(clip_id, "Interview", Id::from_u128(14), TrackKind::Video, source, Time::seconds(2));
        assert!(track.insert(clip, &mut SequentialIds::default()).is_ok());
        let tl = Timeline::new(tl_id, "Main", SequenceFormat::new(Time::new(1, 25)), vec![track]);
        let project = Project::new(Id::from_u128(2), "p", Vec::new(), vec![tl]);
        let mut s =
            EditorSession::new(project, SessionDeps::headless(crate::test_rig::unique_dir("sq-session-access")));
        s.set_active_timeline(tl_id);
        (s, clip_id)
    }

    fn nodes(s: &EditorSession) -> (SessionAccess, Vec<(NodeId, Node)>) {
        let mut access = SessionAccess::default();
        access.sync(s, ToolState::default(), None);
        let mut a = A11y::new(true);
        access.push_nodes(&mut a);
        (access, a.take())
    }

    #[test]
    fn clips_tracks_tools_and_transport_are_nodes() {
        let (s, clip) = session();
        let (_, all) = nodes(&s);
        let id = A11y::node_id(TIMELINE, Role::ListItem, &id_key("c", clip));
        let node = all.iter().find(|(i, _)| *i == id).map(|(_, n)| n);
        assert_eq!(node.and_then(Node::label), Some("Interview, from 00:00:02:00, length 00:00:04:00"));
        assert!(all.iter().any(|(_, n)| n.role() == Role::Group));
        assert!(all.iter().any(|(_, n)| n.role() == Role::Tab && n.is_selected() == Some(true)));
        let selection = A11y::node_id(TOOLS, Role::Button, "Selection Tool");
        let on = all.iter().find(|(i, _)| *i == selection).map(|(_, n)| n.toggled());
        assert_eq!(on, Some(Some(accesskit::Toggled::True)));
        assert!(all.iter().any(|(_, n)| n.label() == Some("Play")));
    }

    #[test]
    fn click_selects_a_clip_focus_moves_the_playhead_and_play_toggles() {
        let (mut s, clip) = session();
        let (access, _) = nodes(&s);
        let id = A11y::node_id(TIMELINE, Role::ListItem, &id_key("c", clip));
        assert_eq!(access.run(id, A11yAction::Click, &mut s), Outcome::Done);
        assert!(s.selection().contains(&clip));
        assert_eq!(access.run(id, A11yAction::Focus, &mut s), Outcome::Done);
        assert_eq!(s.playhead(), Time::seconds(2));
        let razor = A11y::node_id(TOOLS, Role::Button, "Razor Tool");
        assert_eq!(access.run(razor, A11yAction::Click, &mut s), Outcome::Tool(EditorTool::Razor));
        let play = A11y::node_id(MONITOR, Role::Button, "play");
        assert_eq!(access.run(play, A11yAction::Click, &mut s), Outcome::Done);
        assert_eq!(access.run(NodeId(1), A11yAction::Click, &mut s), Outcome::Unknown);
    }

    struct Gone;
    impl TimelineMediaSource for Gone {
        fn waveform(&self, _media: Id) -> Option<std::sync::Arc<sq_media::waveform_data::WaveformData>> {
            None
        }
        fn is_offline(&self, _media: Id) -> bool {
            true
        }
    }

    #[test]
    fn an_offline_clip_says_so_and_a_marker_takes_focus() {
        let (mut s, clip) = session();
        s.seek(Time::seconds(3));
        s.add_marker_at_playhead();
        s.seek(Time::seconds(0));
        let mut access = SessionAccess::default();
        access.sync(&s, ToolState::default(), Some(&Gone));
        let mut a = A11y::new(true);
        access.push_nodes(&mut a);
        let id = A11y::node_id(TIMELINE, Role::ListItem, &id_key("c", clip));
        let all = a.take();
        let label = all.iter().find(|(i, _)| *i == id).and_then(|(_, n)| n.label().map(str::to_string));
        assert_eq!(label.as_deref(), Some("Interview, from 00:00:02:00, length 00:00:04:00, media offline"));
        let marker = all.iter().find(|(_, n)| n.label().is_some_and(|l| l.starts_with("Marker "))).expect("marker");
        assert!(marker.1.supports_action(Action::Focus));
        assert_eq!(access.run(marker.0, A11yAction::Focus, &mut s), Outcome::Done);
        assert_eq!(s.playhead(), Time::seconds(3));
    }
}
