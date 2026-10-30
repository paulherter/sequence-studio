import Foundation
import Testing
import SQCore
import SQLibrary
import SQDrawLibrary
@testable import SQEditorUI
@testable import SQInspectorUI

@MainActor @Suite struct QuickApplyModelTests {
    private func preset(_ name: String, _ kind: PresetKind = .effect) -> PresetItem {
        PresetItem(kind: kind, name: name, payload: Data(), payloadVersion: 1)
    }
    private var items: [QuickApplyItem] { QuickApplyCatalog.items(presets: [preset("Soft Glow")]) }

    // MARK: Catalog

    @Test func catalogHasEffectsTransitionsPresetsAndCommands() {
        let all = items
        #expect(all.contains { $0.action == .effect(ClipEffect.gaussianBlurKind) })
        #expect(all.contains { $0.action == .transition(.crossDissolve) })
        #expect(all.contains { $0.title == "Soft Glow" })
        #expect(Set(all.map(\.id)).count == all.count, "ids are unique")
    }

    /// One source: everything the Effects panel lists is searchable in the palette by the name shown there.
    @Test func everyEffectsPanelEntryIsFoundByItsName() {
        let all = items
        for e in EffectsPanelView.catalog + EffectsPanelView.builtInPresetEntries {
            let hits = QuickApplyRanking.rank(all, query: e.title, recents: [], limit: 60)
            #expect(hits.contains { $0.title == e.title }, "\(e.title) (\(e.id)) missing from the palette")
        }
        let stab = QuickApplyRanking.rank(all, query: "Stabilize", recents: [], limit: 5)
        #expect(stab.first?.action == .effect(ClipEffect.stabilizeKind))
    }

    @Test func everySupportedMenuCommandIsSearchable() {
        let all = items
        for c in EditorMenus.all.flatMap(\.commands) where CommandSupport.isSupported(c) && c != .quickApply {
            #expect(all.contains { $0.title.lowercased() == c.title.lowercased() }, "\(c.title) missing")
        }
    }

    @Test func builtInPresetsAreListed() throws {
        let p = try #require(MotionPresets.offered.first)
        #expect(items.contains { $0.action == .builtInPreset(p.id) && $0.title == p.name })
    }

