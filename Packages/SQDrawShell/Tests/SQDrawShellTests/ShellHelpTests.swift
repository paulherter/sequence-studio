import Foundation
import Testing
import SQCore
import SQUIKit
import SQEditorSession
@testable import SQDrawShell

@MainActor
@Suite struct ShellHelpTests {
    func host() -> (ShellHost, [URL]) {
        let h = ShellHost(session: ShellCommandsTests.session(), map: .premiereDefault)
        return (h, [])
    }

    /// Runs `flow` until it shows a dialog and answers it.
    func answer(_ h: ShellHost, _ flow: @escaping @MainActor () async -> Void, with r: ShellDialog.Response) async -> ShellDialog? {
        let t = Task { @MainActor in await flow() }
        for _ in 0..<200 where h.dialog == nil { await Task.yield() }
        let d = h.dialog
        d?.press(r)
        await t.value
        return d
    }

    @Test func supportRowsOpenTheirPages() {
        let (h, _) = host()
        var opened: [URL] = []
        h.openURL = { opened.append($0) }
        h.perform(.support(.github))
        h.perform(.support(.support))
        #expect(opened == [SupportLinks.github, SupportLinks.url])
    }

    @Test func discordRowOpensTheInvite() {
        let (h, _) = host()
        var opened: [URL] = []
        h.openURL = { opened.append($0) }
        h.perform(.support(.discord))
        #expect(opened == [SupportLinks.discord!])
    }

    @Test func feedbackOpensAPrefilledMail() {
        let (h, _) = host()
        var opened: [URL] = []
        h.openURL = { opened.append($0) }
        h.perform(.sendFeedback)
        #expect(opened.first?.scheme == "mailto")
    }

    /// The Mac About (AboutDialog.makeBody): the sList card, the icon above the name, version, tagline, the link
    /// buttons (a click opens the page), License and credits; Acknowledgments swaps to the list, Back swaps back.
    @Test func aboutIsTheMacCardAndAcknowledgmentsGoBackAndForth() async throws {
        let (h, _) = host()
        var opened: [URL] = []
        h.openURL = { opened.append($0) }
        let t = Task { @MainActor in await h.showAbout() }
        for _ in 0..<200 where h.dialog == nil { await Task.yield() }
        let d = try #require(h.dialog)
        #expect(d.width == 480)
        d.layout(in: CGRect(x: 0, y: 0, width: 1100, height: 720), measure: TextMeasure(atlas: nil, scale: 1))
        let about = try #require(d.content as? ShellAboutContent)
        #expect(about.page == .about)
        let texts = about.parts.compactMap { if case .text(let s, _, _, _, _, _) = $0 { s } else { nil } }
        #expect(texts.first == "Sequence Studio")
        #expect(texts.contains(AppVersion.aboutLine))
        #expect(texts.contains("License: " + AboutContent.license))
        let icon = try #require(about.iconFrame)
        guard case .icon = about.parts.first else { Issue.record("no icon first"); return }
        #expect(icon.width == 88 && abs(icon.midX - d.card.midX) < 0.5)
        let buttons = about.parts.compactMap { if case .button(let s, let r, _, _) = $0 { (s, r) } else { nil } }
        #expect(buttons.map(\.0) == AboutContent.links(discord: SupportLinks.discord).map(\.title))
        let gh = buttons[0].1
        _ = d.handle(.mouseDown(x: Float(gh.midX), y: Float(gh.midY), modifiers: []), scale: 1)
        _ = d.handle(.mouseUp(x: Float(gh.midX), y: Float(gh.midY)), scale: 1)
        #expect(opened == [SupportLinks.github])
        #expect(h.dialog === d)
        d.press(.second)
        for _ in 0..<200 where h.dialog === d || h.dialog == nil { await Task.yield() }
        let ack = try #require(h.dialog)
        #expect(ack.messageText == "Acknowledgments")
        #expect((ack.content as? ShellAboutContent)?.page == .acknowledgments)
        ack.press(.second)
        for _ in 0..<200 where h.dialog === ack || h.dialog == nil { await Task.yield() }
        #expect((h.dialog?.content as? ShellAboutContent)?.page == .about)
        h.dialog?.press(.first)
        await t.value
    }

    @Test func aboutListsSupportersOnlyWhenThereAreAny() {
        func texts(_ names: [String]) -> [String] {
            let c = ShellAboutContent(page: .about, supporters: names) { _ in }
            c.layout(CGRect(x: 0, y: 0, width: 480, height: 0), measure: TextMeasure(atlas: nil, scale: 1))
            return c.parts.compactMap { if case .text(let s, _, _, _, _, _) = $0 { s } else { nil } }
        }
        #expect(!texts([]).contains("Supporters"))
        #expect(texts(["Ada", "Linus"]).contains("Supporters"))
    }

    @Test func revealLogsShowsTheLogFileOrItsFolder() {
        let (h, _) = host()
        var revealed: [URL] = [], opened: [URL] = []
        h.revealFile = { revealed.append($0) }
        h.openURL = { opened.append($0) }
        h.perform(.revealLogs)
        #expect(revealed.count + opened.count == 1)
    }

    @Test func updateCheckWithoutAFeedSaysSo() async {
        let (h, _) = host()
        let d = await answer(h, { await h.checkForUpdates() }, with: .first)
        #expect(d?.messageText == "Check for Updates")
        #expect(d?.informativeText.contains("not set up") == UpdateCheck.feedURL.isEmpty)
    }
}
