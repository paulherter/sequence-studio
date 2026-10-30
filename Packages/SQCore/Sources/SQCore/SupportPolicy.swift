import Foundation

/// Rules for the Support entries (heart button, Help menu, project chooser) and the gentle post-export reminder.
/// Pure: dates and links are injected so tests need no clock and no UI.
public enum SupportReminder {
    /// Defaults key (a Date) of the last time the reminder was shown.
    public static let defaultsKey = "sq.support.lastReminder"
    /// Defaults key (a Bool): the user chose "Don't show again".
    public static let offKey = "sq.support.reminderOff"
    /// At most one reminder per this many seconds (7 days).
    public static let interval: TimeInterval = 7 * 24 * 3600

    /// True when the export-done notice may carry the quiet "Enjoying Sequence Studio? Support it" line.
    /// Never after a failed or canceled export, never once turned off; never twice within `interval` (a clock set back counts as "just shown").
    public static func mayShow(exportSucceeded: Bool, lastShown: Date?, now: Date, turnedOff: Bool = false) -> Bool {
        guard exportSucceeded, !turnedOff else { return false }
        guard let last = lastShown else { return true }
        return now.timeIntervalSince(last) >= interval
    }

    /// The slot is recorded only once the line is built and its window is visible (not minimized, not hidden).
    public static func shouldRecord(lineShown: Bool, windowVisible: Bool) -> Bool { lineShown && windowVisible }
}

/// The entries behind the heart button and the Help menu group, in order. Discord is left out while its URL is nil.
public enum SupportEntry: Sendable, Equatable, CaseIterable {
    case support, discord, github

    public static func visible(discord: URL?) -> [SupportEntry] {
        allCases.filter { $0 != .discord || discord != nil }
    }

    /// One wording and symbol per entry for all places (heart menu, Help menu, chooser card), so they cannot drift apart.
    public var menuTitle: String {
        switch self {
        case .support: "Support Sequence Studio"
        case .discord: "Join the Discord"
        case .github: "View on GitHub"
        }
    }
    /// Help menu items end in an ellipsis only for the one that opens a page of its own.
    public var helpTitle: String { self == .support ? menuTitle + "\u{2026}" : menuTitle }
    public var cardTitle: String {
        switch self {
        case .support: "Support"
        case .discord: "Discord"
        case .github: "GitHub"
        }
    }
    public var symbol: String {
        switch self {
        case .support: "heart"
        case .discord: "discord"
        case .github: "code"
        }
    }
}

/// What the project chooser overlay does to the editor behind it.
public enum StartOverlayPolicy {
    /// Esc closes the chooser only when a real project is open behind it (reopened from the menu). At launch it cannot.
    public static func escapeCloses(hasRealProject: Bool) -> Bool { hasRealProject }

    /// Which window carries a launch-time recovery or crash-report prompt: with no project open it is the start window
    /// (the editor window must not open before the user chooses to recover).
    public enum PromptHost: Equatable, Sendable { case startWindow, editorWindow }
    public static func recoveryPromptHost(hasRealProject: Bool) -> PromptHost { hasRealProject ? .editorWindow : .startWindow }

    /// While the chooser is up the editor takes no mouse and no keyboard commands.
    public static func editorIsInert(chooserShown: Bool) -> Bool { chooserShown }

    /// A menu command is enabled while the chooser is up only when it starts or opens a project (or is app-level).
    public static func menuEnabled(chooserShown: Bool, startsOrOpensProject: Bool) -> Bool {
        !chooserShown || startsOrOpensProject
    }

    /// The editor panels stay hidden behind the scrim until a project was chosen (the launch session is a placeholder).
    public static func hidesEditorPanels(chooserShown: Bool, hasRealProject: Bool) -> Bool {
        chooserShown && !hasRealProject
    }
}

/// Help > Send Feedback: a prefilled mail for outside testers (Mac and Windows).
public enum FeedbackLinks {
    /// Tester feedback goes here.
    public static let address = "info@getsequencestudio.com"

    /// `os`: the system line ("macOS 26.1", "Windows 11 ...").
    public static func mailURL(appVersion: String, build: String, os: String) -> URL? {
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = address
        let body = "What were you doing?\n\n\nWhat happened / what did you expect?\n\n\n"
            + "---\nSequence Studio \(appVersion) (\(build)), \(os)\n"
            + "(Please attach the newest file from Help > Reveal Logs and Reports if it crashed.)\n"
        c.queryItems = [URLQueryItem(name: "subject", value: "Sequence Studio feedback"),
                        URLQueryItem(name: "body", value: body)]
        // URLComponents leaves "+" and spaces in mailto queries ambiguous: encode them explicitly.
        return c.string.flatMap { URL(string: $0.replacingOccurrences(of: "+", with: "%2B")) }
    }
}

/// Where people can support the project and find the community. Discord is hidden everywhere while its URL is nil.
public enum SupportLinks {
    public static let title = "Support Sequence Studio"
    public static let tagline = "Sequence Studio is free, with no ads and no subscription. Your support keeps it that way."
    /// Support, buy and donate page (the only one: app, README and FUNDING.yml all point here).
    public static let url = URL(string: "https://getsequencestudio.com/supporter/")!
    public static let website = URL(string: "https://getsequencestudio.com")!
    public static let releases = URL(string: "https://github.com/paulherter/sequence-studio/releases")!
    public static let issues = URL(string: "https://github.com/paulherter/sequence-studio/issues")!
    /// Every host a link in the product may point to.
    public static let allowedHosts: Set<String> = ["getsequencestudio.com", "github.com", "discord.gg"]
    public static var allLinks: [URL] { [url, website, github, releases, issues] + [discord].compactMap { $0 } }
    public static let github = URL(string: "https://github.com/paulherter/sequence-studio")!
    /// The community invite: every Discord entry (start window, Help menu, About, Mac menus) shows while this is set.
    public static let discord: URL? = URL(string: "https://discord.gg/q6KPQc8WCA")
    public static var entries: [SupportEntry] { SupportEntry.visible(discord: discord) }

    public static func url(for e: SupportEntry) -> URL? {
        switch e {
        case .support: url
        case .discord: discord
        case .github: github
        }
    }
}
