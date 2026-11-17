// Swift: EditorSession.swift (rest), EditorSession+Shell.swift, EditorSession+CommandEnablement.swift,
// EditorSession+Recovery.swift, CommandRouting.swift, KeyRouter.swift, ToolState.swift, EditorSession+FollowSelection.swift
// and the other ES1 files of TASKS.md.
//! ES1: session core rest: lifecycle, selection, transport, sequence tabs, save queue, command routing and enablement,
//! key routing, tool state, follow selection.

#[cfg(test)]
mod blade_default_tests;
#[cfg(test)]
mod edge_case_tests;
mod editing;
mod enablement;
mod files;
mod format;
mod lifecycle;
mod place;
mod routing;
#[cfg(test)]
mod session_tests;
mod shell;
mod small;
mod tabs;
mod tools;
pub use editing::*;
pub use files::*;
pub use format::*;
pub use place::*;
pub use routing::*;
pub use shell::*;
pub use small::*;
pub use tabs::*;
pub use tools::*;

use std::path::Path;

use sq_core_edit::playback_bounds::PlaybackBounds;
use sq_core_file::ProjectFileError;
use sq_core_model::{Project, SequenceFormat, Timeline};
use sq_core_time::{Id, IdSource, Time};
use sq_uikit::editor_command::EditorCommand;
use sq_uikit::panel_id::PanelID;

use crate::{Change, EditorSession, ProgramEngine};

impl EditorSession {
    /// Empty project with one 29.97 fps HD sequence (V1-V4, A1-A4).
    // Swift: EditorSession.swift:328
    pub fn make_untitled(ids: &mut dyn IdSource) -> Project {
        let mut t = Timeline::new(
            ids.next_id(),
            "Sequence 01",
            SequenceFormat::new(Time::new(1001, 30000)),
            Timeline::default_tracks(4, 4, ids),
        );
        t.format_locked = false;
        Project::new(ids.next_id(), "Untitled", Vec::new(), vec![t])
    }

    /// The state before a project is chosen (launch chooser, after Close Project): a project without any sequence.
    // Swift: EditorSession.swift:336
    pub fn make_empty(ids: &mut dyn IdSource) -> Project {
        Project::new(ids.next_id(), "Untitled", Vec::new(), Vec::new())
    }

    /// Another monitor's engine (the Trim monitor) that must hear about relinked media like the Program engine.
    // Swift: EditorSession.swift:172
    pub fn add_auxiliary_engine(&mut self, engine: Box<dyn ProgramEngine>) {
        self.auxiliary_engines.retain(|e| e.is_alive());
        self.auxiliary_engines.push(engine);
    }

    /// Tells the Program engine and every alive auxiliary engine what the proxy service decided since the last call
    /// (the proxy use, and which media got or lost proxies). The app also calls it after its proxy tick.
    // Swift: AutoProxy.swift:412 (the service held the engines weakly and told them itself)
    pub fn apply_proxy_effects(&mut self) {
        let effects = self.auto_proxy.as_mut().map(|p| p.take_effects()).unwrap_or_default();
        if effects.is_empty() {
            return;
        }
        self.auxiliary_engines.retain(|e| e.is_alive());
        for effect in effects {
            match effect {
                crate::ProxyEffect::UseChanged(u) => {
                    self.engine.set_proxy_use(u);
                    self.auxiliary_engines.iter_mut().for_each(|e| e.set_proxy_use(u));
                }
                crate::ProxyEffect::ProxiesChanged(ids) => {
                    self.engine.proxies_changed(&ids);
                    self.auxiliary_engines.iter_mut().for_each(|e| e.proxies_changed(&ids));
                }
            }
        }
    }

