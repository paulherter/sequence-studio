// Swift: ProjectPanelModel.swift, ProjectPanelColumns.swift, ProjectPanelMenus.swift, ProxyIntake.swift,
// RecentProjects.swift, ImportReport.swift, KeywordAtPlayhead.swift, StartProjectInfo.swift, LibraryStores.swift,
// EditorSession+Keyword.swift.
//! ES7: project panel model (columns, menus), proxy intake, recents, import report, keyword at playhead.

mod calendar;
mod columns;
mod folder_watch;
mod import;
mod import_report;
mod keyword_at_playhead;
mod library_stores;
mod menus;
mod model;
mod proxy_intake;
mod recent_projects;
mod start_project_info;
#[cfg(test)]
mod tests;

pub use calendar::*;
pub use columns::*;
pub use folder_watch::*;
pub use import::*;
pub use import_report::*;
pub use keyword_at_playhead::*;
pub use library_stores::*;
pub use menus::*;
pub use model::*;
pub use proxy_intake::*;
pub use recent_projects::*;
pub use start_project_info::*;

use crate::EditorSession;

impl EditorSession {
    /// Turns the transcript word under the playhead into a big text clip on the topmost free video track. One undo
    /// step; the new clip is selected.
    // Swift: EditorSession+Keyword.swift:8
    pub fn add_keyword_at_playhead(&mut self) -> bool {
        let Some(t) = self.active_timeline() else { return false };
        let (template, range) = match KeywordAtPlayhead::plan(t, self.playhead()) {
            Ok(plan) => plan,
            Err(message) => {
                self.set_error(message);
                return false;
            }
        };
        self.add_text_clip(&template, Some(range.start), None, range.duration, None, true).is_some()
    }
}
