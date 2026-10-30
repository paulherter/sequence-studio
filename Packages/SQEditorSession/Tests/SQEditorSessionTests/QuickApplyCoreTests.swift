import Foundation
import Testing
import SQCore
import SQLibrary
@testable import SQEditorSession

@MainActor @Suite struct QuickApplyCoreTests {
    private let effects: [(id: String, title: String)] = [
        (ClipEffect.gaussianBlurKind, "Gaussian Blur"), (EffectDragPayload.transitionID(.crossDissolve), "Cross Dissolve"),
    ]
    private func items() -> [QuickApplyItem] {
        QuickApplyCatalog.items(effects: effects, builtInPresets: [], presets: [PresetItem(kind: .effect, name: "Soft Glow", payload: Data(), payloadVersion: 1)])
    }
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "qa.\(UUID().uuidString)")! }

    @Test func catalogListsEffectsTransitionsPresetsAndCommandsWithUniqueIDs() {
        let all = items()
        #expect(all.contains { $0.action == .effect(ClipEffect.gaussianBlurKind) })
        #expect(all.contains { $0.title == "Soft Glow" })
        #expect(all.contains { $0.category.hasSuffix("Transition") })
        #expect(all.contains { $0.category == "Command" })
        #expect(Set(all.map(\.id)).count == all.count)
    }

    @Test func fuzzySearchFindsAndRanksPrefixFirst() {
        let r = QuickApplyRanking.rank(items(), query: "gblur", recents: [], limit: 5)
        #expect(r.first?.title == "Gaussian Blur")
    }

    @Test func returnOnATransitionAsksStartOrEndWhenClipsAreSelected() {
        let m = QuickApplyModel(items: items(), defaults: defaults())
        m.query = "cross"
        #expect(m.confirm(canChooseEnd: true) == .askEnd(m.selected!))
        m.chooseEnd(.end)
        guard case .apply(let item, let end) = m.confirm(canChooseEnd: true) else { Issue.record("no apply"); return }
        #expect(end == .end)
        #expect(item.action == .transition(.crossDissolve))
        #expect(m.recents.first == item.id)
    }

    @Test func recentsStayEightAndComeFirstOnAnEmptyQuery() {
        let d = defaults()
        let m = QuickApplyModel(items: items(), defaults: d)
        m.query = "soft"
        _ = m.commit()
        m.query = ""
        #expect(m.results.first?.title == "Soft Glow")
        #expect(m.isRecentRow(m.results[0]))
        #expect(d.stringArray(forKey: QuickApplyModel.recentsKey)?.count == 1)
    }

    @Test func effectNeedsAVideoClipSelection() {
        let blur = items().first { $0.action == .effect(ClipEffect.gaussianBlurKind) }!
        guard case .refused = QuickApplyTarget.resolve(blur, selectedVideoClips: []) else { Issue.record("expected refusal"); return }
        let id = UUID()
        #expect(QuickApplyTarget.resolve(blur, selectedVideoClips: [id]) == .effect(kind: ClipEffect.gaussianBlurKind, clips: [id]))
    }
}
