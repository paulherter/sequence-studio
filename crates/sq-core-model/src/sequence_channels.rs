// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: SequenceChannels.swift (type, channel count, fold and the Timeline accessor: task M-4)
//
// v82: the output channel layout of a sequence. Stored only when not Stereo, so untouched sequences encode as before; a
// sequence with Mono makes the file v82.

use crate::Timeline;
use serde::{Deserialize, Serialize};

/// Audio channel layout of a sequence.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ChannelLayout {
    /// Two channels.
    Stereo,
    /// One channel.
    Mono,
}

impl ChannelLayout {
    /// Every layout (Swift `allCases`).
    pub const ALL: [ChannelLayout; 2] = [ChannelLayout::Stereo, ChannelLayout::Mono];

    /// Output channels of the layout.
    pub fn channel_count(self) -> usize {
        match self {
            ChannelLayout::Mono => 1,
            ChannelLayout::Stereo => 2,
        }
    }

    /// The Mono mix law: the plain average (L + R) / 2. Full-scale correlated input (L = R = 1) stays at 1.0, so the sum
    /// never clips and needs no limiter of its own; opposite phase cancels, as it does on a mono speaker. (An equal-power
    /// -3 dB sum, 0.707 (L + R), would reach +3 dB on correlated material.)
    pub fn fold(left: f32, right: f32) -> f32 {
        (left + right) * 0.5
    }
}

impl Timeline {
    /// Output channels of the sequence (default Stereo).
    pub fn channel_layout(&self) -> ChannelLayout {
        self.channel_layout_store.unwrap_or(ChannelLayout::Stereo)
    }

    /// Sets the output channels; Stereo is stored as absent.
    pub fn set_channel_layout(&mut self, layout: ChannelLayout) {
        self.channel_layout_store = (layout != ChannelLayout::Stereo).then_some(layout);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::nesting::test_util::*;

    #[test]
    fn fold_is_the_plain_average() {
        assert_eq!(ChannelLayout::fold(1.0, 1.0), 1.0);
        assert_eq!(ChannelLayout::fold(1.0, -1.0), 0.0);
        assert_eq!(ChannelLayout::fold(0.5, 0.0), 0.25);
        assert_eq!((ChannelLayout::Stereo.channel_count(), ChannelLayout::Mono.channel_count()), (2, 1));
    }

    #[test]
    fn stereo_is_stored_as_absent() {
        let mut p = project_json(vec![], vec![timeline_json(1, vec![])]);
        let t = &mut p.timelines[0];
        assert_eq!(t.channel_layout(), ChannelLayout::Stereo);
        t.set_channel_layout(ChannelLayout::Mono);
        assert_eq!((t.channel_layout(), t.channel_layout_store), (ChannelLayout::Mono, Some(ChannelLayout::Mono)));
        t.set_channel_layout(ChannelLayout::Stereo);
        assert_eq!(t.channel_layout_store, None);
    }
}
