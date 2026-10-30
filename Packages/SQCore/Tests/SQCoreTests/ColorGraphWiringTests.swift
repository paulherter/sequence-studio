import Foundation
import Testing
@testable import SQCore

// Explicit Steps wiring (v80): wires, refusals, insert, extract, key wires, file version.

@Suite struct ColorGraphWiringTests {
    /// Three serial Steps a -> b -> c.
    private static func chain() -> (ColorGraph, UUID, UUID, UUID) {
        var g = ColorGraph()
        let a = g.steps[0].id
        let b = g.addStep(after: a)
        let c = g.addStep(after: b)
        return (g, a, b, c)
    }

    @Test func derivedLinksOfAChain() {
        let (g, a, b, c) = Self.chain()
        #expect(g.imageLinks == [GraphLink(.source, .step(a)), GraphLink(.step(a), .step(b)), GraphLink(.step(b), .step(c)), GraphLink(.step(c), .sink)])
        #expect(!g.hasCustomWiring && g.isWiringApplied)
    }

    @Test func reconnectingTheSameChainStaysDerived() {
        var (g, a, b, c) = Self.chain()
        g.disconnect(GraphLink(.step(b), .step(c)))
        #expect(g.hasCustomWiring, "a Step without input is not a column graph")
        let r = g.connect(.step(b), to: .step(c))
        #expect(r == nil)
        #expect(!g.hasCustomWiring)
        #expect(g.steps.map(\.id) == [a, b, c])
    }

    @Test func cycleIsRefused() {
        var (g, a, _, c) = Self.chain()
        #expect(g.refusal(from: .step(c), to: .step(a)) == .cycle)
        let r = g.connect(.step(c), to: .step(a))
        #expect(r == .cycle)
        #expect(!g.hasCustomWiring)
    }

    @Test func outputToOutputAndInputToInputAreRefused() {
        var (g, a, _, _) = Self.chain()
        let r1 = g.connect(.sink, to: .step(a))
        let r2 = g.connect(.step(a), to: .source)
        let r3 = g.connect(.step(a), to: .step(a))
        #expect(r1 == .notAnOutput && r2 == .notAnInput && r3 == .sameBox)
    }

    @Test func aSecondWireIntoAStepReplacesTheFirst() {
        var (g, a, b, c) = Self.chain()
        let r = g.connect(.step(a), to: .step(c))
        #expect(r == nil)
        let into = g.imageLinks.filter { $0.to == .step(c) }
        #expect(into == [GraphLink(.step(a), .step(c))])
        #expect(g.step(b) != nil)
    }

    @Test func aStepFansOutToTwoStepsAndKeepsCustomWiring() {
        var (g, a, b, c) = Self.chain()
        g.connect(.step(a), to: .step(c))     // a feeds b and c; c's input from b is replaced
        #expect(g.imageLinks.filter { $0.from == .step(a) }.count == 2)
        #expect(g.step(b) != nil)
    }

    @Test func parallelBranchesJoinInAMixer() {
        var g = ColorGraph()
        let a = g.steps[0].id
        let p = g.addStep(after: a, kind: .parallel)
        #expect(g.mixerHeads == [a])
        // A third branch wired into the mixer is accepted.
        let q = g.addStep(after: p)
        g.connect(.source, to: .step(q))
        let r = g.connect(.step(q), to: .mixer(a))
        #expect(r == nil)
        #expect(g.imageLinks.contains(GraphLink(.step(q), .mixer(a))))
    }

    @Test func removingAStepHealsTheWires() {
        var (g, a, b, c) = Self.chain()
        g.removeStep(b)
        #expect(g.steps.map(\.id) == [a, c])
        #expect(g.imageLinks.contains(GraphLink(.step(a), .step(c))))
    }

    @Test func removingAStepInCustomWiringHealsToo() {
        var (g, a, b, c) = Self.chain()
        g.connect(.source, to: .step(c))      // custom: c has two... replaced by source
        g.disconnect(GraphLink(.step(a), .step(b)))
        g.removeStep(b)
        #expect(g.step(b) == nil)
        #expect(g.imageLinks.allSatisfy { g.exists($0.from) && g.exists($0.to) })
        _ = a
    }

    @Test func insertingOntoAWirePutsTheStepBetween() {
        var (g, a, b, c) = Self.chain()
        let ok = g.insert(a, onto: GraphLink(.step(b), .step(c)))
        #expect(ok)
        #expect(g.steps.map(\.id) == [b, a, c])
        #expect(!g.hasCustomWiring)
    }

