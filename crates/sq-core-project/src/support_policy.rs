// Swift: SupportPolicy.swift (links are plain strings: no URL type in the portable crates)
//! Rules for the Support entries (heart button, Help menu, project chooser) and the gentle post-export reminder.
//! Pure: dates and links are injected so tests need no clock and no UI.

use sq_core_time::Timestamp;

/// The quiet "Enjoying Sequence Studio? Support it" line after an export.
pub struct SupportReminder;

impl SupportReminder {
    /// Defaults key (a Date) of the last time the reminder was shown.
    pub const DEFAULTS_KEY: &'static str = "sq.support.lastReminder";
    /// Defaults key (a Bool): the user chose "Don't show again".
    pub const OFF_KEY: &'static str = "sq.support.reminderOff";
    /// At most one reminder per this many seconds (7 days).
    pub const INTERVAL: f64 = 7.0 * 24.0 * 3600.0;

    /// True when the export-done notice may carry the quiet "Enjoying Sequence Studio? Support it" line.
    /// Never after a failed or canceled export, never once turned off; never twice within `INTERVAL` (a clock set back
    /// counts as "just shown").
    pub fn may_show(export_succeeded: bool, last_shown: Option<Timestamp>, now: Timestamp, turned_off: bool) -> bool {
        if !export_succeeded || turned_off {
            return false;
        }
        let Some(last) = last_shown else { return true };
        now.reference_seconds() - last.reference_seconds() >= Self::INTERVAL
    }

    /// The slot is recorded only once the line is built and its window is visible (not minimized, not hidden).
    pub fn should_record(line_shown: bool, window_visible: bool) -> bool {
        line_shown && window_visible
    }
}

/// The entries behind the heart button and the Help menu group, in order. Discord is left out while its URL is `None`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum SupportEntry {
    Support,
    Discord,
    Github,
}

impl SupportEntry {
    /// Every entry in menu order.
    pub const ALL: [SupportEntry; 3] = [SupportEntry::Support, SupportEntry::Discord, SupportEntry::Github];

    /// The entries shown when the Discord link is `discord`.
    pub fn visible(discord: Option<&str>) -> Vec<SupportEntry> {
        Self::ALL.into_iter().filter(|e| *e != SupportEntry::Discord || discord.is_some()).collect()
    }

    /// One wording and symbol per entry for all places (heart menu, Help menu, chooser card), so they cannot drift apart.
    pub fn menu_title(self) -> &'static str {
        match self {
            SupportEntry::Support => "Support Sequence Studio",
            SupportEntry::Discord => "Join the Discord",
            SupportEntry::Github => "View on GitHub",
        }
    }

    /// Help menu items end in an ellipsis only for the one that opens a page of its own.
    pub fn help_title(self) -> String {
        if self == SupportEntry::Support {
            format!("{}\u{2026}", self.menu_title())
        } else {
            self.menu_title().to_string()
        }
    }

    /// Title on the chooser card.
    pub fn card_title(self) -> &'static str {
        match self {
            SupportEntry::Support => "Support",
            SupportEntry::Discord => "Discord",
            SupportEntry::Github => "GitHub",
        }
    }

    /// Icon name.
    pub fn symbol(self) -> &'static str {
        match self {
            SupportEntry::Support => "heart",
            SupportEntry::Discord => "discord",
            SupportEntry::Github => "github",
        }
    }
}

/// Which window carries a launch-time recovery or crash-report prompt.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PromptHost {
    StartWindow,
    EditorWindow,
}

/// What the project chooser overlay does to the editor behind it.
pub struct StartOverlayPolicy;

impl StartOverlayPolicy {
    /// Esc closes the chooser only when a real project is open behind it (reopened from the menu). At launch it cannot.
    pub fn escape_closes(has_real_project: bool) -> bool {
        has_real_project
    }

    /// With no project open the prompt sits on the start window (the editor window must not open before the user chooses
    /// to recover).
    pub fn recovery_prompt_host(has_real_project: bool) -> PromptHost {
        if has_real_project { PromptHost::EditorWindow } else { PromptHost::StartWindow }
    }

    /// While the chooser is up the editor takes no mouse and no keyboard commands.
    pub fn editor_is_inert(chooser_shown: bool) -> bool {
        chooser_shown
    }

    /// A menu command is enabled while the chooser is up only when it starts or opens a project (or is app-level).
    pub fn menu_enabled(chooser_shown: bool, starts_or_opens_project: bool) -> bool {
        !chooser_shown || starts_or_opens_project
    }

    /// The editor panels stay hidden behind the scrim until a project was chosen (the launch session is a placeholder).
    pub fn hides_editor_panels(chooser_shown: bool, has_real_project: bool) -> bool {
        chooser_shown && !has_real_project
    }
}

/// "Report on GitHub": a new issue with title and body prefilled.
pub struct IssueLinks;

