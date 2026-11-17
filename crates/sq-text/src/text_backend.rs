// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: TextBackend.swift

//! Seam between the portable layout (`TextLayout`) and the platform's text engine. The Rust port has one backend,
//! `text_backend_portable` (the Windows build of the Swift package is the reference product).

/// Vertical metrics of a font in points (y up, all positive).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TextFontMetrics {
    /// Ascent.
    pub ascent: f64,
    /// Descent.
    pub descent: f64,
    /// Leading.
    pub leading: f64,
}

/// What the line breaker needs from a typeset paragraph: widths of UTF-16 ranges.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TextLineMetrics {
    /// Typographic width of the line, trailing whitespace included.
    pub width: f64,
    /// Width of the trailing whitespace.
    pub trailing_whitespace: f64,
    /// Ascent.
    pub ascent: f64,
    /// Descent.
    pub descent: f64,
    /// Leading.
    pub leading: f64,
}

/// A typeset paragraph.
pub trait LineTypesetting {
    /// Metrics of the line made of `length` UTF-16 units from `location`.
    fn line(&self, location: i64, length: i64) -> TextLineMetrics;
}
