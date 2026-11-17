// SPDX-License-Identifier: GPL-3.0-or-later
//! Default values Swift's decoders use for missing keys (`decodeIfPresent(..) ?? value`), named for serde attributes.

use crate::{BlendMode, ClipSpeed, TimeInterpolation};

/// `true`.
pub(crate) fn yes() -> bool {
    true
}

/// `ClipSpeed.normal`.
pub(crate) fn normal_speed() -> ClipSpeed {
    ClipSpeed::NORMAL
}

/// `TimeInterpolation.frameSampling`.
pub(crate) fn frame_sampling() -> TimeInterpolation {
    TimeInterpolation::FrameSampling
}

/// `BlendMode.normal`.
pub(crate) fn normal_blend() -> BlendMode {
    BlendMode::Normal
}