impl IssueLinks {
    /// `os` is the system line ("macOS 26.1"). The body names the version and system so a report always carries them.
    pub fn new_issue_url(app_version: &str, os: &str) -> String {
        let body = format!(
            "What were you doing?\n\n\nWhat happened / what did you expect?\n\n\n---\nSequence Studio {app_version}, {os}\n"
        );
        format!(
            "{}/new?title={}&body={}",
            SupportLinks::ISSUES,
            percent_encode(&format!("Feedback on Sequence Studio {app_version}")),
            percent_encode(&body)
        )
    }
}

/// Help > Send Feedback: a prefilled mail for outside testers (Mac and Windows).
pub struct FeedbackLinks;

impl FeedbackLinks {
    /// Tester feedback goes here.
    pub const ADDRESS: &'static str = "info@getsequencestudio.com";

    /// `os`: the system line ("macOS 26.1", "Windows 11 ..."). The query is percent-encoded byte by byte except for
    /// unreserved characters, so the decoded text equals Foundation's; the encoded bytes may differ in characters
    /// Foundation leaves raw.
    pub fn mail_url(app_version: &str, build: &str, os: &str) -> String {
        let build_part = if build.is_empty() { String::new() } else { format!(" ({build})") };
        let body = format!(
            "What were you doing?\n\n\nWhat happened / what did you expect?\n\n\n---\nSequence Studio {app_version}{build_part}, {os}\n(Please attach the newest file from Help > Reveal Logs and Reports if it crashed.)\n"
        );
        format!(
            "mailto:{}?subject={}&body={}",
            Self::ADDRESS,
            percent_encode("Sequence Studio feedback"),
            percent_encode(&body)
        )
    }
}