    @Test func insertingOntoItsOwnWireIsRefused() {
        var (g, a, b, _) = Self.chain()
        let ok = g.insert(b, onto: GraphLink(.step(a), .step(b)))
        #expect(!ok)
    }

    @Test func detachingClosesTheGap() {
        var (g, a, b, c) = Self.chain()
        let links = g.imageLinks
        let healed = g.detach(b, in: links)
        #expect(healed.contains(GraphLink(.step(a), .step(c))))
        #expect(!healed.contains { $0.from == .step(b) || $0.to == .step(b) })
    }

    @Test func extractingLeavesTheStepUnwiredAndClosesTheChain() {
        var (g, a, b, c) = Self.chain()
        let ok = g.extract(b)
        #expect(ok)
        #expect(g.hasCustomWiring)
        #expect(g.imageLinks.contains(GraphLink(.step(a), .step(c))))
        #expect(!g.imageLinks.contains { $0.from == .step(b) || $0.to == .step(b) })
        let back = g.insert(b, onto: GraphLink(.step(a), .step(c)))
        #expect(back && !g.hasCustomWiring && g.steps.map(\.id) == [a, b, c])
    }

    @Test func extractingTheOnlyStepDoesNothing() {
        var g = ColorGraph()
        let id = g.steps[0].id
        let ok = g.extract(id)
        #expect(!ok)
    }

    @Test func keyWiresAreStoredRefusedOnCycleAndDroppedWithTheStep() {
        var (g, a, b, c) = Self.chain()
        let k1 = g.connectKey(from: a, to: .step(c))
        #expect(k1 == nil)
        #expect(g.keyLinks == [GraphLink(.step(a), .step(c))])
        #expect(g.usesKeyLink(a) && g.usesKeyLink(c) && !g.usesKeyLink(b))
        #expect(g.isWiringApplied, "key wires are applied by the renderer")
        let k2 = g.connectKey(from: a, to: .step(c))
        let k3 = g.connectKey(from: c, to: .step(a))
        let k4 = g.connectKey(from: a, to: .sink)
        #expect(k2 == .duplicate && k3 == .cycle && k4 == .notAKeyEnd)
        g.removeStep(c)
        #expect(g.keyLinks.isEmpty)
        #expect(g.isWiringApplied)
    }

    @Test func aKeyInputHoldsOneWire() {
        var (g, a, b, c) = Self.chain()
        g.connectKey(from: a, to: .step(c))
        g.connectKey(from: b, to: .step(c))
        #expect(g.keyLinks == [GraphLink(.step(b), .step(c))])
    }

    @Test func settingAKindDropsCustomWiring() {
        var (g, a, b, c) = Self.chain()
        g.disconnect(GraphLink(.step(a), .step(b)))
        #expect(g.hasCustomWiring)
        g.setKind(c, .parallel)
        #expect(!g.hasCustomWiring)
    }

    // MARK: File version

    private static func project(_ g: ColorGraph) throws -> Project {
        var clip = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(3, 1)), start: .zero)
        clip.setActiveGrade(.pro)
        clip.colorGraph = g
        var t = Track(kind: .video)
        try t.overwrite(clip)
        return Project(name: "P", timelines: [Timeline(name: "S", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30)), tracks: [t])])
    }

    @Test func keyWireWritesV80AndRoundTrips() throws {
        var (g, a, _, c) = Self.chain()
        g.connectKey(from: a, to: .step(c))
        let p = try Self.project(g)
        #expect(p.containsV80Content)
        #expect(ProjectFile.writtenVersion(for: p) == 80)
        let back = try ProjectFile.decode(ProjectFile.encode(p), migrations: nil)
        #expect(try #require(back.allClips().first).colorGraph == g)
    }

    @Test func customWiringWritesV80AndRoundTrips() throws {
        var (g, a, b, _) = Self.chain()
        g.disconnect(GraphLink(.step(a), .step(b)))
        let p = try Self.project(g)
        #expect(ProjectFile.writtenVersion(for: p) == 80)
        let back = try ProjectFile.decode(ProjectFile.encode(p), migrations: nil)
        let h = try #require(back.allClips().first?.colorGraph)
        #expect(h.links == g.links && h.hasCustomWiring)
    }

    @Test func plainGraphKeepsItsLowerVersion() throws {
        let (g, _, _, _) = Self.chain()
        let p = try Self.project(g)
        #expect(!p.containsV80Content)
        #expect(ProjectFile.writtenVersion(for: p) == 78)
    }
}
