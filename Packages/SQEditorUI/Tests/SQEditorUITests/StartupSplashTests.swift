import Foundation
import Testing
@testable import SQEditorUI
@testable import SQInspectorUI

@MainActor private final class Spy: StartupSplashPresenting {
    var shows = 0, closes = 0
    var last: StartupLog?
    var onGone: (() -> Void)?
    func show() { shows += 1 }
    func update(_ log: StartupLog) { last = log }
    func close() { closes += 1 }
}

@Suite struct StartupSplashTests {
    @Test func visibleWindowFadesLastThree() {
        var l = StartupLog(expected: 10)
        for s in ["a", "b", "c", "d"] { l.begin(s) }
        #expect(l.visible.map(\.text) == ["b", "c", "d…"])
        #expect(l.visible.map(\.opacity) == [0.25, 0.5, 1])
        l.finish()
        #expect(l.visible.last?.text == "d")
    }

    @Test func fewerThanThreeKeepsNewestFull() {
        var l = StartupLog(expected: 10)
        l.begin("a")
        #expect(l.visible == [.init(text: "a…", opacity: 1)])
    }

    @Test func progressMonotonicAndCapped() {
        var l = StartupLog(expected: 4)
        var prev = l.progress
        #expect(prev == 0)
        for i in 0..<9 { l.begin("s\(i)"); #expect(l.progress >= prev); #expect(l.progress < 1); prev = l.progress }
        l.finish()
        #expect(l.progress == 1)
        l.begin("late")
        #expect(l.steps.count == 9)
    }

    @Test func gate() {
        #expect(StartupSplashGate.shouldShow(elapsed: 0, alreadyShown: false, finished: false))
        #expect(StartupSplashGate.shouldShow(elapsed: 0.15, alreadyShown: false, finished: false))
        #expect(!StartupSplashGate.shouldShow(elapsed: 1, alreadyShown: true, finished: false))
        #expect(!StartupSplashGate.shouldShow(elapsed: 1, alreadyShown: false, finished: true))
    }

    @MainActor @Test func fastLaunchShowsToo() {
        let spy = Spy()
        var t: TimeInterval = 100
        var lines: [String] = []
        let r = StartupReporter(expected: 3, presenter: spy, clock: { t }, emit: { lines.append($0) })
        r.step("Preferences"); t += 0.05; r.step("Fonts"); t += 0.05; r.step("Metal device")
        r.finish()
        #expect(spy.shows == 1 && spy.closes == 1)
        #expect(lines.count == 4 && lines[0].hasPrefix("SQStartup +0 ms Preferences"))
    }

    @MainActor @Test func slowLaunchShowsOnceAndClosesOnFinish() {
        let spy = Spy()
        var t: TimeInterval = 0
        let r = StartupReporter(expected: 3, presenter: spy, clock: { t }, emit: { _ in })
        r.step("Preferences"); t += 0.2
        r.step("Shaders"); t += 0.2
        r.step("Color pipeline")
        #expect(spy.shows == 1)
        #expect(spy.last?.visible.count == 3)
        #expect(r.isSplashShown)
        r.finish(); r.finish()
        #expect(spy.closes == 1)
        #expect(!r.isSplashShown)
    }

    @MainActor @Test func windowShowCallbackWaitsForFadeEnd() {
        let spy = Spy()
        var t: TimeInterval = 0
        let r = StartupReporter(expected: 3, presenter: spy, clock: { t }, emit: { _ in })
        var calls: [Bool] = []
        r.step("Preferences"); t += 0.2
        r.whenSplashGone { calls.append($0) }
        #expect(calls.isEmpty)        // splash is up
        r.finish()
        #expect(spy.closes == 1 && calls.isEmpty)   // still fading
        spy.onGone?()
        #expect(calls == [true])      // after the fade: show with a plain fade-in
        r.whenSplashGone { calls.append($0) }
        #expect(calls == [true, false])
    }

    @MainActor @Test func noSplashShowsWindowDirectly() {
        let r = StartupReporter(expected: 3, presenter: nil, emit: { _ in })
        var calls: [Bool] = []
        r.whenSplashGone { calls.append($0) }
        #expect(calls == [false])
    }
}
