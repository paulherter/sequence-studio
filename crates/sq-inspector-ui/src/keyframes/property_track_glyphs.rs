// Swift: PropertyTrackGlyphs.swift
//! The lanes, the Graph Editor sampling and the draw-list Controls read the same glyphs.

use std::collections::BTreeSet;

use sq_core_model::keyframes_editing::PropertyTrack;
use sq_core_time::{Id, Time};
use sq_uikit::key_glyph::{KeyGlyph, KeyGlyphEntry};

/// One key a lane shows: id, clip-local time and glyph.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TrackGlyph {
    pub id: Id,
    pub time: Time,
    pub glyph: KeyGlyph,
}

impl From<KeyGlyphEntry> for TrackGlyph {
    fn from(e: KeyGlyphEntry) -> TrackGlyph {
        TrackGlyph { id: e.id, time: e.time, glyph: e.glyph }
    }
}

/// Id, clip-local time and glyph of every key a lane shows.
pub trait PropertyTrackGlyphs {
    fn glyphs(&self) -> Vec<TrackGlyph>;
}

impl PropertyTrackGlyphs for PropertyTrack {
    fn glyphs(&self) -> Vec<TrackGlyph> {
        let all: Vec<TrackGlyph> = match self {
            PropertyTrack::Scalar(t) => KeyGlyph::glyphs(t),
            PropertyTrack::Vector(t) => KeyGlyph::glyphs(t),
            PropertyTrack::Color(t) => KeyGlyph::glyphs(t),
            PropertyTrack::Path(t) => KeyGlyph::glyphs(t),
        }
        .into_iter()
        .map(TrackGlyph::from)
        .collect();
        let shown = self.times();
        if shown.len() == all.len() {
            return all;
        }
        let ids: BTreeSet<Id> = shown.iter().map(|(id, _)| *id).collect();
        all.into_iter().filter(|g| ids.contains(&g.id)).collect()
    }
}
