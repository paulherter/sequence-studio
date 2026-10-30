import Foundation
import Testing
@testable import SQCore

@Suite struct StyleKitTests {
    static let red = EffectColor(red: 1, green: 0, blue: 0)
    static let blue = EffectColor(red: 0, green: 0, blue: 1)

    static func brand() -> StyleKit {
        var k = StyleKit()
        k.fonts["brand"] = "Avenir-Black"
        k.colors["text"] = .white
        k.colors["accent"] = red
        k.pill = StylePill(color: .token("accent"))
        k.caption = CaptionStyleSpec(baseStyle: "pill", font: .token("brand"), size: 70, textColor: .token("text"), usesPill: true)
        k.motion = MotionDefaults(duration: Time(3, 10), curve: MotionCurve.easeOut.rawValue)
        return k
    }

    // MARK: StyleValue

    @Test func styleValueResolvesLiteralsAndTokens() {
        let k = Self.brand()
        let color: (String) -> EffectColor? = { k.color($0) }
        let font: (String) -> String? = { k.font($0) }
        let literal = StyleValue<EffectColor>.literal(Self.blue).resolve(color)
        let token = StyleValue<EffectColor>.token("accent").resolve(color)
        let missing = StyleValue<EffectColor>.token("missing").resolve(color)
        let brandFont = StyleValue<String>.token("brand").resolve(font)
        #expect(literal == Self.blue)
        #expect(token == Self.red)
        #expect(missing == nil)
        #expect(brandFont == "Avenir-Black")
    }

    @Test func styleValueCodableShape() throws {
        let data = try JSONEncoder().encode([StyleValue<String>.token("brand"), .literal("Helvetica")])
        let obj = try #require(JSONSerialization.jsonObject(with: data) as? [[String: String]])
        #expect(obj == [["token": "brand"], ["literal": "Helvetica"]])
        let back = try JSONDecoder().decode([StyleValue<String>].self, from: data)
        #expect(back == [.token("brand"), .literal("Helvetica")])
    }

