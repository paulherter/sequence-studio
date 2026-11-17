//! Edit helpers every ES4 file shares.

use sq_core_model::Clip;
use sq_core_time::Id;

use crate::EditorSession;

impl EditorSession {
    /// The clip `id` of the active sequence.
    pub(crate) fn clip_in_active(&self, id: Id) -> Option<Clip> {
        self.active_timeline()?.tracks.iter().find_map(|t| t.clip(id)).cloned()
    }

    /// A unique key for one gesture's merged undo step: `prefix:id:counter`.
    pub(crate) fn gesture_key(&mut self, prefix: &str, id: Id, continues_gesture: bool) -> String {
        if !continues_gesture {
            self.gesture_counter += 1;
        }
        format!("{prefix}:{id}:{}", self.gesture_counter)
    }
}
