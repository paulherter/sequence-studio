// Swift: ScreenColorSampler.swift
//! The host window's screen color sampler (the Mac `SQLoupe`): drawn eyedropper buttons call `begin`, the host arms its
//! loupe and answers once with the picked color (`None` = canceled). Absent while the host cannot sample: the buttons hide.
//! The app owns one value (Windows: `InspectorHost`, GDI under the pointer).

use sq_uikit::sqcolor_value::SQColorValue;

/// Answers a sampling request once.
pub type SampleDone = Box<dyn FnOnce(Option<SQColorValue>)>;

/// Starts a sampling request.
pub type SampleBegin = Box<dyn Fn(SampleDone)>;

/// The host's sampler hook.
#[derive(Default)]
pub struct ScreenColorSampler {
    /// Arms the host's loupe; `None` while the host cannot sample.
    pub begin: Option<SampleBegin>,
}