    /// One turn of the proxy service: worker results in, new work out, then the monitors hear what changed. Returns the
    /// transcodes still to do for the queue popover.
    pub fn pump_proxies(&mut self) -> Vec<crate::BackgroundProxyJob> {
        let Some(p) = self.auto_proxy.as_mut() else { return Vec::new() };
        p.pump();
        let jobs = p.background_jobs();
        self.apply_proxy_effects();
        jobs
    }

    /// The policy the monitors, the proxy service and the render cache run with (thermal / Low Power / memory pressure,
    /// `PowerPolicy::combined`): the Program and auxiliary engines cap their decode size and halve the prefetch, background
    /// proxy transcodes and render-cache jobs start nothing new while `pauses_background_jobs`.
    // Swift: PlaybackEngine.swift:35, AutoProxy.swift:112, RenderCacheController.held
    pub fn apply_load_policy(&mut self, policy: sq_playback::engine::power_policy::PowerPolicy) {
        self.engine.set_power_policy(policy);
        self.auxiliary_engines.retain(|e| e.is_alive());
        self.auxiliary_engines.iter_mut().for_each(|e| e.set_power_policy(policy));
        if let Some(p) = self.auto_proxy.as_mut() {
            p.set_held(policy.pauses_background_jobs);
        }
        if let Some(r) = self.render_cache.as_mut() {
            r.set_held(policy.pauses_background_jobs);
        }
    }

    /// Cancel on a background job's row of the queue popover.
    pub fn cancel_proxy_job(&mut self, id: &str) {
        if let Some(p) = self.auto_proxy.as_mut() {
            p.cancel_job(id);
        }
    }

    /// Preferences > Media > Delete Cache: the proxies no monitor uses are removed; the bytes freed.
    pub fn clear_proxy_cache(&mut self) -> i64 {
        self.auto_proxy.as_mut().map_or(0, |p| p.clear_cache())
    }

    /// Clears the status line message.
    // Swift: EditorSession.swift:961
    pub fn clear_error(&mut self) {
        if self.last_error.is_none() {
            return;
        }
        self.last_error = None;
        self.notify(Change::STATUS);
    }

    // Swift: EditorSession.swift:147
    pub fn bounds(&self) -> PlaybackBounds {
        self.bounds
    }

    /// Loop toggle and the "Play In to Out" range; range and loop go on to the engine (Swift `bounds.didSet`).
    pub fn set_bounds(&mut self, bounds: PlaybackBounds) {
        let old = std::mem::replace(&mut self.bounds, bounds);
        if bounds.range() != old.range() {
            self.engine.set_play_range(bounds.range());
        }
        if bounds.loop_playback != old.loop_playback {
            self.engine.set_loops(bounds.loop_playback);
        }
    }

    /// Unlink: at least one selected clip carries a link.
    // Swift: EditorSession+CommandEnablement.swift:29
    pub fn can_unlink_selection(&self) -> bool {
        let Some(t) = self.active_timeline() else { return false };
        if self.selection.is_empty() {
            return false;
        }
        t.tracks.iter().flat_map(|tr| tr.clips().iter()).any(|c| self.selection.contains(&c.id) && c.link.is_some())
    }

    /// What undo and redo do after the step: reveal the change, put the playhead back (`to`).
    pub(crate) fn after_undo_redo(&mut self, before: Option<&Timeline>, to: Option<Time>) {
        self.reveal_change(before);
        // A ripple had moved the playhead: back where it was (only in the sequence it happened in).
        if let Some(t) = to {
            self.seek_sequence(t);
        }
    }
}

/// Which command handler a menu or key goes to (Swift `CommandRouting`, a namespace).
// Swift: CommandRouting.swift:9
pub enum CommandRouting {}

impl CommandRouting {
    /// Delete in the Program monitor with graphics layers selected removes those layers, never the whole clip.
    // Swift: CommandRouting.swift:91
    pub fn deletes_monitor_layers(command: EditorCommand, panel: Option<PanelID>, has_layer_selection: bool) -> bool {
        command == EditorCommand::Delete && panel == Some(PanelID::ProgramMonitor) && has_layer_selection
    }
}

