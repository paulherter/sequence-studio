// Swift: TimelineSignposts.swift
//! Instruments intervals of the timeline hot paths. Off Apple platforms the Swift code does nothing, and this port is
//! the portable path: the same calls, doing nothing.

/// Names: `scrollWheel`, `scroll`, `zoomStep`, `draw`, `headerSync`, `waveformColumns`, `waveformBucketBuild`.
pub struct TimelineSignpost;

impl TimelineSignpost {
    /// Runs `body` inside the named interval (no recording here).
    #[inline]
    pub fn interval<T>(_name: &'static str, body: impl FnOnce() -> T) -> T {
        body()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn interval_returns_the_body_result() {
        assert_eq!(TimelineSignpost::interval("draw", || 7), 7);
    }
}
