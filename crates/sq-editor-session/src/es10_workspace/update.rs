//! "Is there a newer version?", the first-run welcome content and the keyboard picture of the shortcuts window.

use std::future::Future;

use serde::Deserialize;
use sq_os::Platform;
use sq_uikit::appearance_palette::UiDefaults;

use super::storage::env_var;

/// "Is there a newer version?" against a configurable address. Default: the GitHub releases API of the public
/// repository; `SQ_UPDATE_URL` (environment) or the `sq.updateFeedURL` default replaces it, and an empty value switches
/// the check off (it never touches the network and the UI says so).
///
/// The address returns either our small document `{"version": "1.2.0", "url": "https://...", "notes": "optional"}` or a
/// GitHub release (`tag_name`, `html_url`, `body`, `assets`); for a GitHub release the download is the installer asset
/// of this system (`.exe` on Windows, `.AppImage` on Linux, `.dmg` on the Mac), else the release page.
// Swift: UpdateCheck.swift:12
pub enum UpdateCheck {}

/// Which stream of builds an install follows. The packager fixes the build's own channel (`SQ_CHANNEL` at compile time);
/// the user's update choice (Settings > General > Updates) may differ and picks the feed of the update check.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum ReleaseChannel {
    /// Released versions.
    #[default]
    Stable,
    /// Daily builds: newest changes, may break projects.
    Nightly,
}

impl ReleaseChannel {
    /// Both channels, in the order Settings lists them.
    pub const ALL: [ReleaseChannel; 2] = [Self::Stable, Self::Nightly];

    /// The channel this build was packaged for: `SQ_CHANNEL=nightly` at compile time, anything else is Stable.
    pub fn build() -> Self {
        Self::from_raw(option_env!("SQ_CHANNEL"))
    }

    /// "nightly" (any case) is Nightly; a missing or unknown value is Stable.
    pub fn from_raw(raw: Option<&str>) -> Self {
        match raw.map(|r| r.trim().to_lowercase()).as_deref() {
            Some("nightly") => Self::Nightly,
            _ => Self::Stable,
        }
    }

    /// The stored value.
    pub fn raw(self) -> &'static str {
        match self {
            Self::Stable => "stable",
            Self::Nightly => "nightly",
        }
    }

    /// The name Settings shows.
    pub fn title(self) -> &'static str {
        match self {
            Self::Stable => "Stable",
            Self::Nightly => "Nightly",
        }
    }

    /// Position in [`Self::ALL`].
    pub fn index(self) -> usize {
        Self::ALL.iter().position(|c| *c == self).unwrap_or(0)
    }

    /// The default update feed of this channel. Stable asks the latest GitHub release; Nightly asks the small document
    /// the nightly job publishes next to it (our `{"version", "url", "notes"}` form).
    pub fn default_feed_url(self) -> &'static str {
        match self {
            Self::Stable => UpdateCheck::DEFAULT_FEED_URL,
            Self::Nightly => UpdateCheck::NIGHTLY_FEED_URL,
        }
    }

    /// The warning before a switch to Nightly.
    pub const NIGHTLY_WARNING_TITLE: &'static str = "Switch to Nightly?";
    pub const NIGHTLY_WARNING: &'static str =
        "Nightly builds can break projects. Back up your projects before you switch.";
    pub const NIGHTLY_SWITCH_BUTTON: &'static str = "Switch to Nightly";

    /// The version string the update check compares: the packager's full `SQ_BUILD_VERSION` ("0.2.0-nightly.20261119") on
    /// a nightly build, else the display version.
    pub fn local_version() -> String {
        Self::local_version_of(
            Self::build(),
            option_env!("SQ_BUILD_VERSION"),
            &sq_uikit::app_version::AppVersion::display(),
        )
    }

    /// [`Self::local_version`] from its inputs (the build channel, the build string, the display version).
    pub fn local_version_of(channel: Self, build_version: Option<&str>, display: &str) -> String {
        match (channel, build_version.map(str::trim)) {
            (Self::Nightly, Some(v)) if !v.is_empty() => v.to_string(),
            _ => display.to_string(),
        }
    }

    /// The About line of this build: "Version 0.2.0 Alpha", plus " Nightly" on a nightly build.
    pub fn about_line() -> String {
        Self::about_line_of(
            Self::build(),
            &sq_uikit::app_version::AppVersion::about_line(),
            option_env!("SQ_BUILD_VERSION"),
        )
    }

    /// [`Self::about_line`] from its inputs: a nightly build shows its packager version, the same text as the status bar
    /// ("Version 0.2.1-nightly.20261121"); without a build string it adds " Nightly" to the line.
    pub fn about_line_of(channel: Self, line: &str, build_version: Option<&str>) -> String {
        if channel != Self::Nightly {
            return line.to_string();
        }
        match build_version.map(str::trim) {
            Some(v) if !v.is_empty() => format!("Version {v}"),
            _ => format!("{line} Nightly"),
        }
    }
}

