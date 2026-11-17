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

/// A published version.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub struct UpdateRelease {
    // Swift: UpdateCheck.swift:29
    pub version: String,
    // Swift: UpdateCheck.swift:30
    pub url: String,
    // Swift: UpdateCheck.swift:31
    pub notes: Option<String>,
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

    /// The installer file ending of this system (.dmg, .exe or .AppImage).
    pub fn installer_suffix() -> &'static str {
        Platform::current().update_asset().suffix()
    }

    /// The address in use: `SQ_UPDATE_URL`, else the `sq.updateFeedURL` default, else `DEFAULT_FEED_URL`. Empty = inert.
    // Swift: UpdateCheck.swift:17
    pub fn feed_url(d: &dyn UiDefaults) -> String {
        env_var("SQ_UPDATE_URL")
            .or_else(|| d.string("sq.updateFeedURL"))
            .unwrap_or_else(|| Self::DEFAULT_FEED_URL.to_string())
    }

    /// A GitHub release as our release; the download is the installer asset when there is one.
    pub(crate) fn github_release(data: &[u8], suffix: &str) -> Option<UpdateRelease> {
        let g: GitHubRelease = serde_json::from_slice(data).ok()?;
        let suffix = suffix.to_lowercase();
        let asset = g
            .assets
            .unwrap_or_default()
            .into_iter()
            .find(|a| a.name.to_lowercase().ends_with(&suffix))
            .map(|a| a.browser_download_url);
        let notes = g.body.map(|b| b.trim().to_string()).filter(|b| !b.is_empty());
        Some(UpdateRelease { version: g.tag_name, url: asset.unwrap_or(g.html_url), notes })
    }

    // Swift: UpdateCheck.swift:56
    pub fn release(data: &[u8]) -> Option<UpdateRelease> {
        let r = serde_json::from_slice::<UpdateRelease>(data)
            .ok()
            .or_else(|| Self::github_release(data, Self::installer_suffix()))?;
        (!Self::parts(&r.version).is_empty() && r.url.starts_with("https://")).then_some(r)
    }

    /// Dotted numeric version parts; a leading "v" and a suffix after "-" or "+" are ignored. Empty when not numeric.
    pub(crate) fn parts(v: &str) -> Vec<i64> {
        let mut s = v.trim_matches(|c: char| c == ' ' || c == '\t');
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
        false
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
        if !feed.starts_with("https://") || feed.len() <= "https://".len() {
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