    @Test func styleValueRejectsAnObjectWithNeitherKey() {
        let bad = Data(#"{"x":"y"}"#.utf8)
        #expect(throws: (any Error).self) { _ = try JSONDecoder().decode(StyleValue<String>.self, from: bad) }
    }

    // MARK: Motion defaults

    @Test func motionDefaultsSetDurationAndCurveOfNewMotionEffects() throws {
        var c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(5, 1)), start: .zero)
        let added = c.addEffect(kind: ClipEffect.popKind, motionDefaults: Self.brand().motion)
        let id = try #require(added)
        let e = try #require(c.effects.first { $0.id == id })
        #expect(e.parameters[ClipEffect.motionDurationKey]?.value == 0.3)
        #expect(e.parameters[ClipEffect.motionCurveKey]?.value == Double(MotionCurve.easeOut.rawValue))
    }

    @Test func motionDefaultsLeaveOtherEffectsAlone() throws {
        var c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(5, 1)), start: .zero)
        var plain = try #require(ClipEffect.make(kind: ClipEffect.gaussianBlurKind))
        plain.parameters[ClipEffect.blurrinessKey] = AnimatedProperty(20)   // the applied start value (AUDIT G13)
        let added = c.addEffect(kind: ClipEffect.gaussianBlurKind, motionDefaults: Self.brand().motion)
        let id = try #require(added)
        #expect(c.effects.first { $0.id == id }?.parameters == plain.parameters)
    }

    // MARK: Merge (import keeps the importer's brand)

    @Test func importAddsMissingTokensAndKeepsExistingOnes() {
        var mine = StyleKit()
        mine.fonts["brand"] = "Futura-Bold"
        mine.colors["accent"] = Self.blue
        let (merged, report) = mine.merging(Self.brand())
        #expect(merged.fonts["brand"] == "Futura-Bold")
        #expect(merged.colors["accent"] == Self.blue)
        #expect(merged.colors["text"] == .white)
        #expect(merged.pill == Self.brand().pill)
        #expect(merged.caption == Self.brand().caption)
        #expect(merged.motion == Self.brand().motion)
        #expect(report.keptTokens.sorted() == ["color:accent", "font:brand"])
        #expect(report.addedTokens.contains("color:text"))
    }

    @Test func importKeepsTheImportersPillCaptionAndMotion() {
        var mine = StyleKit()
        mine.pill = StylePill(color: .literal(Self.blue))
        mine.caption = CaptionStyleSpec(baseStyle: "default")
        mine.motion = MotionDefaults(duration: Time(1, 2), curve: 0)
        let (merged, _) = mine.merging(Self.brand())
        #expect(merged.pill == mine.pill)
        #expect(merged.caption == mine.caption)
        #expect(merged.motion == mine.motion)
    }

    @Test func importAddsCaptionPositionOnlyWhereTheImporterHasNone() {
        let pos = CaptionPosition(vertical: .middle, offsetY: 0.207)
        var theirs = StyleKit(); theirs.captionPosition = pos
        let (added, report) = StyleKit().merging(theirs)
        #expect(added.captionPosition == pos)
        #expect(report.addedTokens.contains("captionPosition"))
        var mine = StyleKit(); mine.captionPosition = CaptionPosition(vertical: .top)
        #expect(mine.merging(theirs).kit.captionPosition == mine.captionPosition)
    }

    @Test func importAddsLooksAndRenamesAConflictingOne() {
        var mine = StyleKit()
        mine.looks["pop"] = StyleKitLook(name: "Pop", payload: Data("mine".utf8), payloadVersion: 1)
        var theirs = StyleKit()
        theirs.looks["pop"] = StyleKitLook(name: "Pop", payload: Data("theirs".utf8), payloadVersion: 1)
        theirs.looks["box"] = StyleKitLook(name: "Box", payload: Data("box".utf8), payloadVersion: 1)
        let (merged, report) = mine.merging(theirs)
        #expect(merged.looks["pop"] == mine.looks["pop"])
        #expect(merged.looks["box"] == theirs.looks["box"])
        #expect(merged.looks["pop-2"]?.payload == Data("theirs".utf8))
        #expect(merged.looks["pop-2"]?.name == "Pop 2")
        #expect(report.addedLooks.sorted() == ["box", "pop-2"])
    }

    @Test func reimportingTheSameKitChangesNothing() {
        let k = Self.brand()
        let (merged, report) = k.merging(k)
        #expect(merged == k)
        #expect(report.addedTokens.isEmpty && report.addedLooks.isEmpty)
    }

    // MARK: .sqstyle file

    @Test func sqstyleRoundTrip() throws {
        var k = Self.brand()
        k.looks["pop"] = StyleKitLook(name: "Pop", payload: Data("x".utf8), payloadVersion: 1)
        let back = try StyleKitFile.decode(StyleKitFile.encode(k))
        #expect(back == k)
    }

    /// A kit whose looks are all caption looks (payload v1) is written as before; one Look with a newer payload makes
    /// the file version 2, which a build that only knows version 1 refuses instead of dropping the Look.
    @Test func sqstyleVersionFollowsTheLookPayloads() throws {
        func version(_ kit: StyleKit) throws -> Int? {
            (try JSONSerialization.jsonObject(with: StyleKitFile.encode(kit)) as? [String: Any])?["formatVersion"] as? Int
        }
        var k = Self.brand()
        #expect(try version(k) == 1)
        k.looks["old"] = StyleKitLook(name: "Old", payload: Data("x".utf8), payloadVersion: 1)
        #expect(try version(k) == 1)
        k.looks["new"] = StyleKitLook(name: "New", payload: Data("y".utf8), payloadVersion: 2)
        #expect(try version(k) == 2)
        #expect(try StyleKitFile.decode(StyleKitFile.encode(k)) == k)
        #expect(StyleKitFile.formatVersion == 2)
    }

    @Test func sqstyleFromANewerBuildIsRefused() throws {
        let data = try StyleKitFile.encode(Self.brand())
        var obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj["formatVersion"] = StyleKitFile.formatVersion + 1
        let newer = try JSONSerialization.data(withJSONObject: obj)
        let expected = StyleKitFile.FileError.newerVersion(found: StyleKitFile.formatVersion + 1, supported: StyleKitFile.formatVersion)
        #expect(throws: expected) { _ = try StyleKitFile.decode(newer) }
        let junk = Data("nope".utf8)
        #expect(throws: StyleKitFile.FileError.corrupt) { _ = try StyleKitFile.decode(junk) }
    }

    @Test func sqstyleWritesAndReadsAFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kit-\(UUID().uuidString).sqstyle")
        defer { try? FileManager.default.removeItem(at: url) }
        try StyleKitFile.write(Self.brand(), to: url)
        let read = try StyleKitFile.read(from: url)
        #expect(read == Self.brand())
        #expect(StyleKitFile.fileExtension == "sqstyle")
    }

    // MARK: ProjectFile v33

    @Test func styleKitRoundTripsThroughTheProjectFile() throws {
        var p = Project(name: "P")
        p.styleKit = Self.brand()
        let back = try ProjectFile.decode(ProjectFile.encode(p), migrations: ProjectFile.migrations)
        #expect(back.styleKit == Self.brand())
        #expect(back == p)
    }

    @Test func aProjectWithoutAKitWritesNoKey() throws {
        let data = try JSONEncoder().encode(Project(name: "P"))
        let obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["styleKit"] == nil)
    }

    @Test func v33IsCurrentAndV32ToV33IsIdentity() throws {
        #expect(ProjectFile.currentVersion >= 33)
        #expect(ProjectFile.realMigrations[32] == nil)
        let obj: ProjectFile.JSONObject = ["formatVersion": 32, "project": ["name": "P"] as ProjectFile.JSONObject]
        let step = try #require(ProjectFile.migrations[32])
        let out = try step(obj)
        #expect(jsonEqual(out, obj))
    }

    @Test func aV32FileOpensWithoutAKit() throws {
        let data = try ProjectFile.encode(Project(name: "P"))
        var obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj["formatVersion"] = 32
        let back = try ProjectFile.decode(JSONSerialization.data(withJSONObject: obj), migrations: ProjectFile.migrations)
        #expect(back.styleKit == nil)
    }

    @Test func aNewerProjectFileIsRefused() throws {
        let data = try ProjectFile.encode(Project(name: "P"))
        var obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj["formatVersion"] = ProjectFile.currentVersion + 1
        let newer = try JSONSerialization.data(withJSONObject: obj)
        let expected = ProjectFileError.newerVersion(found: ProjectFile.currentVersion + 1, supported: ProjectFile.currentVersion)
        #expect(throws: expected) { _ = try ProjectFile.decode(newer, migrations: ProjectFile.migrations) }
    }

    // MARK: Review fixes

    @Test func rewriteGeneratorsReachesVariantOverrides() throws {
        let g = GeneratorRef(kind: "text", payload: Data("a".utf8))
        var c = Clip(name: "t", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(1, 1)), start: .zero, generator: g)
        let vid = UUID()
        c.variantOverrides = [vid: VariantOverride(generator: GeneratorRef(kind: "text", payload: Data("v".utf8)))]
        var p = Project(name: "P", timelines: [Timeline(name: "s", frameDuration: Time(1, 30), tracks: [Track(kind: .video, clips: [c])])])
        let n = p.rewriteGenerators { GeneratorRef(kind: $0.kind, payload: $0.payload + Data("!".utf8)) }
        let out = p.timelines[0].tracks[0].clips[0]
        #expect(n == 1)
        #expect(out.generator?.payload == Data("a!".utf8))
        #expect(out.variantOverrides[vid]?.generator?.payload == Data("v!".utf8))
    }

    @Test func aMalformedKitIsDroppedAndTheProjectStillOpens() throws {
        let data = try ProjectFile.encode(Project(name: "P"))
        var obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var proj = try #require(obj["project"] as? [String: Any])
        proj["styleKit"] = ["fonts": 5, "caption": "nope"]
        obj["project"] = proj
        let raw = try JSONSerialization.data(withJSONObject: obj)
        let back = try ProjectFile.decode(raw, migrations: ProjectFile.migrations)
        #expect(back.name == "P")
        #expect(back.styleKit == nil)
    }

    @Test func hostileSizesAreClamped() throws {
        let spec = CaptionStyleSpec(baseStyle: "pill", size: 1e12)
        #expect(spec.size == CaptionStyleSpec.maxSize)
        let json = #"{"baseStyle":"pill","size":-5,"usesPill":true}"#
        let decoded = try JSONDecoder().decode(CaptionStyleSpec.self, from: Data(json.utf8))
        #expect(decoded.size == 1)
        let pill = StylePill(color: .token("x"), horizontalEm: 1e9, verticalEm: -3, cornerRadius: 1e12)
        #expect(pill.horizontalEm == StylePill.maxEm && pill.verticalEm == 0 && pill.cornerRadius == 10_000)
        let pj = #"{"color":{"token":"x"},"horizontalEm":1e9,"verticalEm":0.2,"cornerRadius":-4}"#
        let dp = try JSONDecoder().decode(StylePill.self, from: Data(pj.utf8))
        #expect(dp.horizontalEm == StylePill.maxEm && dp.cornerRadius == 0)
    }

    @Test func oversizedSqstyleIsRefused() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("big-\(UUID().uuidString).sqstyle")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(count: StyleKitFile.maxFileSize + 1).write(to: url)
        #expect(throws: StyleKitFile.FileError.tooLarge) { _ = try StyleKitFile.read(from: url) }
    }
}