/// What the app needs to install a release in place: the installer asset with the hash the feed publishes for it and the
/// address of its detached signature. A release without all three can only be opened as a link.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub struct UpdateInstall {
    /// The asset's file name.
    pub name: String,
    /// The asset's download address.
    pub url: String,
    /// The SHA-256 of the file, lowercase hex.
    pub sha256: String,
    /// The address of the signature file (`<asset>.sig`).
    pub sig_url: String,
    /// The size in bytes, when the feed says.
    pub size: Option<u64>,
}

/// A published version.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub struct UpdateRelease {
    // Swift: UpdateCheck.swift:29
    pub version: String,
    // Swift: UpdateCheck.swift:30
    pub url: String,
    // Swift: UpdateCheck.swift:31
    pub notes: Option<String>,
    /// The in-place install data; `None` when the feed has no verifiable installer for this system.
    #[serde(default)]
    pub install: Option<UpdateInstall>,
}

/// Result of a check.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum UpdateOutcome {
    /// The address is empty or not https: nothing was asked.
    NotConfigured,
    /// This is the newest version.
    UpToDate,
    /// A newer version exists.
    Available(UpdateRelease),
    /// The answer could not be read.
    Failed,
}

#[derive(Deserialize)]
struct GitHubAsset {
    name: String,
    browser_download_url: String,
    digest: Option<String>,
    size: Option<u64>,
}

#[derive(Deserialize)]
struct GitHubRelease {
    tag_name: String,
    html_url: String,
    body: Option<String>,
    assets: Option<Vec<GitHubAsset>>,
}

impl UpdateCheck {
    // Swift: UpdateCheck.swift:14
    pub const DEFAULT_FEED_URL: &'static str =
        "https://api.github.com/repos/paulherter/sequence-studio/releases/latest";

    /// The nightly document: same scheme as the stable feed, a release tagged `nightly` that is replaced every night.
    pub const NIGHTLY_FEED_URL: &'static str =
        "https://github.com/paulherter/sequence-studio/releases/download/nightly/nightly.json";