/// One open sequence tab: the root sequence and the nested path shown in it.
// Swift: SequenceTabs.swift:7
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SequenceTab {
    // Swift: SequenceTabs.swift:8
    pub path: Vec<Id>,
}

impl SequenceTab {
    /// The sequence the tab opened (the path is never empty).
    // Swift: SequenceTabs.swift:9
    pub fn root(&self) -> Id {
        self.path[0]
    }
    /// The sequence the tab shows: the innermost of the path.
    // Swift: SequenceTabs.swift:10
    pub fn shown(&self) -> Id {
        self.path[self.path.len() - 1]
    }
}

/// Open sequence tabs over the timeline and the nested path of each.
// Swift: SequenceTabs.swift:6
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SequenceTabs {
    pub(crate) tabs: Vec<SequenceTab>,
    pub(crate) active_index: Option<usize>,
}

/// Serialized access to the project package on disk (Swift actor `ProjectSaveQueue`). The writer and reader are
/// `Send + Sync` so ES1 can run them on the worker pool, one at a time.
// Swift: ProjectSaveQueue.swift:6
pub struct ProjectSaveQueue {
    writer: Writer,
    reader: Reader,
}

/// Writes a project to a path.
// Swift: ProjectSaveQueue.swift:7
pub type Writer = std::sync::Arc<dyn Fn(&Project, &Path) -> Result<(), ProjectFileError> + Send + Sync>;
/// Reads a project from a path.
// Swift: ProjectSaveQueue.swift:8
pub type Reader = std::sync::Arc<dyn Fn(&Path) -> Result<Project, ProjectFileError> + Send + Sync>;

impl ProjectSaveQueue {
    /// The queue over `ProjectFile` (Swift's default arguments).
    // Swift: ProjectSaveQueue.swift:12
    pub fn new() -> ProjectSaveQueue {
        ProjectSaveQueue::with(
            std::sync::Arc::new(|p, path| sq_core_project::project_file::project_file().write(p, path)),
            std::sync::Arc::new(|path| sq_core_project::project_file::project_file().read(path)),
        )
    }

    pub fn with(writer: Writer, reader: Reader) -> ProjectSaveQueue {
        ProjectSaveQueue { writer, reader }
    }

    // Swift: ProjectSaveQueue.swift:17
    pub fn write(&self, project: &Project, path: &Path) -> Result<(), ProjectFileError> {
        (self.writer)(project, path)
    }

    // Swift: ProjectSaveQueue.swift:19
    pub fn read(&self, path: &Path) -> Result<Project, ProjectFileError> {
        (self.reader)(path)
    }
}

impl Default for ProjectSaveQueue {
    fn default() -> ProjectSaveQueue {
        ProjectSaveQueue::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn untitled_project_has_one_unlocked_sequence_with_eight_tracks() {
        let mut ids = sq_core_time::SequentialIds::default();
        let p = EditorSession::make_untitled(&mut ids);
        assert_eq!(p.name, "Untitled");
        assert_eq!(p.timelines.len(), 1);
        let t = &p.timelines[0];
        assert_eq!((t.name.as_str(), t.tracks.len(), t.format_locked), ("Sequence 01", 8, false));
        assert_eq!(t.frame_duration(), Time::new(1001, 30000));
        assert!(EditorSession::make_empty(&mut ids).timelines.is_empty());
    }

    #[test]
    fn monitor_delete_with_layers_removes_layers() {
        let pm = Some(PanelID::ProgramMonitor);
        assert!(CommandRouting::deletes_monitor_layers(EditorCommand::Delete, pm, true));
        assert!(!CommandRouting::deletes_monitor_layers(EditorCommand::Delete, pm, false));
        assert!(!CommandRouting::deletes_monitor_layers(EditorCommand::Delete, Some(PanelID::Timeline), true));
    }
}
