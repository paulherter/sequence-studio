import Foundation
import Testing
@testable import SQCore

// Pro grade (Color Graph effect, v78): a serial chain of Steps with In / Out LUTs, exclusive with the Simple grade.

@Suite struct ColorGraphTests {
    private static func videoClip() -> Clip {
        Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(3, 1)), start: .zero)
    }

    private static func project(_ clip: Clip) throws -> Project {
        var t = Track(kind: .video)
        try t.overwrite(clip)
        return Project(name: "P", timelines: [Timeline(name: "S", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30)), tracks: [t])])
    }

    // MARK: Graph edits

    @Test func newGraphHasOneNeutralStepAndAutomaticInLUT() {
        let g = ColorGraph()
        #expect(g.steps.count == 1)
        #expect(g.steps[0].isNeutral)
        #expect(g.inputLUT == .automatic)
        #expect(g.outputLUT == nil)
        #expect(g.isNeutral)
    }

    @Test func addRemoveMoveAndEnableSteps() throws {
        var g = ColorGraph()
        let a = g.steps[0].id
        let b = g.addStep(after: a)
        let c = g.addStep(after: a)                     // lands between a and b
        #expect(g.steps.map(\.id) == [a, c, b])
        #expect(g.steps.map(\.label) == ["Step 1", "Step 3", "Step 2"])
        g.moveStep(b, to: 0)
        #expect(g.steps.map(\.id) == [b, a, c])
        g.moveStep(b, to: 99)                          // clamped to the end
        #expect(g.steps.map(\.id) == [a, c, b])
        g.setEnabled(c, false)
        #expect(g.step(c)?.enabled == false)
        g.removeStep(c)
        #expect(g.steps.map(\.id) == [a, b])
        g.removeStep(a); g.removeStep(b)
        #expect(g.steps.count == 1)                    // the last Step stays (reset instead)
        #expect(g.steps[0].isNeutral)
        let appended = g.addStep(after: nil)
        #expect(g.steps.last?.id == appended)
    }

    @Test func primariesMatchCDLWhenLiftIsZero() {
        var p = StepPrimaries()
        p.gain = ColorTriple(1.2, 1.0, 0.8); p.offset = ColorTriple(0.01, 0, -0.02); p.gamma = ColorTriple(0.9, 1, 1.1)
        p.saturation = 0.8
        let rgb: (Float, Float, Float) = (0.4, 0.5, 0.6)
        let out = p.apply(rgb)
        func sop(_ v: Float, _ s: Float, _ o: Float, _ pw: Float) -> Float { let t = v * s + o; return t > 0 ? pow(t, pw) : t }
        let r = sop(0.4, 1.2, 0.01, 0.9), g = sop(0.5, 1, 0, 1), b = sop(0.6, 0.8, -0.02, 1.1)
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        #expect(abs(out.0 - (y + 0.8 * (r - y))) < 1e-5)
        #expect(abs(out.1 - (y + 0.8 * (g - y))) < 1e-5)
        #expect(abs(out.2 - (y + 0.8 * (b - y))) < 1e-5)
        #expect(StepPrimaries().isNeutral)
        let id = StepPrimaries().apply(rgb)
        #expect(id.0 == 0.4 && id.1 == 0.5 && id.2 == 0.6)
    }

    // MARK: Simple | Pro on a clip

    @Test func proSwitchCreatesGraphAndKeepsSimpleValues() throws {
        var c = Self.videoClip()
        var simple = c.color
        simple.effects[0].basic.exposure = 1.5
        c.color = simple
        #expect(c.activeGrade == .simple)
        #expect(c.colorGraph == nil)
        c.setActiveGrade(.pro)
        #expect(c.activeGrade == .pro)
        let g = try #require(c.colorGraph)
        #expect(g.steps.count == 1)
        #expect(c.effects.firstIndex { $0.kind == ClipEffect.colorGraphKind }! > c.effects.lastIndex { $0.isColor }!)
        #expect(c.color.effects[0].basic.exposure == 1.5)   // the dimmed Simple grade keeps its values
        c.setActiveGrade(.simple)
        #expect(c.activeGrade == .simple)
        #expect(c.colorGraph != nil)                        // the dimmed Pro grade keeps its graph
        c.setActiveGrade(.pro)
        #expect(c.effects.filter { $0.kind == ClipEffect.colorGraphKind }.count == 1)
    }

    @Test func renderColorUsesTheActiveGradeOnly() throws {
        var c = Self.videoClip()
        var simple = c.color
        simple.effects[0].basic.exposure = 1.5
        c.color = simple
        #expect(c.renderColor(atLocal: .zero).graph == nil)
        c.setActiveGrade(.pro)
        var g = try #require(c.colorGraph)
        g.steps[0].primaries.saturation = 0.5
        g.inputLUT = .file("/in.cube")
        c.colorGraph = g
        let pro = c.renderColor(atLocal: .zero)
        #expect(pro.graph == g)
        #expect(pro.effects[0].basic.isNeutral)             // Simple sliders are off while Pro is active
        #expect(!pro.isIdentity(rec709Source: true))
        // Pro's eye off: only the In LUT conversion stays.
        let i = try #require(c.effects.firstIndex { $0.kind == ClipEffect.colorGraphKind })
        c.effects[i].enabled = false
        let off = try #require(c.renderColor(atLocal: .zero).graph)
        #expect(off.inputLUT == .file("/in.cube"))
        #expect(off.steps.allSatisfy { $0.isNeutral })
        c.effects[i].enabled = true
        c.setActiveGrade(.simple)
        let back = c.renderColor(atLocal: .zero)
        #expect(back.graph == nil)
        #expect(back.effects[0].basic.exposure == 1.5)
    }

    @Test func graphEffectMakesNoImageFilter() throws {
        var c = Self.videoClip()
        c.setActiveGrade(.pro)
        var g = try #require(c.colorGraph)
        g.steps[0].primaries.saturation = 0
        c.colorGraph = g
        #expect(c.effects.allSatisfy { $0.kind != ClipEffect.colorGraphKind || $0.imageFilter(atLocal: .zero) == nil })
        #expect(EffectCatalog.spec(for: ClipEffect.colorGraphKind) != nil)
    }

    // MARK: Parallel and Layer Steps, Mix, rename (v79)

    @Test func newStepsAreSerialAtMix100() {
        var g = ColorGraph()
        let id = g.addStep(after: nil)
        #expect(g.step(id)?.kind == .serial && g.step(id)?.mix == 100)
    }

    @Test func addStepWithKindAndFirstStepStaysSerial() {
        var g = ColorGraph()
        let p = g.addStep(after: g.steps[0].id, kind: .parallel)
        let l = g.addStep(after: p, kind: .layer)
        #expect(g.steps.map(\.kind) == [.serial, .parallel, .layer])
        g.moveStep(p, to: 0)
        #expect(g.steps[0].kind == .serial, "the first Step is always serial")
        #expect(g.step(l)?.kind == .layer)
    }

    @Test func movingAHeadAwayHandsItsColumnToTheFirstFollower() {
        var g = ColorGraph()
        let a = g.steps[0].id
        let b = g.addStep(after: a, kind: .parallel)
        let c = g.addStep(after: b)
        g.moveStep(a, to: 2)
        #expect(g.steps.map(\.id) == [b, c, a])
        #expect(g.steps.map(\.kind) == [.serial, .serial, .serial])
    }

    @Test func droppingAStepOnAWireMakesItASerialStepInThatGap() {
        var g = ColorGraph()
        let a = g.steps[0].id
        let b = g.addStep(after: a, kind: .parallel)
        let c = g.addStep(after: b)
        let d = g.addStep(after: c)
        g.moveToGap(b, gap: 2)       // columns without b: [a] [c] [d] -> between c and d
        #expect(g.steps.map(\.id) == [a, c, b, d])
        #expect(g.steps.map(\.kind) == [.serial, .serial, .serial, .serial])
        g.moveToGap(a, gap: 0)
        #expect(g.steps.map(\.id) == [a, c, b, d])
        g.moveToGap(d, gap: 0)
        #expect(g.steps.first?.id == d)
    }

    @Test func positionsRoundTripAndTidyUpClearsThem() throws {
        var g = ColorGraph()
        let a = g.steps[0].id
        g.setPosition(a, StepPosition(x: 12.5, y: -30))
        let back = try JSONDecoder().decode(ColorGraph.self, from: JSONEncoder().encode(g))
        #expect(back.steps[0].position == StepPosition(x: 12.5, y: -30))
        g.update(a) { $0.reset() }
        #expect(g.steps[0].position != nil)
        g.tidyUp()
        #expect(g.steps[0].position == nil)
    }

    @Test func columnsGroupAHeadWithItsFollowers() {
        var g = ColorGraph()
        let a = g.steps[0].id
        let b = g.addStep(after: a, kind: .parallel)
        let c = g.addStep(after: b, kind: .layer)
        let d = g.addStep(after: c)
        let e = g.addStep(after: d, kind: .parallel)
        #expect(g.columns.map { $0.map(\.id) } == [[a, b, c], [d, e]])
        #expect(g.serialCount == 2)
    }

    @Test func removingAHeadPromotesItsFirstFollower() {
        var g = ColorGraph()
        let a = g.steps[0].id
        let b = g.addStep(after: a)
        let c = g.addStep(after: b, kind: .parallel)
        g.removeStep(b)
        #expect(g.steps.map(\.id) == [a, c])
        #expect(g.steps[1].kind == .serial)
        g.removeStep(a)
        #expect(g.steps.map(\.id) == [c])
    }

    @Test func kindChangeAndResetKeepsKind() {
        var g = ColorGraph()
        let b = g.addStep(after: nil)
        g.setKind(b, .layer)
        #expect(g.step(b)?.kind == .layer)
        g.setKind(g.steps[0].id, .parallel)
        #expect(g.steps[0].kind == .serial, "the first Step cannot leave the series")
        g.update(b) { $0.mix = 40 }
        g.update(b) { $0.reset() }
        #expect(g.step(b)?.kind == .layer && g.step(b)?.mix == 100)
    }

    @Test func renameTrimsAndIgnoresEmptyNames() {
        var g = ColorGraph()
        let a = g.steps[0].id
        g.rename(a, to: "  Skin  ")
        #expect(g.steps[0].label == "Skin")
        g.rename(a, to: "   ")
        #expect(g.steps[0].label == "Skin")
    }

    @Test func mixAloneIsNotAChange() {
        var s = ColorStep(label: "A")
        s.mix = 30
        #expect(s.isNeutral)
    }

    @Test func v79GraphWritesV79AndRoundTrips() throws {
        var c = Self.videoClip()
        c.setActiveGrade(.pro)
        var g = try #require(c.colorGraph)
        let p2 = g.addStep(after: nil, kind: .parallel)
        let l = g.addStep(after: p2, kind: .layer)
        g.update(l) { $0.mix = 55; $0.label = "Sky"; $0.qualifier = ColorQualifier() }
        c.colorGraph = g
        let p = try Self.project(c)
        #expect(p.containsV79Content)
        #expect(ProjectFile.writtenVersion(for: p) == 79)
        let back = try ProjectFile.decode(ProjectFile.encode(p), migrations: nil)
        #expect(try #require(back.allClips().first).colorGraph == g)
    }

    @Test func serialOnlyGraphStaysV78() throws {
        var c = Self.videoClip()
        c.setActiveGrade(.pro)
        var g = try #require(c.colorGraph)
        let s2 = g.addStep(after: nil)
        g.rename(s2, to: "Renamed")
        c.colorGraph = g
        let p = try Self.project(c)
        #expect(!p.containsV79Content)
        #expect(ProjectFile.writtenVersion(for: p) == 78)
    }

    @Test func oldStepJSONDecodesAsSerialMix100() throws {
        let json = #"{"id":"7C1C5D2A-1111-4C3B-9E2E-000000000001","label":"A"}"#
        let s = try JSONDecoder().decode(ColorStep.self, from: Data(json.utf8))
        #expect(s.kind == .serial && s.mix == 100)
    }

    // MARK: File

    @Test func graphWritesV78AndRoundTrips() throws {
        var c = Self.videoClip()
        #expect(!(try Self.project(c)).containsV78Content)
        c.setActiveGrade(.pro)
        var g = try #require(c.colorGraph)
        let s2 = g.addStep(after: nil)
        g.update(s2) {
            $0.primaries.gain = ColorTriple(1.1, 1, 0.9)
            $0.curves.master = [CurvePoint(0, 0.05), CurvePoint(1, 0.95)]
            $0.lut = .file("/look.cube"); $0.lutIntensity = 60
            $0.qualifier = ColorQualifier()
            $0.window = StepWindow(shape: .rectangle)
        }
        g.outputLUT = .file("/out.cube"); g.outputLUTIntensity = 80
        c.colorGraph = g
        let p = try Self.project(c)
        #expect(p.containsV78Content)
        #expect(ProjectFile.writtenVersion(for: p) == 78)
        #expect(ProjectFile.currentVersion >= 78)
        let back = try ProjectFile.decode(ProjectFile.encode(p), migrations: nil)
        let clip = try #require(back.allClips().first)
        #expect(clip.colorGraph == g)
        #expect(clip.activeGrade == .pro)
    }

    @Test func stepDecodesWithMissingFieldsAsDefaults() throws {
        let json = #"{"id":"7C1C5D2A-1111-4C3B-9E2E-000000000001","label":"A"}"#
        let s = try JSONDecoder().decode(ColorStep.self, from: Data(json.utf8))
        #expect(s.label == "A" && s.enabled && s.isNeutral && s.lut == nil && s.lutIntensity == 100)
    }

    // MARK: CDL / EDL import

    @Test func parsesCCAndCCCAndCDL() throws {
        let cc = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ColorCorrection id="shot_010">
          <SOPNode><Slope>1.1 1.0 0.9</Slope><Offset>0.01 0 -0.02</Offset><Power>0.95 1 1.05</Power></SOPNode>
          <SatNode><Saturation>0.85</Saturation></SatNode>
        </ColorCorrection>
        """
        let a = try ColorDecisionImport.parse(Data(cc.utf8), fileExtension: "cc")
        #expect(a.count == 1)
        #expect(a[0].id == "shot_010")
        #expect(a[0].slope == ColorTriple(1.1, 1.0, 0.9))
        #expect(a[0].offset == ColorTriple(0.01, 0, -0.02))
        #expect(a[0].power == ColorTriple(0.95, 1, 1.05))
        #expect(a[0].saturation == 0.85)
        let p = a[0].primaries
        #expect(p.gain == a[0].slope && p.offset == a[0].offset && p.gamma == a[0].power && p.saturation == 0.85)
        #expect(p.lift == ColorTriple(0, 0, 0))

        let ccc = """
        <ColorCorrectionCollection xmlns="urn:ASC:CDL:v1.01">
          <ColorCorrection id="a"><SOPNode><Slope>2 2 2</Slope></SOPNode></ColorCorrection>
          <ColorCorrection id="b"><SATNode><Saturation>0.5</Saturation></SATNode></ColorCorrection>
        </ColorCorrectionCollection>
        """
        let b = try ColorDecisionImport.parse(Data(ccc.utf8), fileExtension: "ccc")
        #expect(b.map(\.id) == ["a", "b"])
        #expect(b[0].slope == ColorTriple(2, 2, 2) && b[0].offset == ColorTriple(0, 0, 0) && b[0].saturation == 1)
        #expect(b[1].slope == ColorTriple(1, 1, 1) && b[1].saturation == 0.5)

        let cdl = """
        <ColorDecisionList xmlns="urn:ASC:CDL:v1.01"><ColorDecision>
          <ColorCorrection id="x"><SOPNode><Slope>1 1 1</Slope><Offset>0.1 0.1 0.1</Offset><Power>1 1 1</Power></SOPNode></ColorCorrection>
        </ColorDecision></ColorDecisionList>
        """
        let d = try ColorDecisionImport.parse(Data(cdl.utf8), fileExtension: "cdl")
        #expect(d.count == 1 && d[0].offset == ColorTriple(0.1, 0.1, 0.1))
    }

    @Test func parsesEDLComments() throws {
        let edl = """
        TITLE: TEST
        001  A001C003 V     C        01:00:00:00 01:00:02:00 00:00:00:00 00:00:02:00
        * FROM CLIP NAME: A001C003.MOV
        *ASC_SOP (1.2 1.0 0.8)(0.0 0.01 -0.01)(1.0 1.0 1.0)
        *ASC_SAT 0.9
        002  A001C004 V     C        01:00:05:00 01:00:06:00 00:00:02:00 00:00:03:00
        *ASC_SAT 1.2
        003  A001C005 V     C        01:00:07:00 01:00:08:00 00:00:03:00 00:00:04:00
        """
        let e = try ColorDecisionImport.parse(Data(edl.utf8), fileExtension: "edl")
        #expect(e.count == 2)
        #expect(e[0].id == "A001C003.MOV")
        #expect(e[0].slope == ColorTriple(1.2, 1.0, 0.8))
        #expect(e[0].offset == ColorTriple(0, 0.01, -0.01))
        #expect(e[0].saturation == 0.9)
        #expect(e[1].id == "002" && e[1].saturation == 1.2 && e[1].slope == ColorTriple(1, 1, 1))
    }

    @Test func importedDecisionsAreClampedToTheStepRanges() throws {
        var d = ColorDecision(id: "x")
        d.slope = ColorTriple(1e30, -2, 1.5)
        d.offset = ColorTriple(-5, 1e30, 0.2)
        d.power = ColorTriple(0, -1, 1e30)
        d.saturation = 1e30
        let p = d.primaries
        #expect(p.gain == ColorTriple(StepPrimaries.gainRange.upperBound, 0, 1.5))
        #expect(p.offset == ColorTriple(-1, 1, 0.2))
        #expect(p.gamma == ColorTriple(StepPrimaries.gammaRange.lowerBound, StepPrimaries.gammaRange.lowerBound, StepPrimaries.gammaRange.upperBound),
                "power 0 or below takes the smallest exponent")
        #expect(p.saturation == StepPrimaries.saturationRange.upperBound)
        d.saturation = -1
        #expect(d.primaries.saturation == 0)
        // Huge values in a file parse and come out clamped.
        let cc = "<ColorCorrection id=\"h\"><SOPNode><Slope>1e30 1 1</Slope><Power>0 1 1</Power></SOPNode></ColorCorrection>"
        let h = try ColorDecisionImport.parse(Data(cc.utf8), fileExtension: "cc")[0].primaries
        #expect(h.gain.r == 4 && h.gamma.r == 0.1)
    }

    @Test func pastedGraphFollowsTheCopiedGrade() throws {
        var target = Self.videoClip()
        var pro = ColorGraph(); pro.isActive = true
        pro.update(pro.steps[0].id) { $0.primaries.contrast = 1.3 }
        // A Pro grade arrives: the target shows it, Pro active.
        target.applyCopiedGraph(pro)
        #expect(target.activeGrade == .pro && target.colorGraph?.steps[0].primaries.contrast == 1.3)
        // A Simple grade arrives: the target goes Simple, its graph values stay.
        target.applyCopiedGraph(nil)
        #expect(target.activeGrade == .simple && target.colorGraph?.steps[0].primaries.contrast == 1.3)
        // An inactive graph arrives: the target takes its values but stays Simple.
        var off = pro; off.isActive = false; off.update(off.steps[0].id) { $0.primaries.contrast = 0.7 }
        target.applyCopiedGraph(off)
        #expect(target.activeGrade == .simple && target.colorGraph?.steps[0].primaries.contrast == 0.7)
        // Simple onto a clip without a graph adds nothing.
        var plain = Self.videoClip()
        plain.applyCopiedGraph(nil)
        #expect(plain.colorGraph == nil)
    }

    @Test func movingTheOnlyStepChangesNothing() {
        var g = ColorGraph()
        let only = g.steps[0]
        g.moveStep(only.id, to: 0); g.moveStep(only.id, to: 5); g.moveStep(only.id, to: -3)
        #expect(g.steps == [only])
        g.moveStep(UUID(), to: 0)
        #expect(g.steps == [only])
        let b = g.addStep(after: nil)
        g.moveStep(b, to: -4)
        #expect(g.steps.count == 2 && g.steps[0].id == b)
    }

    private static func proClip(contrast: Float) -> Clip {
        var c = videoClip()
        var g = ColorGraph(); g.isActive = true
        g.update(g.steps[0].id) { $0.primaries.contrast = contrast }
        c.colorGraph = g
        return c
    }

    @Test func pasteAttributesCarriesTheGraph() {
        var source = Self.proClip(contrast: 1.4)
        source.effects.insert(ColorGradeLinkTests.warm(30), at: 0)
        var simple = Self.videoClip()
        simple.effects.append(ColorGradeLinkTests.warm(10))
        let full = simple.pastingAttributes(from: source)
        #expect(full.activeGrade == .pro && full.colorGraph?.steps[0].primaries.contrast == 1.4)
        #expect(full.effects.filter(\.isColorGraph).count == 1)
        #expect(full.colorGraphIndex! > full.effects.lastIndex(where: \.isColor)!, "placed behind the Color effects")
        let over = Self.proClip(contrast: 0.6).pastingAttributes(from: source)
        #expect(over.effects.filter(\.isColorGraph).count == 1 && over.colorGraph?.steps[0].primaries.contrast == 1.4)
        // A Simple source onto a Pro target: the target renders the source's grade.
        var plain = Self.videoClip()
        plain.effects.append(ColorGradeLinkTests.warm(25))
        let off = Self.proClip(contrast: 1.4).pastingAttributes(from: plain)
        #expect(off.activeGrade == .simple && off.colorGradeEffects.count == 1)
    }

    @Test func gradeLinksCarryTheGraph() {
        let a = ColorGradeLinkTests.clip("A")
        let b = ColorGradeLinkTests.clip("B", start: Time(4, 1))
        var p = ColorGradeLinkTests.project([a, b])
        #expect(p.linkGrades([a.id, b.id], source: a.id) != nil)
        // Edit A: Pro on.
        var old = p
        p.forEachClipInPlace { c in
            guard c.id == a.id else { return }
            var g = ColorGraph(); g.isActive = true
            g.update(g.steps[0].id) { $0.primaries.contrast = 1.5 }
            c.colorGraph = g
        }
        p.propagateGradeLinks(from: old)
        var bb = ColorGradeLinkTests.find(p, b.id)
        #expect(bb.activeGrade == .pro && bb.colorGraph?.steps[0].primaries.contrast == 1.5)
        // Edit A back to Simple: B follows.
        old = p
        p.forEachClipInPlace { c in if c.id == a.id { c.setActiveGrade(.simple) } }
        p.propagateGradeLinks(from: old)
        bb = ColorGradeLinkTests.find(p, b.id)
        #expect(bb.activeGrade == .simple)
    }

    @Test func rejectsFilesWithoutDecisions() {
        #expect(throws: ColorDecisionImport.ImportError.self) {
            try ColorDecisionImport.parse(Data("<a/>".utf8), fileExtension: "cdl")
        }
        #expect(throws: ColorDecisionImport.ImportError.self) {
            try ColorDecisionImport.parse(Data("<ColorCorrection><SOPNode><Slope>1 x 1</Slope></SOPNode></ColorCorrection>".utf8),
                                          fileExtension: "cc")
        }
    }
}

// Send to Pro: the Simple grade's values as Steps.
@Suite struct ColorGraphMixerWiringTests {
    /// A graph of `kinds` (the first is serial).
    private func graph(_ kinds: [StepKind]) -> ColorGraph {
        var g = ColorGraph()
        g.steps[0].label = "S1"
        for (i, k) in kinds.enumerated().dropFirst() { g.addStep(after: g.steps.last?.id, kind: k); g.steps[i].label = "S\(i + 1)" }
        return g
    }
    private func labels(_ g: ColorGraph) -> [String] { g.steps.map(\.label) }
    private func kinds(_ g: ColorGraph) -> [StepKind] { g.steps.map(\.kind) }

    @Test func deletingAMixerTurnsItsInputsIntoSerialSteps() {
        var g = graph([.serial, .parallel, .layer, .serial])
        let head = g.steps[0].id
        g.steps[0].mixerPosition = StepPosition(x: 1, y: 2)
        #expect(g.stack(of: head).count == 3)
        let r1 = g.dissolveMixer(head)
        #expect(r1)
        #expect(kinds(g) == [.serial, .serial, .serial, .serial])
        #expect(labels(g) == ["S1", "S2", "S3", "S4"], "the order stays")
        #expect(g.steps[0].mixerPosition == nil)
        let r2 = g.dissolveMixer(head)
        #expect(!r2, "a lone Step has no mixer")
    }

    @Test func aWireFromAStepsOutputMakesTheTargetFollowIt() {
        var g = graph([.serial, .serial, .serial])
        let (a, b, c) = (g.steps[0].id, g.steps[1].id, g.steps[2].id)
        let r3 = g.follow(c, after: a)
        #expect(r3)
        #expect(g.steps.map(\.id) == [a, c, b])
        let r4 = g.follow(c, after: nil)
        #expect(r4, "from the source: the front")
        #expect(g.steps.map(\.id) == [c, a, b])
        let r5 = g.follow(c, after: c)
        #expect(!r5, "a loop snaps back")
        let r6 = g.follow(UUID(), after: a)
        #expect(!r6)
    }

    @Test func aWireFromAStackBranchDoesNotMapButFromItsMixerDoes() {
        var g = graph([.serial, .parallel, .serial])
        let (a, p, c) = (g.steps[0].id, g.steps[1].id, g.steps[2].id)
        let before = g
        let r7 = g.follow(c, after: p)
        #expect(r7 == false)
        #expect(g == before)
        let r8 = g.follow(c, after: a)
        #expect(r8, "the head names the stack's mixer")
        #expect(g.steps.map(\.id) == [a, p, c])
        let r9 = g.follow(p, after: a)
        #expect(!r9, "a stack member cannot follow its own mixer")
    }

    @Test func aWireIntoAMixerAddsAParallelInput() {
        var g = graph([.serial, .parallel, .serial, .serial])
        let (a, c, d) = (g.steps[0].id, g.steps[2].id, g.steps[3].id)
        let r10 = g.join(d, stackOf: a)
        #expect(r10)
        #expect(g.steps.map(\.kind) == [.serial, .parallel, .parallel, .serial])
        #expect(g.steps[2].id == d && g.steps[3].id == c)
        #expect(g.stack(of: a).count == 3)
        let r11 = g.join(d, stackOf: a)
        #expect(!r11, "already an input")
        let r12 = g.join(c, stackOf: c)
        #expect(!r12, "a lone Step has no mixer")
    }

    @Test func mixerPositionsSurviveCodingAndTidyUpClearsThem() throws {
        var g = graph([.serial, .parallel])
        g.setMixerPosition(g.steps[0].id, StepPosition(x: 5, y: 6))
        g.setPosition(g.steps[1].id, StepPosition(x: 1, y: 2))
        let back = try JSONDecoder().decode(ColorGraph.self, from: JSONEncoder().encode(g))
        #expect(back == g)
        #expect(g.steps.contains { $0.usesV79Fields })
        g.tidyUp()
        #expect(g.steps.allSatisfy { $0.position == nil && $0.mixerPosition == nil })
    }
}

@Suite struct ColorGraphFromSimpleTests {
    @Test func neutralSimpleGivesOneNeutralActiveStep() {
        let g = ColorGraph(simple: .default)
        #expect(g.isActive && g.steps.count == 1 && g.steps[0].isNeutral)
        #expect(g.inputLUT == .automatic)
    }

    @Test func basicValuesLandInStepOne() {
        var c = ClipColor.default
        c.effects[0].basic.exposure = 1
        c.effects[0].basic.contrast = 50
        c.effects[0].basic.saturation = 120
        c.effects[0].curves.master = [CurvePoint(0, 0), CurvePoint(0.5, 0.6), CurvePoint(1, 1)]
        let g = ColorGraph(simple: c)
        let p = g.steps[0].primaries
        #expect(g.steps.count == 1)
        #expect(abs(p.gain.r - 2) < 1e-5 && abs(p.gain.g - 2) < 1e-5)
        #expect(abs(p.contrast - 1.5) < 1e-5)
        #expect(abs(p.saturation - 1.2) < 1e-5)
        #expect(g.steps[0].curves == c.effects[0].curves)
    }

    @Test func disabledSectionsAndSecondEffectAreRespected() {
        var c = ClipColor.default
        c.effects[0].basic.contrast = 40
        c.effects[0].setEnabled(.basicCorrection, false)
        c.addEffect()
        c.effects[1].wheels.saturation = 50
        let g = ColorGraph(simple: c)
        #expect(g.steps.count == 1, "the disabled Basic section leaves effect 1 neutral")
        #expect(abs(g.steps[0].primaries.saturation - 0.5) < 1e-5)
    }

    @Test func valuesStayInSliderRanges() {
        var c = ClipColor.default
        c.effects[0].basic.exposure = 5
        c.effects[0].basic.saturation = 200
        c.effects[0].wheels.saturation = 200
        let p = ColorGraph(simple: c).steps[0].primaries
        #expect(p.gain.r == StepPrimaries.gainRange.upperBound)
        #expect(p.saturation == StepPrimaries.saturationRange.upperBound)
    }
}
