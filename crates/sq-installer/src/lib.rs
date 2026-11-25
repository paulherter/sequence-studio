//! The Sequence Studio setup program. One state machine ([`machine`]), the text of every screen as data ([`model`]), the
//! drawing and input ([`view`]) and the window ([`window`]). The Windows installer and uninstaller are the `sq-installer`
//! binary; the Linux first-run flow of the app opens the same window from `sequence-studio`.
//! Design: `design/installer/spec.md`.

pub mod app;
pub mod args;
pub mod machine;
pub mod model;
pub mod session;
pub mod shots;
pub mod view;
pub mod wait;

#[cfg(windows)]
pub mod windows;

#[cfg(unix)]
pub mod linux;

use sq_setup_engine::Version;

/// The version a setup program carries: the packager's full `SQ_BUILD_VERSION` ("0.2.1-nightly.20261121") when it set one,
/// else the workspace version. A Nightly setup must carry the prerelease, or the app's channel check refuses its update.
pub fn build_version() -> Version {
    version_of(option_env!("SQ_BUILD_VERSION"), env!("CARGO_PKG_VERSION"))
}

/// [`build_version`] from its inputs; an empty or unreadable build string falls back to the workspace version.
pub fn version_of(build: Option<&str>, workspace: &str) -> Version {
    build
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .and_then(Version::parse)
        .or_else(|| Version::parse(workspace))
        .unwrap_or_else(|| Version::new(0, 0, 0))
}

#[cfg(test)]
mod version_tests {
    use super::*;

    #[test]
    fn a_nightly_setup_carries_the_build_version_with_its_prerelease() {
        let v = version_of(Some("0.2.1-nightly.20261121"), "0.2.1");
        assert_eq!(v.pre.as_deref(), Some("nightly.20261121"));
        assert_eq!((v.major, v.minor, v.patch), (0, 2, 1));
    }

    #[test]
    fn without_a_build_version_the_workspace_version_is_used() {
        assert_eq!(version_of(None, "0.2.1"), Version::new(0, 2, 1));
        assert_eq!(version_of(Some("  "), "0.2.1"), Version::new(0, 2, 1));
        assert_eq!(version_of(Some("junk"), "0.2.1"), Version::new(0, 2, 1));
    }
}
