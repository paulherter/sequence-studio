// Swift: EditorSession+FastCut.swift, TimelineEdit+FastCut.swift, EditorSession+Speed*.swift, SpeedBand.swift,
// SpeedDialogModel.swift, EditorSession+JumpCut.swift, EditorSession+CutCheck.swift, EditorSession+MusicFit.swift,
// EditorSession+BeatGrid.swift and the other ES3 files of TASKS.md.
//! ES3: Fast Cut, speed (dialog, bands, points, presets), jump cut, cut check, music fit, beat grid.

use sq_core_model::{Clip, Timeline};
use sq_core_time::Id;

mod analysis;
mod conform;
mod fast_cut;
mod session_speed;
mod speed_band;
mod speed_dialog;
mod speed_edit;
#[cfg(test)]
mod tests;

pub use analysis::*;
pub use conform::*;
pub use fast_cut::*;
pub use session_speed::*;
pub use speed_band::*;
pub use speed_dialog::*;
pub use speed_edit::*;

/// The clip with `id` in `t`.
pub(crate) fn clip_in(t: &Timeline, id: Id) -> Option<&Clip> {
    t.tracks.iter().flat_map(|tr| tr.clips()).find(|c| c.id == id)
}
