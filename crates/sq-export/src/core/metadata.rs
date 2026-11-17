// Swift: ExportMetadata.swift

use serde::{Deserialize, Serialize};

/// Descriptive metadata written into the exported file: title, comment, creation date, and the chapter list.
///
/// The marker-based constructor (`YouTubeChapters`) lives with the text writers in `formats`.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ExportMetadata {
    /// Title.
    pub title: String,
    /// Comment.
    pub comment: String,
    /// Creation date as Swift's default `Date` coding writes it: seconds since 2001-01-01 00:00:00 UTC.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub creation_date: Option<f64>,
    /// Chapter list text (`M:SS Title` lines), appended to the comment.
    // Same as Swift (ExportMetadata.swift:13): chapters travel as text in the description field, not as a chapter track; upgrade when a player needs the track.
    pub chapter_text: String,
}

impl ExportMetadata {
    /// Metadata from its four parts.
    pub fn new(title: &str, comment: &str, creation_date: Option<f64>, chapter_text: &str) -> ExportMetadata {
        ExportMetadata {
            title: title.to_string(),
            comment: comment.to_string(),
            creation_date,
            chapter_text: chapter_text.to_string(),
        }
    }

    /// Nothing to write.
    pub fn is_empty(&self) -> bool {
        self.title.is_empty() && self.comment.is_empty() && self.creation_date.is_none() && self.chapter_text.is_empty()
    }

    /// Title, comment (with chapters) and creation time as the container tags the encoder writes.
    pub fn container_tags(&self) -> (String, String, String) {
        (self.title.clone(), self.full_comment(), self.creation_iso8601().unwrap_or_default())
    }

    /// Creation date as ISO 8601 UTC (`2026-01-02T03:04:05Z`), the form containers store it in.
    pub fn creation_iso8601(&self) -> Option<String> {
        // Seconds from 1970-01-01 to the Swift reference date 2001-01-01.
        let unix = (self.creation_date? + 978_307_200.0).floor() as i64;
        let (days, secs) = (unix.div_euclid(86_400), unix.rem_euclid(86_400));
        // Civil date from days since the epoch (Howard Hinnant's algorithm).
        let z = days + 719_468;
        let era = z.div_euclid(146_097);
        let doe = z.rem_euclid(146_097);
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        let mp = (5 * doy + 2) / 153;
        let day = doy - (153 * mp + 2) / 5 + 1;
        let month = if mp < 10 { mp + 3 } else { mp - 9 };
        let year = yoe + era * 400 + i64::from(month <= 2);
        Some(format!("{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z", secs / 3600, secs / 60 % 60, secs % 60))
    }

    /// Comment with the chapter list after it, blank line between.
    pub fn full_comment(&self) -> String {
        [self.comment.as_str(), self.chapter_text.as_str()]
            .into_iter()
            .filter(|s| !s.is_empty())
            .collect::<Vec<_>>()
            .join("\n\n")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn creation_date_is_written_as_utc_iso_8601() {
        // 2026-01-02T03:04:05Z is 1_767_323_045 s after 1970; the reference date is 978_307_200 s after it.
        let m = ExportMetadata::new("", "", Some(1_767_323_045.0 - 978_307_200.0), "");
        assert_eq!(m.creation_iso8601().as_deref(), Some("2026-01-02T03:04:05Z"));
        let leap = ExportMetadata::new("", "", Some(0.0), "");
        assert_eq!(leap.creation_iso8601().as_deref(), Some("2001-01-01T00:00:00Z"));
        assert_eq!(ExportMetadata::default().creation_iso8601(), None);
    }

    #[test]
    fn full_comment_joins_comment_and_chapters_with_a_blank_line() {
        let m = ExportMetadata::new("T", "note", None, "0:00 Intro");
        assert_eq!(m.full_comment(), "note\n\n0:00 Intro");
        assert_eq!(ExportMetadata::new("", "", None, "0:00 A").full_comment(), "0:00 A");
    }
}