    /// The installer file ending of this system (.dmg, .exe or .AppImage).
    pub fn installer_suffix() -> &'static str {
        Platform::current().update_asset().suffix()
    }

    /// The address in use for the channel the user chose (the stored `update_channel`, else this build's channel).
    pub fn feed_url(d: &dyn UiDefaults) -> String {
        let channel = d
            .string(super::settings::AppSettingsKey::UPDATE_CHANNEL)
            .map_or_else(ReleaseChannel::build, |r| ReleaseChannel::from_raw(Some(&r)));
        Self::feed_url_for(channel, d)
    }

    /// The address of `channel`: `SQ_UPDATE_URL`, else the `sq.updateFeedURL` default (both replace either channel's
    /// address), else the channel's own. Empty = inert.
    // Swift: UpdateCheck.swift:17
    pub fn feed_url_for(channel: ReleaseChannel, d: &dyn UiDefaults) -> String {
        env_var("SQ_UPDATE_URL")
            .or_else(|| d.string("sq.updateFeedURL"))
            .unwrap_or_else(|| channel.default_feed_url().to_string())
    }

    /// Whether `url` may be fetched: always `https://`; `http://127.0.0.1:<port>/` only while `SQ_UPDATE_TEST_LOCALHOST=1`
    /// is set (a local test feed); nothing else, never another host.
    pub fn url_allowed(url: &str) -> bool {
        Self::url_allowed_with(url, env_var("SQ_UPDATE_TEST_LOCALHOST").as_deref() == Some("1"))
    }

    /// [`Self::url_allowed`] with the switch given.
    pub fn url_allowed_with(url: &str, localhost_test: bool) -> bool {
        if let Some(rest) = url.strip_prefix("https://") {
            return !rest.is_empty();
        }
        let Some(rest) = url.strip_prefix("http://127.0.0.1:") else { return false };
        let (port, _) = rest.split_once('/').unwrap_or((rest, ""));
        localhost_test && !port.is_empty() && port.bytes().all(|b| b.is_ascii_digit())
    }

    /// A GitHub release as our release; the download is the installer asset when there is one.
    pub(crate) fn github_release(data: &[u8], suffix: &str) -> Option<UpdateRelease> {
        let g: GitHubRelease = serde_json::from_slice(data).ok()?;
        let suffix = suffix.to_lowercase();
        let assets = g.assets.unwrap_or_default();
        let asset = assets
            .iter()
            .find(|a| a.name.to_lowercase().ends_with(&suffix) && Self::url_allowed(&a.browser_download_url));
        let install = asset.and_then(|a| {
            let sha256 = a.digest.as_deref()?.strip_prefix("sha256:")?.trim().to_lowercase();
            let sig_name = format!("{}.sig", a.name);
            let sig = assets.iter().find(|s| s.name == sig_name && Self::url_allowed(&s.browser_download_url))?;
            Some(UpdateInstall {
                name: a.name.clone(),
                url: a.browser_download_url.clone(),
                sha256,
                sig_url: sig.browser_download_url.clone(),
                size: a.size,
            })
        });
        let url = asset.map(|a| a.browser_download_url.clone());
        let notes = g.body.map(|b| b.trim().to_string()).filter(|b| !b.is_empty());
        Some(UpdateRelease { version: g.tag_name, url: url.unwrap_or(g.html_url), notes, install })
    }

    // Swift: UpdateCheck.swift:56
    pub fn release(data: &[u8]) -> Option<UpdateRelease> {
        let r = serde_json::from_slice::<UpdateRelease>(data)
            .ok()
            .or_else(|| Self::github_release(data, Self::installer_suffix()))?;
        (!Self::parts(&r.version).is_empty() && Self::url_allowed(&r.url)).then_some(r)
    }

    /// The date of a nightly version ("0.2.0-nightly.20261119" gives 20261119); `None` for any other version.
    pub(crate) fn nightly_stamp(v: &str) -> Option<u64> {
        let rest = v.split_once("-nightly.")?.1;
        let digits: String = rest.chars().take_while(char::is_ascii_digit).collect();
        digits.parse().ok()
    }

    /// Dotted numeric version parts; a leading "v", a suffix after "-" or "+" and a stage word after a space ("0.2.0 Alpha")
    /// are ignored. Empty when not numeric.
    pub(crate) fn parts(v: &str) -> Vec<i64> {
        let mut s = v.split_whitespace().next().unwrap_or("");
        if s.starts_with(['v', 'V']) {
            s = &s[1..];
        }
        if let Some(i) = s.find(['-', '+']) {
            s = &s[..i];
        }
        let nums: Vec<Option<i64>> = s.split('.').map(|p| p.parse::<i64>().ok()).collect();
        if nums.contains(&None) { Vec::new() } else { nums.into_iter().flatten().collect() }
    }

    /// True when `remote` is a higher version than `local`. A version that cannot be read is never newer.
    // Swift: UpdateCheck.swift:73
    pub fn is_newer(remote: &str, local: &str) -> bool {
        let (r, l) = (Self::parts(remote), Self::parts(local));
        if r.is_empty() || l.is_empty() {
            return false;
        }
        for i in 0..r.len().max(l.len()) {
            let a = r.get(i).copied().unwrap_or(0);
            let b = l.get(i).copied().unwrap_or(0);
            if a != b {
                return a > b;
            }
        }
        // Same numbers: a nightly is older than the release of its number and a newer nightly beats an older one.
        match (Self::nightly_stamp(remote), Self::nightly_stamp(local)) {
            (Some(a), Some(b)) => a > b,
            (None, Some(_)) => true,
            _ => false,
        }
    }

    // Swift: UpdateCheck.swift:82
    pub fn outcome(data: &[u8], local_version: &str) -> UpdateOutcome {
        match Self::release(data) {
            None => UpdateOutcome::Failed,
            Some(r) if Self::is_newer(&r.version, local_version) => UpdateOutcome::Available(r),
            Some(_) => UpdateOutcome::UpToDate,
        }
    }

    /// Fetches `feed` and compares it with `local_version`. `fetch` is the app's HTTP GET (`None` = it failed); it is
    /// only called for an https address.
    // Swift: UpdateCheck.swift:89
    pub async fn check<F, Fut>(local_version: &str, feed: &str, fetch: F) -> UpdateOutcome
    where
        F: FnOnce(String) -> Fut,
        Fut: Future<Output = Option<Vec<u8>>>,
    {
        if !Self::url_allowed(feed) {
            return UpdateOutcome::NotConfigured;
        }
        match fetch(feed.to_string()).await {
            Some(data) => Self::outcome(&data, local_version),
            None => UpdateOutcome::Failed,
        }
    }
}

