//! Headless shell and session for the tests of the form, dock and Project list modules.

use crate::shell_host::ShellHost;
use sq_core_time::{SequentialIds, Timestamp};
use sq_editor_session::{EditorSession, RecentProjects, SessionDeps};
use sq_runtime::FakeClock;
use sq_uikit::command_map::CommandMap;
use sq_uikit::controls_grid::CGSize;
use std::sync::Arc;

/// An untitled session without engine or disk services.
pub(crate) fn session() -> EditorSession {
    let mut ids = SequentialIds::default();
    let project = EditorSession::make_untitled(&mut ids);
    let mut deps = SessionDeps::headless(std::env::temp_dir().join("sq-draw-shell-tests-sh2"));
    deps.ids = Box::new(ids);
    EditorSession::new(project, deps)
}

/// A host with the default key map on a 1000 x 700 window.
pub(crate) fn shell() -> ShellHost {
    let mut h = ShellHost::new(
        CommandMap::premiere_default(),
        RecentProjects::new(Vec::new()),
        Arc::new(FakeClock::new()),
        Box::new(|| Timestamp::from_unix_seconds(0.0)),
    );
    h.set_size(CGSize::new(1000.0, 700.0));
    h
}
