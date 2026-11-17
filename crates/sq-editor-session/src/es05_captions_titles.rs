// Swift: EditorSession+Caption*.swift, CaptionMapping.swift, CaptionMonitorHit.swift, EditorSession+Title*.swift,
// EditorSession+TextPresets.swift, EditorSession+Graphics*.swift, GraphicLayerSelection.swift, GraphicPresets.swift,
// EditorSession+StyleKit.swift, EditorSession+Generators.swift and the other ES5 files of TASKS.md.
//! ES5: captions, titles, text, graphics, StyleKit, generators.

use std::collections::BTreeSet;

use sq_core_time::Id;

mod caption_style;
mod caption_style_tab;
mod captions;
mod common;
mod look_store_captions;
pub(crate) use common::generator_track;
mod generators;
mod graphic_presets;
mod templates;
#[cfg(test)]
mod tests;
pub(crate) use sq_core_audio::TimelineCaptionEditsExt as TimelineCaptionEdits;

pub use caption_style::*;
pub use caption_style_tab::*;
pub use captions::*;
pub use generators::*;
pub use graphic_presets::*;
pub use look_store_captions::LookStoreCaptions;
pub use templates::*;

/// The selected layers of one graphics clip, as the session sees them.
// Swift: GraphicLayerSelection.swift:5
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GraphicLayerSelection {
    // Swift: GraphicLayerSelection.swift:6
    pub clip: Id,
    // Swift: GraphicLayerSelection.swift:7
    pub layers: BTreeSet<Id>,
}

impl GraphicLayerSelection {
    // Swift: GraphicLayerSelection.swift:8
    pub fn new(clip: Id, layers: BTreeSet<Id>) -> GraphicLayerSelection {
        GraphicLayerSelection { clip, layers }
    }
}
