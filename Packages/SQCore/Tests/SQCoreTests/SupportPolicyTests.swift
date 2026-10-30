import Foundation
import Testing
@testable import SQCore

@Suite struct SupportPolicyTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test func reminderShowsOnFirstSuccessfulExport() {
        #expect(SupportReminder.mayShow(exportSucceeded: true, lastShown: nil, now: now))
    }

    @Test func reminderNeverOnFailedExport() {
        #expect(!SupportReminder.mayShow(exportSucceeded: false, lastShown: nil, now: now))
        #expect(!SupportReminder.mayShow(exportSucceeded: false, lastShown: now.addingTimeInterval(-30 * 86400), now: now))
    }

    @Test func reminderThrottledToSevenDays() {
        let day: TimeInterval = 86400
        #expect(!SupportReminder.mayShow(exportSucceeded: true, lastShown: now.addingTimeInterval(-1), now: now))
        #expect(!SupportReminder.mayShow(exportSucceeded: true, lastShown: now.addingTimeInterval(-6.9 * day), now: now))
        #expect(SupportReminder.mayShow(exportSucceeded: true, lastShown: now.addingTimeInterval(-7 * day), now: now))
        #expect(SupportReminder.mayShow(exportSucceeded: true, lastShown: now.addingTimeInterval(-40 * day), now: now))
    }

    @Test func reminderBlockedWhenClockWasSetBack() {
        #expect(!SupportReminder.mayShow(exportSucceeded: true, lastShown: now.addingTimeInterval(3600), now: now))
    }

    @Test func reminderNeverOnceTurnedOff() {
        #expect(!SupportReminder.mayShow(exportSucceeded: true, lastShown: nil, now: now, turnedOff: true))
        #expect(!SupportReminder.mayShow(exportSucceeded: true, lastShown: now.addingTimeInterval(-90 * 86400), now: now, turnedOff: true))
    }

    @Test func discordInviteIsSet() {
        #expect(SupportLinks.discord?.absoluteString == "https://discord.gg/q6KPQc8WCA")
        #expect(SupportLinks.url(for: .discord) == SupportLinks.discord)
        #expect(SupportLinks.entries == [.support, .discord, .github])
    }

    @Test func discordHiddenWhileNil() {
        #expect(SupportEntry.visible(discord: nil) == [.support, .github])
        let url = URL(string: "https://discord.gg/x")!
        #expect(SupportEntry.visible(discord: url) == [.support, .discord, .github])
    }

    @Test func recoveryPromptSitsOnTheStartWindowAtLaunch() {
        #expect(StartOverlayPolicy.recoveryPromptHost(hasRealProject: false) == .startWindow)
        #expect(StartOverlayPolicy.recoveryPromptHost(hasRealProject: true) == .editorWindow)
    }

    @Test func chooserOverlayLocksEditor() {
        #expect(StartOverlayPolicy.editorIsInert(chooserShown: true))
        #expect(!StartOverlayPolicy.editorIsInert(chooserShown: false))
        #expect(!StartOverlayPolicy.menuEnabled(chooserShown: true, startsOrOpensProject: false))
        #expect(StartOverlayPolicy.menuEnabled(chooserShown: true, startsOrOpensProject: true))
        #expect(StartOverlayPolicy.menuEnabled(chooserShown: false, startsOrOpensProject: false))
    }

    @Test func escapeOnlyWithRealProject() {
        #expect(!StartOverlayPolicy.escapeCloses(hasRealProject: false))
        #expect(StartOverlayPolicy.escapeCloses(hasRealProject: true))
    }

    @Test func launchHidesPanelsUntilProjectChosen() {
        #expect(StartOverlayPolicy.hidesEditorPanels(chooserShown: true, hasRealProject: false))
        #expect(!StartOverlayPolicy.hidesEditorPanels(chooserShown: true, hasRealProject: true))
        #expect(!StartOverlayPolicy.hidesEditorPanels(chooserShown: false, hasRealProject: false))
    }

    @Test func reminderSlotNeedsVisibleWindow() {
        #expect(SupportReminder.shouldRecord(lineShown: true, windowVisible: true))
        #expect(!SupportReminder.shouldRecord(lineShown: true, windowVisible: false))
        #expect(!SupportReminder.shouldRecord(lineShown: false, windowVisible: true))
    }

    @Test func everyPlaceSharesOneEntryList() {
        let url = URL(string: "https://example.com/invite")
        #expect(SupportEntry.visible(discord: nil) == [.support, .github])
        #expect(SupportEntry.visible(discord: url) == [.support, .discord, .github])
        for e in SupportEntry.allCases {
            #expect(!e.menuTitle.isEmpty && !e.symbol.isEmpty && !e.cardTitle.isEmpty)
            #expect(!e.menuTitle.lowercased().contains("donat"))
        }
    }

    @Test func feedbackMailCarriesVersionAndSystem() throws {
        let url = try #require(FeedbackLinks.mailURL(appVersion: "0.1 Alpha", build: "42", os: "Windows 11"))
        #expect(url.scheme == "mailto")
        let body = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "body" }?.value ?? ""
        #expect(body.contains("Sequence Studio 0.1 Alpha (42), Windows 11"))
    }

    @Test func everyVisibleSupportEntryHasALink() {
        for e in SupportLinks.entries { #expect(SupportLinks.url(for: e) != nil) }
        #expect(SupportLinks.url(for: .github) == SupportLinks.github)
    }

    @Test func supportLinksAreHttpsOnAllowedHostsAndCanonical() {
        for u in SupportLinks.allLinks {
            #expect(u.scheme == "https", "\(u)")
            #expect(SupportLinks.allowedHosts.contains(u.host ?? ""), "\(u)")
        }
        #expect(SupportLinks.url.absoluteString == "https://getsequencestudio.com/supporter/")
        #expect(!SupportLinks.allLinks.contains { $0.absoluteString.contains("sponsors") })
    }
}
