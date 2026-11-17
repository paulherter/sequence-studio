// Swift: SlipTwoUp.swift
//! What the two-up viewer shows during a Slip drag.

use crate::timeline_interaction::TimelineInteraction;
use sq_core_model::Clip;
use sq_core_time::{Id, Time};

/// What the two-up viewer shows during a Slip drag: the first and last frame of the clip as it will be after the slip.
/// The clip does not move on the timeline, its content does, so both pictures come from the preview timeline at fixed
/// sequence times (`head_time`, `tail_time`). `source_head` / `source_tail` are the media times behind them, for the labels.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct SlipTwoUp {
    /// The slipped clip.
    pub clip: Id,
    /// Sequence time of the clip's first frame.
    pub head_time: Time,
    /// Sequence time of the clip's last frame (never before `head_time`).
    pub tail_time: Time,
    /// Media time of the first visible frame (for a reversed clip the head is the later one).
    pub source_head: Time,
    /// Media time of the last visible frame.
    pub source_tail: Time,
    /// Slip applied so far (source start now minus at mouse down); zero = nothing moved yet.
    pub offset: Time,
}

impl SlipTwoUp {
    /// The two-up state of `c` after the slip so far.
    pub fn new(c: &Clip, frame_duration: Time, start_source: Time) -> SlipTwoUp {
        let fd = frame_duration;
        let last_step = c.speed.scale(fd);
        let (source_head, source_tail) = if c.reversed {
            (c.source.end() - last_step, c.source.start)
        } else {
            (c.source.start, c.source.end() - last_step)
        };
        SlipTwoUp {
            clip: c.id,
            head_time: c.start,
            tail_time: c.start.max(c.timeline().end() - fd),
            source_head,
            source_tail,
            offset: c.source.start - start_source,
        }
    }

    /// "+12 f" / "-3 f" readout; whole frames.
    pub fn offset_label(&self, frame_duration: Time) -> String {
        TimelineInteraction::frame_text(self.offset, frame_duration)
    }
}