    @Test func stabilizeFromThePaletteAddsTheEffectLikeADrag() throws {
        let item = try #require(items.first { $0.action == .effect(ClipEffect.stabilizeKind) })
        let r = TimeRange(start: .zero, duration: Time(10, 1))
        let v = Clip(name: "v", media: UUID(), kind: .video, source: r, start: .zero)
        var vt = Track(kind: .video)
        try vt.overwrite(v)
        let s = EditorSession(project: Project(name: "P", timelines: [Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [vt])]),
                              engine: StubProgramEngine())
        guard case .effect(let kind, let clips) = QuickApplyTarget.resolve(item, selectedVideoClips: [v.id]) else { Issue.record("not an effect"); return }
        #expect(s.addEffect(kind: kind, to: clips))
        #expect(s.activeTimeline?.tracks.flatMap(\.clips).first?.effects.map(\.kind) == [ClipEffect.stabilizeKind])
    }

    // MARK: Ranking

    @Test func saveStackMacroIsListedAndNeedsOneClip() throws {
        let item = try #require(QuickApplyCatalog.items(presets: []).first { $0.action == .saveStackAsPreset })
        let id = UUID()
        #expect(QuickApplyTarget.resolve(item, selectedVideoClips: [id]) == .saveStackAsPreset)
        guard case .refused = QuickApplyTarget.resolve(item, selectedVideoClips: [id, UUID()]) else { Issue.record("expected refusal"); return }
        #expect(QuickApplyRanking.rank([item], query: "save stack", recents: [], limit: 5) == [item])
    }

    @Test func recentsAreLastUsedFirstAndPersist() {
        let d = UserDefaults(suiteName: "sq.test.quickApply.\(UUID().uuidString)")!
        let a = QuickApplyItem(id: "a", title: "Alpha", category: "Effect", action: .effect("a"))
        let b = QuickApplyItem(id: "b", title: "Beta", category: "Effect", action: .effect("b"))
        let m = QuickApplyModel(items: [a, b], defaults: d)
        m.select(1); _ = m.commit()
        m.query = ""; m.select(1); _ = m.commit()      // b used, then (after reorder) the other
        #expect(QuickApplyModel(items: [a, b], defaults: d).results.first?.id == m.recents.first)
    }

    @Test func blurFindsBlurFirst() {
        let r = QuickApplyRanking.rank(items, query: "blur", recents: [], limit: 20)
        #expect(r.first?.action == .effect(ClipEffect.gaussianBlurKind))
    }

    @Test func nonSubsequenceDoesNotMatch() {
        #expect(QuickApplyRanking.score(query: "xyz", title: "Gaussian Blur") == nil)
        #expect(QuickApplyRanking.score(query: "gb", title: "Gaussian Blur") != nil)
    }

    @Test func prefixAndWordStartBeatScatteredMatch() {
        let prefix = QuickApplyRanking.score(query: "blur", title: "Blur Edges")!
        let word = QuickApplyRanking.score(query: "blur", title: "Gaussian Blur")!
        let scattered = QuickApplyRanking.score(query: "blur", title: "Bold Lumen Underline Rim")!
        #expect(prefix > word)
        #expect(word > scattered)
    }

    @Test func emptyQueryListsRecentsFirstInOrder() {
        let all = items
        let recent = [all[5].id, all[2].id]
        let r = QuickApplyRanking.rank(all, query: "", recents: recent, limit: 10)
        #expect(r.prefix(2).map(\.id) == recent)
    }

    @Test func recentBreaksTiesWhenQueried() {
        let a = QuickApplyItem(id: "a", title: "Fade In", category: "Command", action: .command(.videoFadeIn))
        let b = QuickApplyItem(id: "b", title: "Fade Out", category: "Command", action: .command(.videoFadeOut))
        let r = QuickApplyRanking.rank([a, b], query: "fade", recents: ["b"], limit: 5)
        #expect(r.map(\.id) == ["b", "a"])
    }

    @Test func limitIsHonoured() {
        #expect(QuickApplyRanking.rank(items, query: "", recents: [], limit: 3).count == 3)
    }

    // MARK: Recents and macros

    @Test func recentsAreCappedAtEightAndUseThePaletteKey() {
        #expect(QuickApplyModel.maxRecents == 8)
        #expect(QuickApplyModel.recentsKey == "sq.palette.recents")
        let ids = (0..<12).map { "i\($0)" }
        #expect(ids.reduce([String]()) { QuickApplyModel.pushRecent($1, into: $0) }.count == 8)
    }

    @Test func oldRecentsKeyMigratesOnce() {
        let d = UserDefaults(suiteName: "sq.test.quickApply.\(UUID().uuidString)")!
        d.set(["a", "b"], forKey: "sq.quickApply.recents")
        #expect(QuickApplyModel(items: [], defaults: d).recents == ["a", "b"])
        #expect(d.stringArray(forKey: "sq.palette.recents") == ["a", "b"])
    }

    @Test func recentRowsAreMarkedOnlyOnAnEmptyQuery() {
        let d = UserDefaults(suiteName: "sq.test.quickApply.\(UUID().uuidString)")!
        let a = QuickApplyItem(id: "a", title: "Alpha", category: "Effect", action: .effect("a"))
        let b = QuickApplyItem(id: "b", title: "Beta", category: "Effect", action: .effect("b"))
        let m = QuickApplyModel(items: [a, b], defaults: d)
        m.select(1); _ = m.commit()
        m.query = ""
        #expect(m.isRecentRow(b) && !m.isRecentRow(a))
        m.query = "be"
        #expect(!m.isRecentRow(b))
    }

    @Test func builtInMacroIsListedAndItsStepsExistInTheCatalog() throws {
        let all = items
        let macro = try #require(QuickApplyMacro.builtIn.first)
        let item = try #require(all.first { $0.action == .macro(macro.id) })
        #expect(item.category == "Macro")
        for step in macro.steps { #expect(all.contains { $0.id == step }, "\(step) is not a palette row") }
        #expect(QuickApplyTarget.resolve(item, selectedVideoClips: []) == .macro(macro))
    }

    // MARK: Target resolution

    @Test func effectNeedsSelectedVideoClips() {
        let blur = QuickApplyItem(id: "e", title: "Blur", category: "Effect", action: .effect(ClipEffect.gaussianBlurKind))
        let id = UUID()
        #expect(QuickApplyTarget.resolve(blur, selectedVideoClips: [id]) == .effect(kind: ClipEffect.gaussianBlurKind, clips: [id]))
        guard case .refused = QuickApplyTarget.resolve(blur, selectedVideoClips: []) else { Issue.record("expected refusal"); return }
    }

    @Test func transitionAndCommandNeedNoClips() {
        let t = QuickApplyItem(id: "t", title: "Cross Dissolve", category: "Transition", action: .transition(.crossDissolve))
        let c = QuickApplyItem(id: "c", title: "Add Edit", category: "Command", action: .command(.addEdit))
        #expect(QuickApplyTarget.resolve(t, selectedVideoClips: []) == .transition(.crossDissolve))
        #expect(QuickApplyTarget.resolve(c, selectedVideoClips: []) == .command(.addEdit))
    }

    // MARK: Model

    @MainActor
    @Test func commitRecordsRecentAndPersists() {
        let suite = UserDefaults(suiteName: "sq.test.quickapply.\(UUID().uuidString)")!
        let m = QuickApplyModel(items: items, defaults: suite)
        m.query = "blur"
        #expect(m.selected?.action == .effect(ClipEffect.gaussianBlurKind))
        let chosen = m.commit()
        #expect(chosen?.action == .effect(ClipEffect.gaussianBlurKind))
        #expect(m.recents.first == chosen?.id)
        let m2 = QuickApplyModel(items: items, defaults: suite)
        #expect(m2.recents.first == chosen?.id)
        m2.query = ""
        #expect(m2.results.first?.id == chosen?.id)
    }

    @MainActor
    @Test func moveClampsSelection() {
        let m = QuickApplyModel(items: items, defaults: UserDefaults(suiteName: "sq.test.quickapply.\(UUID().uuidString)")!)
        m.move(-1)
        #expect(m.selectedIndex == 0)
        m.move(1000)
        #expect(m.selectedIndex == m.results.count - 1)
    }

    @MainActor
    @Test func arrowsWalkTheHitsAfterTyping() {
        let m = QuickApplyModel(items: items, defaults: UserDefaults(suiteName: "sq.test.quickapply.\(UUID().uuidString)")!)
        m.query = "a"
        #expect(m.results.count > 1)
        let first = m.results[0], second = m.results[1]
        m.move(1); #expect(m.selected == second)
        m.move(-1); #expect(m.selected == first)
        m.move(1); m.query = "e"; #expect(m.selectedIndex == 0, "a new query resets to the top")
    }

    @Test func recentsAreCappedAndDeduplicated() {
        var r: [String] = []
        for i in 0..<30 { r = QuickApplyModel.pushRecent("x\(i)", into: r) }
        r = QuickApplyModel.pushRecent("x5", into: r)
        #expect(r.count == QuickApplyModel.maxRecents)
        #expect(r.first == "x5")
        #expect(r.filter { $0 == "x5" }.count == 1)
    }

    // MARK: Reopen + transition end

    @MainActor
    @Test func lastQueryComesBackOnReopen() {
        let suite = UserDefaults(suiteName: "sq.test.quickapply.\(UUID().uuidString)")!
        let m = QuickApplyModel(items: items, defaults: suite)
        m.query = "blur"
        let m2 = QuickApplyModel(items: items, defaults: suite)
        #expect(m2.query == "")
        m2.reopen()
        #expect(m2.query == "blur")
        #expect(m2.selected?.action == .effect(ClipEffect.gaussianBlurKind))
        m2.query = ""   // Delete in the field
        let m3 = QuickApplyModel(items: items, defaults: suite)
        m3.reopen()
        #expect(m3.query == "")
    }

    @MainActor
    @Test func transitionAsksForStartOrEndWhenClipsAreSelected() {
        let suite = UserDefaults(suiteName: "sq.test.quickapply.\(UUID().uuidString)")!
        let m = QuickApplyModel(items: items, defaults: suite)
        m.query = "dissolve"
        let first = m.selected!
        #expect(m.confirm(canChooseEnd: false) == .apply(first, end: nil), "no clips selected: plain apply")
        guard case .askEnd(let item) = m.confirm(canChooseEnd: true) else { Issue.record("expected the start/end popup"); return }
        #expect(item.action == .transition(.crossDissolve))
        #expect(m.pendingTransition == item)
        // FB-G: both ends unless the user picks one (Left = start, Right = end, Down = both again; Return confirms).
        #expect(m.transitionEnd == .both)
        m.chooseEnd(.start); #expect(m.transitionEnd == .start)
        m.chooseEnd(.end); #expect(m.transitionEnd == .end)
        m.chooseEnd(.both); #expect(m.transitionEnd == .both)
        m.chooseEnd(.end)
        #expect(m.confirm(canChooseEnd: true) == .apply(item, end: .end))
        #expect(m.pendingTransition == nil)
        #expect(m.recents.first == item.id)
    }

    @MainActor
    @Test func returnTwiceAppliesToBothEnds() {
        let m = QuickApplyModel(items: items, defaults: UserDefaults(suiteName: "sq.test.quickapply.\(UUID().uuidString)")!)
        m.query = "dissolve"
        guard case .askEnd(let item) = m.confirm(canChooseEnd: true) else { Issue.record("expected the end popup"); return }
        #expect(m.confirm(canChooseEnd: true) == .apply(item, end: .both))
    }

    @MainActor
    @Test func effectsNeverAskForAnEnd() {
        let m = QuickApplyModel(items: items, defaults: UserDefaults(suiteName: "sq.test.quickapply.\(UUID().uuidString)")!)
        m.query = "blur"
        #expect(m.confirm(canChooseEnd: true) == .apply(m.selected!, end: nil))
    }

    @MainActor
    @Test func escapeInEndChoiceGoesBackToTheList() {
        let m = QuickApplyModel(items: items, defaults: UserDefaults(suiteName: "sq.test.quickapply.\(UUID().uuidString)")!)
        m.query = "dissolve"
        _ = m.confirm(canChooseEnd: true)
        m.cancelEndChoice()
        #expect(m.pendingTransition == nil)
        #expect(m.query == "dissolve")
    }

    @Test func edgesForClipsAtStartOrEnd() {
        let a = UUID(), b = UUID()
        #expect(Set(QuickApplyTarget.edges(for: [a, b], end: .start).edges) == [EdgeRef(clip: a, edge: .head), EdgeRef(clip: b, edge: .head)])
        #expect(Set(QuickApplyTarget.edges(for: [a], end: .end).edges) == [EdgeRef(clip: a, edge: .tail)])
        #expect(Set(QuickApplyTarget.edges(for: [a], end: .both).edges) == [EdgeRef(clip: a, edge: .head), EdgeRef(clip: a, edge: .tail)])
    }
}