fn percent_encode(s: &str) -> String {
    let mut out = String::new();
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'.' | b'_' | b'~') {
            out.push(char::from(b));
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

/// Where people can support the project and find the community. Discord is hidden everywhere while its URL is `None`.
pub struct SupportLinks;

impl SupportLinks {
    pub const TITLE: &'static str = "Support Sequence Studio";
    pub const TAGLINE: &'static str =
        "Sequence Studio is free, with no ads and no subscription. Your support keeps it that way.";
    /// Support, buy and donate page (the only one: app, README and FUNDING.yml all point here).
    pub const URL: &'static str = "https://getsequencestudio.com/supporter/";
    pub const WEBSITE: &'static str = "https://getsequencestudio.com";
    pub const RELEASES: &'static str = "https://github.com/paulherter/sequence-studio/releases";
    pub const ISSUES: &'static str = "https://github.com/paulherter/sequence-studio/issues";
    pub const GITHUB: &'static str = "https://github.com/paulherter/sequence-studio";
    /// The community invite: every Discord entry (start window, Help menu, About, Mac menus) shows while this is set.
    pub const DISCORD: Option<&'static str> = Some("https://discord.gg/q6KPQc8WCA");
    /// Every host a link in the product may point to.
    pub const ALLOWED_HOSTS: [&'static str; 3] = ["getsequencestudio.com", "github.com", "discord.gg"];

    /// Every link of the product.
    pub fn all_links() -> Vec<&'static str> {
        let mut v = vec![Self::URL, Self::WEBSITE, Self::GITHUB, Self::RELEASES, Self::ISSUES];
        v.extend(Self::DISCORD);
        v
    }

    /// The entries shown with the current Discord link.
    pub fn entries() -> Vec<SupportEntry> {
        SupportEntry::visible(Self::DISCORD)
    }

    /// The link behind an entry.
    pub fn url_for(e: SupportEntry) -> Option<&'static str> {
        match e {
            SupportEntry::Support => Some(Self::URL),
            SupportEntry::Discord => Self::DISCORD,
            SupportEntry::Github => Some(Self::GITHUB),
        }
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn the_issue_link_opens_a_new_issue_with_version_and_system() {
        let u = IssueLinks::new_issue_url("0.1.2", "macOS 26.1");
        assert!(u.starts_with("https://github.com/paulherter/sequence-studio/issues/new?title="));
        assert!(u.contains("&body="));
        assert!(u.contains("0.1.2"));
        assert!(u.contains("macOS%2026.1"));
        assert!(!u.contains(' ') && !u.contains('\n'));
        assert!(SupportLinks::ALLOWED_HOSTS.contains(&"github.com"));
    }

    use super::*;

    fn now() -> Timestamp {
        Timestamp::from_unix_seconds(2_000_000_000.0)
    }

    fn ago(seconds: f64) -> Option<Timestamp> {
        Some(Timestamp::from_unix_seconds(2_000_000_000.0 - seconds))
    }

    #[test]
    fn reminder_shows_on_first_successful_export() {
        assert!(SupportReminder::may_show(true, None, now(), false));
    }

    #[test]
    fn reminder_never_on_failed_export() {
        assert!(!SupportReminder::may_show(false, None, now(), false));
        assert!(!SupportReminder::may_show(false, ago(30.0 * 86400.0), now(), false));
    }

    #[test]
    fn reminder_throttled_to_seven_days() {
        let day = 86400.0;
        assert!(!SupportReminder::may_show(true, ago(1.0), now(), false));
        assert!(!SupportReminder::may_show(true, ago(6.9 * day), now(), false));
        assert!(SupportReminder::may_show(true, ago(7.0 * day), now(), false));
        assert!(SupportReminder::may_show(true, ago(40.0 * day), now(), false));
    }

    #[test]
    fn reminder_blocked_when_clock_was_set_back() {
        assert!(!SupportReminder::may_show(true, ago(-3600.0), now(), false));
    }

    #[test]
    fn reminder_never_once_turned_off() {
        assert!(!SupportReminder::may_show(true, None, now(), true));
        assert!(!SupportReminder::may_show(true, ago(90.0 * 86400.0), now(), true));
    }

    #[test]
    fn discord_invite_is_set() {
        assert_eq!(SupportLinks::DISCORD, Some("https://discord.gg/q6KPQc8WCA"));
        assert_eq!(SupportLinks::url_for(SupportEntry::Discord), SupportLinks::DISCORD);
        assert_eq!(SupportLinks::entries(), [SupportEntry::Support, SupportEntry::Discord, SupportEntry::Github]);
    }

    #[test]
    fn discord_hidden_while_none() {
        assert_eq!(SupportEntry::visible(None), [SupportEntry::Support, SupportEntry::Github]);
        assert_eq!(SupportEntry::visible(Some("https://discord.gg/x")), SupportEntry::ALL);
    }

    #[test]
    fn start_overlay_rules() {
        assert_eq!(StartOverlayPolicy::recovery_prompt_host(false), PromptHost::StartWindow);
        assert_eq!(StartOverlayPolicy::recovery_prompt_host(true), PromptHost::EditorWindow);
        assert!(StartOverlayPolicy::editor_is_inert(true) && !StartOverlayPolicy::editor_is_inert(false));
        assert!(!StartOverlayPolicy::menu_enabled(true, false));
        assert!(StartOverlayPolicy::menu_enabled(true, true));
        assert!(StartOverlayPolicy::menu_enabled(false, false));
        assert!(!StartOverlayPolicy::escape_closes(false) && StartOverlayPolicy::escape_closes(true));
        assert!(StartOverlayPolicy::hides_editor_panels(true, false));
        assert!(!StartOverlayPolicy::hides_editor_panels(true, true));
        assert!(!StartOverlayPolicy::hides_editor_panels(false, false));
    }

    #[test]
    fn reminder_slot_needs_visible_window() {
        assert!(SupportReminder::should_record(true, true));
        assert!(!SupportReminder::should_record(true, false));
        assert!(!SupportReminder::should_record(false, true));
    }

    #[test]
    fn every_place_shares_one_entry_list() {
        for e in SupportEntry::ALL {
            assert!(!e.menu_title().is_empty() && !e.symbol().is_empty() && !e.card_title().is_empty());
            assert!(!e.menu_title().to_lowercase().contains("donat"));
        }
        assert_eq!(SupportEntry::Support.help_title(), "Support Sequence Studio\u{2026}");
        assert_eq!(SupportEntry::Github.help_title(), "View on GitHub");
    }

    #[test]
    fn feedback_mail_carries_version_and_system() {
        let url = FeedbackLinks::mail_url("0.1 Alpha", "42", "Windows 11");
        assert!(url.starts_with("mailto:info@getsequencestudio.com?subject=Sequence%20Studio%20feedback&body="));
        assert!(url.contains(&percent_encode("Sequence Studio 0.1 Alpha (42), Windows 11")));
        assert!(FeedbackLinks::mail_url("1", "", "x").contains(&percent_encode("Sequence Studio 1, x")));
    }

    #[test]
    fn feedback_mail_body_is_the_swift_text() {
        // Swift SupportPolicyTests / FeedbackLinks.mailURL: no Discord or GitHub link in the body, only the prompts,
        // the version and system line and the log hint.
        let want = "What were you doing?\n\n\nWhat happened / what did you expect?\n\n\n---\nSequence Studio 0.1 Alpha (42), macOS 26.1\n(Please attach the newest file from Help > Reveal Logs and Reports if it crashed.)\n";
        let url = FeedbackLinks::mail_url("0.1 Alpha", "42", "macOS 26.1");
        assert!(url.ends_with(&format!("&body={}", percent_encode(want))), "{url}");
    }

    #[test]
    fn every_visible_support_entry_has_a_link() {
        for e in SupportLinks::entries() {
            assert!(SupportLinks::url_for(e).is_some());
        }
        assert_eq!(SupportLinks::url_for(SupportEntry::Github), Some(SupportLinks::GITHUB));
    }

    #[test]
    fn support_links_are_https_on_allowed_hosts_and_canonical() {
        for u in SupportLinks::all_links() {
            let rest = u.strip_prefix("https://").expect("https");
            let host = rest.split('/').next().unwrap_or("");
            assert!(SupportLinks::ALLOWED_HOSTS.contains(&host), "{u}");
        }
        assert_eq!(SupportLinks::URL, "https://getsequencestudio.com/supporter/");
        assert!(!SupportLinks::all_links().iter().any(|u| u.contains("sponsors")));
    }
}
