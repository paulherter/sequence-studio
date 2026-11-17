// Swift: DuckCurveSource.swift
//! Where the live duck is, drawn on each ducked Music track: a thin amber line that dips under speaking dialogue (the
//! same curve the mix applies, `LiveDucking::curve`). Read-only; to edit it, bake it into volume keys.

use sq_core_audio::live_ducking::{DialogueSilenceProvider, LiveDucking};
use std::rc::Rc;

pub struct DuckCurveSource {
    /// The setting in force (project or Preferences), read at draw time; `None` = off.
    pub ducking: Box<dyn Fn() -> Option<LiveDucking>>,
    /// Pauses inside dialogue clips (the mix's own provider), so the curve is what is heard.
    pub silences: Option<Rc<dyn DialogueSilenceProvider>>,
}

impl DuckCurveSource {
    pub fn new(
        ducking: Box<dyn Fn() -> Option<LiveDucking>>,
        silences: Option<Rc<dyn DialogueSilenceProvider>>,
    ) -> Self {
        DuckCurveSource { ducking, silences }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_setting_at_call_time() {
        let s = DuckCurveSource::new(Box::new(|| None), None);
        assert!((s.ducking)().is_none());
        assert!(s.silences.is_none());
    }
}
