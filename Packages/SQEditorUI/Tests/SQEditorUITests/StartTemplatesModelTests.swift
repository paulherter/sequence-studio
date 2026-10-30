import Testing
import SQCore
@testable import SQEditorUI

@Suite struct StartTemplatesModelTests {
    private func user(_ n: Int) -> ProjectTemplate {
        var t = ProjectTemplate.vertical
        t.id = "user-\(n)"; t.name = "T\(n)"
        return t
    }

    @Test func rowHoldsOnlyUserTemplatesUpToLimit() {
        let all = ProjectTemplate.builtIn + (1...6).map(user)
        let r = StartTemplatesModel.yourTemplates(from: all)
        #expect(r.total == 6)
        #expect(r.shown.map(\.id) == ["user-1", "user-2", "user-3", "user-4"])
    }

    @Test func noUserTemplatesGivesEmptyRow() {
        let r = StartTemplatesModel.yourTemplates(from: ProjectTemplate.builtIn)
        #expect(r.shown.isEmpty && r.total == 0)
    }

    @Test func newProjectOffersMoveAndCopy() {
        let modes = StartTemplatesModel.outsideChoices.map(\.mode)
        #expect(modes == [.ask, .copy, .move, .leave])
        #expect(StartTemplatesModel.outsideIndex(of: .move) == 2)
    }
}
