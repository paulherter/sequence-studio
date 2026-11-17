//! Port of `CoverFrame.swift`: the cover image of an export (a poster frame saved next to the video). The frame is chosen
//! with a sequence marker named "Cover"; without one the first exported frame is used. No file-format field: the marker
//! is the setting.

use sq_core_model::{Marker, trim_spaces};
use sq_core_time::Time;

/// `enum CoverFrame`.
pub struct CoverFrame;

impl CoverFrame {
    /// The marker name that selects the cover frame.
    pub const MARKER_NAME: &'static str = "Cover";

    /// Time of the earliest marker named "Cover" (case and surrounding spaces ignored), or `None`.
    pub fn time(markers: &[Marker]) -> Option<Time> {
        markers
            .iter()
            .filter(|m| trim_spaces(&m.name, false).to_lowercase() == Self::MARKER_NAME.to_lowercase())
            .map(|m| m.time)
            .min()
    }

    /// Index of the cover frame inside the exported frames (frame 0 = `range_start`), clamped to the range.
    pub fn frame_index(time: Option<Time>, range_start: Time, frame_duration: Time, frame_count: i64) -> i64 {
        let Some(time) = time.filter(|_| frame_count > 0 && frame_duration.value() > 0) else { return 0 };
        let rel = time - range_start;
        if rel.is_negative() {
            return 0;
        }
        rel.frame_index(frame_duration).clamp(0, frame_count - 1)
    }

    /// "Trip" -> "Trip Cover.png".
    pub fn file_name(video_stem: &str, ext: &str) -> String {
        format!("{video_stem} Cover.{ext}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::MarkerColor;
    use sq_core_time::SequentialIds;

    const FD: Time = Time::new(1, 30);

    fn marker(ids: &mut SequentialIds, t: i64, name: &str) -> Marker {
        use sq_core_time::IdSource;
        Marker {
            id: ids.next_id(),
            time: Time::new(t, 1),
            name: name.to_string(),
            color: MarkerColor::default(),
            comment: String::new(),
            duration: Time::ZERO,
        }
    }

    #[test]
    fn finds_marker_named_cover() {
        let mut ids = SequentialIds::default();
        let ms = [marker(&mut ids, 1, "Intro"), marker(&mut ids, 5, "Cover")];
        assert_eq!(CoverFrame::time(&ms), Some(Time::new(5, 1)));
    }

    #[test]
    fn name_match_ignores_case_and_spaces() {
        let mut ids = SequentialIds::default();
        assert_eq!(CoverFrame::time(&[marker(&mut ids, 2, "  cover ")]), Some(Time::new(2, 1)));
    }

    #[test]
    fn earliest_cover_wins() {
        let mut ids = SequentialIds::default();
        let ms = [marker(&mut ids, 9, "Cover"), marker(&mut ids, 3, "Cover")];
        assert_eq!(CoverFrame::time(&ms), Some(Time::new(3, 1)));
    }

    #[test]
    fn no_cover_marker_gives_none() {
        let mut ids = SequentialIds::default();
        assert_eq!(CoverFrame::time(&[marker(&mut ids, 1, "Cover art")]), None);
        assert_eq!(CoverFrame::time(&[]), None);
    }

    #[test]
    fn index_is_relative_to_range_start() {
        // Cover at 5 s, export range starts at 2 s: frame 90.
        assert_eq!(CoverFrame::frame_index(Some(Time::new(5, 1)), Time::new(2, 1), FD, 1000), 90);
    }

    #[test]
    fn index_falls_back_to_first_frame() {
        assert_eq!(CoverFrame::frame_index(None, Time::ZERO, FD, 100), 0);
    }

    #[test]
    fn index_clamps_into_the_exported_range() {
        assert_eq!(CoverFrame::frame_index(Some(Time::new(1, 1)), Time::new(2, 1), FD, 100), 0);
        assert_eq!(CoverFrame::frame_index(Some(Time::new(60, 1)), Time::ZERO, FD, 100), 99);
        assert_eq!(CoverFrame::frame_index(Some(Time::new(1, 1)), Time::ZERO, FD, 0), 0);
    }

    #[test]
    fn cover_file_name_shares_the_video_stem() {
        assert_eq!(CoverFrame::file_name("Trip", "png"), "Trip Cover.png");
        assert_eq!(CoverFrame::file_name("Trip", "jpg"), "Trip Cover.jpg");
    }
}