/// First-run welcome content (Help > Welcome Tour): where to start and the few keys worth knowing. Plain data so a
/// test pins its shape. Key names follow the platform (Cmd on the Mac, Ctrl elsewhere).
// Swift: OnboardingContent.swift:8
pub enum OnboardingContent {}

/// One welcome tip.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OnboardingTip {
    // Swift: OnboardingContent.swift:9
    pub title: String,
    // Swift: OnboardingContent.swift:10
    pub detail: String,
}

impl OnboardingContent {
    // Swift: OnboardingContent.swift:12
    pub const TITLE: &'static str = "Welcome to Sequence Studio";
    // Swift: OnboardingContent.swift:14
    pub const INTRO: &'static str = "A short start. You can skip this and find everything in the menus.";
    // Swift: OnboardingContent.swift:27
    pub const START_BUTTON: &'static str = "Get Started";
    // Swift: OnboardingContent.swift:29
    pub const SKIP_BUTTON: &'static str = "Skip";

    /// The tips for the system this build runs on.
    // Swift: OnboardingContent.swift:15
    pub fn tips() -> Vec<OnboardingTip> {
        Self::tips_for(Platform::current())
    }

    // Swift: OnboardingContent.swift:16
    pub fn tips_for(platform: Platform) -> Vec<OnboardingTip> {
        let m = platform.command_name();
        let tip = |title: &str, detail: String| OnboardingTip { title: title.to_string(), detail };
        vec![
            tip("Import", format!("File > Import Media ({m}+I), or drop files into the Project panel.")),
            tip(
                "Edit",
                "Drag a clip to the timeline. K stops, J and L play backward and forward, C cuts at the playhead."
                    .to_string(),
            ),
            tip("Undo", format!("{m}+Z steps back. Window > History lists every step, click one to jump to it.")),
            tip("Shortcuts", "Help shows all keys, and every one can be changed in Keyboard Shortcuts.".to_string()),
            tip("Export", format!("{m}+M opens Export when the sequence is ready.")),
        ]
    }
}

#[cfg(test)]
mod about_line_tests {
    use super::*;

    #[test]
    fn about_names_the_nightly_version_and_leaves_stable_alone() {
        let line = "Version 0.2.1 Alpha";
        assert_eq!(
            ReleaseChannel::about_line_of(ReleaseChannel::Nightly, line, Some("0.2.1-nightly.20261121")),
            "Version 0.2.1-nightly.20261121"
        );
        assert_eq!(ReleaseChannel::about_line_of(ReleaseChannel::Nightly, line, None), "Version 0.2.1 Alpha Nightly");
        assert_eq!(ReleaseChannel::about_line_of(ReleaseChannel::Stable, line, Some("0.2.1-nightly.20261121")), line);
    }
}

#[cfg(test)]
mod nightly_feed_tests {
    use super::*;

    /// The document scripts/nightly.sh writes: tag_name is the version, html_url and assets sit under the nightly-YYYYMMDD release.
    fn nightly_json(tag_name: &str) -> String {
        let base = "https://github.com/paulherter/sequence-studio/releases/download/nightly-20261121";
        let asset = |name: &str| {
            format!(
                r#"{{"name":"{name}","size":1234,"digest":"sha256:{}","browser_download_url":"{base}/{name}"}}"#,
                "ab".repeat(32)
            )
        };
        let names = [
            "SequenceStudio-Nightly-mac.dmg",
            "SequenceStudio-Nightly-linux-x86_64.AppImage",
            "SequenceStudio-Nightly-windows-setup.exe",
        ];
        let assets: Vec<String> = names.iter().flat_map(|n| [asset(n), asset(&format!("{n}.sig"))]).collect();
        format!(
            r#"{{"tag_name":"{tag_name}","html_url":"https://github.com/paulherter/sequence-studio/releases/tag/nightly-20261121","prerelease":true,"body":"Nightly build","assets":[{}]}}"#,
            assets.join(",")
        )
    }

    #[test]
    fn the_nightly_feed_with_the_version_as_tag_name_is_a_release_with_this_systems_installer() {
        let r = UpdateCheck::release(nightly_json("0.2.1-nightly.20261121").as_bytes()).expect("a release");
        assert_eq!(r.version, "0.2.1-nightly.20261121");
        let install = r.install.expect("the installer of this platform");
        assert!(install.name.ends_with(UpdateCheck::installer_suffix()), "{}", install.name);
        assert!(install.sig_url.ends_with(&format!("{}.sig", install.name)));
    }

    #[test]
    fn the_nightly_feed_with_the_release_tag_as_tag_name_is_rejected() {
        assert!(UpdateCheck::release(nightly_json("nightly-20261121").as_bytes()).is_none());
    }
}
