import Foundation
import Testing
import SQCore
import SQUIKit
import SQDrawKit
import SQEditorSession
@testable import SQDrawShell

/// The start screen in a window of its own (`ShellStartWindows.swift`, `ShellHost.startWindowSize`) and the fixed-size
/// Preferences card.
@MainActor
@Suite struct ShellStartWindowsTests {
    typealias S = ShellStartWindows
    static var hosts: [ShellHost] = []

    @Test func startWithoutAProjectShowsTheStartWindowThenHidesTheEditor() {
        #expect(S.steps(.init(startShown: true, startVisible: false, editorVisible: true, hasRealProject: false))
                == [.showStart, .hideEditor])
        #expect(S.steps(.init(startShown: true, startVisible: true, editorVisible: false, hasRealProject: false)) == [])
    }

    @Test func startOverAProjectKeepsTheEditor() {
        #expect(S.steps(.init(startShown: true, startVisible: false, editorVisible: true, hasRealProject: true)) == [.showStart])
    }

    @Test func openingAProjectBringsTheEditorUpThenHidesTheStartWindow() {
        #expect(S.steps(.init(startShown: false, startVisible: true, editorVisible: false, hasRealProject: true))
                == [.showEditor, .hideStart])
        #expect(S.steps(.init(startShown: false, startVisible: false, editorVisible: true, hasRealProject: true)) == [])
    }

    @Test func windowedStartFillsItsOwnWindowAndClearsTheLights() {
        let h = ShellHost(session: ShellCommandsTests.session(), map: .premiereDefault)
        Self.hosts.append(h)
        h.size = CGSize(width: 1440, height: 900)
        h.startWindowSize = CGSize(width: 1100, height: 720)
        h.showStart(defaults: UserDefaults(suiteName: "sq.test.startwin.\(UUID())")!)
        let s = try! #require(h.startScreen)
        #expect(s.frame == CGRect(x: 0, y: 0, width: 1100, height: 720))
        #expect(s.barFrame == nil)
        #expect(s.titleInset == ShellStartScreen.M.lights)
        // Without a project the editor window goes; the close button quits (no project behind it).
        #expect(h.startWindowSteps(startVisible: false, editorVisible: true) == [.showStart, .hideEditor])
        h.editorWindowActivated()
        #expect(h.isStartShown)
    }

    @Test func theRailHasTheAppearanceLinkBeforeFeedback() {
        let h = ShellHost(session: ShellCommandsTests.session(), map: .premiereDefault)
        Self.hosts.append(h)
        h.size = CGSize(width: 1280, height: 800)
        h.showStart(defaults: UserDefaults(suiteName: "sq.test.startrail.\(UUID())")!)
        let spots = h.startScreen!.railSpots()
        let a = try! #require(spots.first { $0.1 == .appearance }?.0)
        let f = try! #require(spots.first { $0.1 == .feedback }?.0)
        #expect(a.width == 28 && a.height == 28)
        #expect(a.maxX <= f.minX && a.minY == f.minY)
    }

    @Test func theRailHasADiscordLinkNextToGitHub() {
        let h = ShellHost(session: ShellCommandsTests.session(), map: .premiereDefault)
        Self.hosts.append(h)
        h.size = CGSize(width: 1280, height: 800)
        h.showStart(defaults: UserDefaults(suiteName: "sq.test.startrail.\(UUID())")!)
        let spots = h.startScreen!.railSpots()
        let d = try! #require(spots.first { $0.1 == .support(.discord) }?.0)
        let g = try! #require(spots.first { $0.1 == .support(.github) }?.0)
        #expect(d.minY == g.minY && abs(d.midX - g.midX) <= 30)
    }

    @Test func preferencesKeepOneSizeOnEveryPage() async throws {
        let defaults = UserDefaults(suiteName: "sq.test.prefsize.\(UUID().uuidString)")!
        let h = ShellHost(session: ShellRecoveryTests.session(), map: .premiereDefault)
        let t = Task { await h.showPreferences(defaults: defaults) }
        var d: ShellDialog?
        for _ in 0..<200 where d == nil { d = h.dialog; await Task.yield() }
        let dialog = try #require(d)
        let window = CGRect(x: 0, y: 0, width: 1440, height: 900), m = TextMeasure(atlas: nil, scale: 1)
        var cards: [CGRect] = []
        for page in ShellPreferences.Page.allCases {
            dialog.form?.selectPage(page.rawValue)
            dialog.layout(in: window, measure: m)
            cards.append(dialog.card)
        }
        #expect(cards.allSatisfy { $0 == cards[0] })
        #expect(cards[0].width == 860 && cards[0].height == 640)
        dialog.press(.first)
        await t.value
    }
}
