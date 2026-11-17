//! Port of `SQUIKit/Sources/SQUIKit/AppVersion.swift`.
//! The portable path has no app bundle (Swift reads `Bundle.main` only on the Mac): the number is the fallback and the
//! build is empty, exactly as in the Swift tests and on Windows.

/// The one source of the app version. Every place that shows a version reads this (status bar, splash,
/// start window, About, feedback mail, launch log).
pub struct AppVersion;

impl AppVersion {
    /// Release stage shown after the number.
    pub const STAGE: &'static str = "Alpha";

    /// Used when the process has no bundle version (tests, command-line tools, Windows): the workspace version,
    /// the same number packaging writes into the Mac bundle and the installers.
    pub const FALLBACK_NUMBER: &'static str = env!("CARGO_PKG_VERSION");

    /// Marketing version, "0.1".
    pub fn number() -> String {
        Self::number_from(None)
    }

    /// Build number set by packaging; empty without a bundle, so the About line leaves the "(build)" part out.
    pub fn build() -> String {
        String::new()
    }

    /// "0.1 Alpha".
    pub fn display() -> String {
        Self::display_of(&Self::number())
    }

    /// "Sequence Studio 0.1 Alpha".
    pub fn full_name() -> String {
        format!("Sequence Studio {}", Self::display())
    }

    /// "Version 0.1 Alpha (1)", the About line.
    pub fn about_line() -> String {
        let build = Self::build();
        if build.is_empty() {
            format!("Version {}", Self::display())
        } else {
            format!("Version {} ({build})", Self::display())
        }
    }

    /// The number from a bundle's short version string; the fallback when it is missing or empty.
    pub fn number_from(short_version: Option<&str>) -> String {
        match short_version {
            Some(v) if !v.is_empty() => v.to_string(),
            _ => Self::FALLBACK_NUMBER.to_string(),
        }
    }

    pub fn display_of(number: &str) -> String {
        format!("{number} {}", Self::STAGE)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn display_joins_number_and_stage() {
        assert_eq!(AppVersion::display_of("0.1"), "0.1 Alpha");
        assert_eq!(AppVersion::number_from(Some("0.10")), "0.10");
        assert_eq!(AppVersion::number_from(None), AppVersion::FALLBACK_NUMBER);
    }

    #[test]
    fn about_line_leaves_out_an_empty_build() {
        assert_eq!(AppVersion::FALLBACK_NUMBER, "0.2.0");
        assert!(AppVersion::build().is_empty());
        assert_eq!(AppVersion::about_line(), format!("Version {}", AppVersion::display()));
        assert!(!AppVersion::about_line().contains('?'));
        assert_eq!(AppVersion::full_name(), "Sequence Studio 0.2.0 Alpha");
    }
}