@Suite struct QuickApplyPlacementTests {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let size = CGSize(width: 640, height: 300)

    @Test func insideScreenStaysPut() {
        let p = QuickApplyPlacement.clamp(topLeft: CGPoint(x: 100, y: 800), size: size, screens: [screen])
        #expect(p == CGPoint(x: 100, y: 800))
    }

    @Test func offScreenIsPulledBack() {
        #expect(QuickApplyPlacement.clamp(topLeft: CGPoint(x: -500, y: 1200), size: size, screens: [screen]) == CGPoint(x: 0, y: 900))
        #expect(QuickApplyPlacement.clamp(topLeft: CGPoint(x: 1400, y: 50), size: size, screens: [screen]) == CGPoint(x: 800, y: 300))
    }

    @Test func secondScreenIsKeptWhenCardLivesThere() {
        let second = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let p = QuickApplyPlacement.clamp(topLeft: CGPoint(x: 2000, y: 700), size: size, screens: [screen, second])
        #expect(p == CGPoint(x: 2000, y: 700))
    }

    @Test func unplugdScreenFallsBackToRemaining() {
        let p = QuickApplyPlacement.clamp(topLeft: CGPoint(x: 2500, y: 700), size: size, screens: [screen])
        #expect(p == CGPoint(x: 800, y: 700))
    }

    @Test func defaultIsCentredInUpperThird() {
        let p = QuickApplyPlacement.defaultTopLeft(in: screen, width: 640)
        #expect(p.x == 400 && p.y == 900 - 900 * 0.28)
    }

    @Test func originRoundTripsAndResets() {
        let d = UserDefaults(suiteName: "sq.test.qa.\(UUID().uuidString)")!
        #expect(QuickApplyPlacement.load(d) == nil)
        QuickApplyPlacement.save(CGPoint(x: 12.5, y: 640), d)
        #expect(QuickApplyPlacement.load(d) == CGPoint(x: 12.5, y: 640))
        QuickApplyPlacement.reset(d)
        #expect(QuickApplyPlacement.load(d) == nil)
    }
}
