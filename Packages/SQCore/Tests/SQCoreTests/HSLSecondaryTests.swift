import Foundation
import Testing
@testable import SQCore

/// Color Range (HSL secondary, v48): a hue / saturation / luma qualifier with softness and the correction applied inside.
@Suite struct HSLSecondaryTests {
    static func skinWarm() -> HSLSecondary {
        var r = HSLSecondary()
        r.saturation = 80; r.temperature = 10
        return r
    }

    @Test func defaultsTargetSkinTonesAndAreNeutral() {
        let r = HSLSecondary()
        #expect(r.hueCenter == 25 && r.hueWidth == 50)
        #expect(r.satMin == 10 && r.satMax == 100 && r.lumMin == 0 && r.lumMax == 100)
        #expect(r.softness == 20 && !r.invert)
        #expect(r.isCorrectionNeutral)
        #expect(!Self.skinWarm().isCorrectionNeutral)
        var h = HSLSecondary(); h.hueShift = 5
        #expect(!h.isCorrectionNeutral)
        var e = HSLSecondary(); e.exposure = -0.5
        #expect(!e.isCorrectionNeutral)
    }

    @Test func clampingKeepsEveryValueInItsRange() {
        var r = HSLSecondary()
        r.hueCenter = -30; r.hueWidth = 500; r.satMin = 80; r.satMax = 20; r.lumMin = -5; r.lumMax = 140
        r.softness = 300; r.hueShift = 400; r.saturation = -10; r.exposure = 9; r.temperature = 200; r.tint = -200
        let c = r.clamped()
        #expect(c.hueCenter == 330 && c.hueWidth == 360)
        #expect(c.satMin == 20 && c.satMax == 80, "a crossed min / max pair is swapped")
        #expect(c.lumMin == 0 && c.lumMax == 100 && c.softness == 100)
        #expect(c.hueShift == 180 && c.saturation == 0 && c.exposure == HSLSecondary.exposureRange.upperBound)
        #expect(c.temperature == 100 && c.tint == -100)
    }

    @Test func sectionIsImplementedNeutralUntilARangeCorrectsAndResetRemovesIt() {
        var e = ColorEffect(id: 1)
        #expect(e.hslSecondary == nil && e.isNeutral(.hslSecondary))
        e.hslSecondary = HSLSecondary()
        #expect(e.isNeutral(.hslSecondary), "a qualifier without a correction changes nothing")
        e.hslSecondary = Self.skinWarm()
        #expect(!e.isNeutral(.hslSecondary))
        #expect(!ClipColor(effects: [e]).isIdentity(rec709Source: true))
        e.setEnabled(.hslSecondary, false)
        #expect(ClipColor(effects: [e]).isIdentity(rec709Source: true), "switched off it changes nothing")
        e.reset(.hslSecondary, isPrimary: true)
        #expect(e.hslSecondary == nil)
        #expect(!e.isEnabled(.hslSecondary), "reset keeps the toggle")
    }

    @Test func colorEffectCodableWritesTheRangeOnlyWhenPresent() throws {
        var e = ColorEffect(id: 1)
        let plain = String(decoding: try JSONEncoder().encode(e), as: UTF8.self)
        #expect(!plain.contains("hslSecondary"))
        e.hslSecondary = Self.skinWarm()
        let back = try JSONDecoder().decode(ColorEffect.self, from: JSONEncoder().encode(e))
        #expect(back == e)
        // Missing keys of a partial range decode to the defaults.
        let partial = try JSONDecoder().decode(HSLSecondary.self, from: Data(#"{"saturation":50}"#.utf8))
        var want = HSLSecondary(); want.saturation = 50
        #expect(partial == want)
    }

    @Test func gradeDataCarriesTheRangeThroughTheClipEffect() throws {
        var e = ColorEffect(id: 1)
        e.hslSecondary = Self.skinWarm()
        let fx = ClipEffect.colorGrade(e)
        #expect(fx.grade?.hslSecondary == Self.skinWarm())
        #expect(fx.colorEffect(atLocal: nil, id: 1).hslSecondary == Self.skinWarm())
        let plain = ClipEffect.colorGrade(ColorEffect(id: 1))
        #expect(plain.grade?.hslSecondary == nil)
        let json = String(decoding: try JSONEncoder().encode(ColorGradeData()), as: UTF8.self)
        #expect(!json.contains("hslSecondary"))
        var d = ColorGradeData(); d.hslSecondary = Self.skinWarm()
        #expect(try JSONDecoder().decode(ColorGradeData.self, from: JSONEncoder().encode(d)) == d)
    }

    @Test func applyColorEditWritesTheRangeOnlyWhenItChanged() {
        var base = ColorEffect(id: 1)
        base.basic.temperature = 5
        var fx = ClipEffect.colorGrade(base)
        // An edit of another value leaves the range alone (nil stays nil).
        var edited = base; edited.basic.temperature = 9
        let ok_edited = fx.applyColorEdit(from: base, to: edited, atLocal: nil); #expect(ok_edited)
        #expect(fx.colorData.hslSecondary == nil)
        // Adding a range writes it; a later unrelated edit with a stale base keeps it.
        let before = fx.colorEffect(atLocal: nil, id: 1)
        var withRange = before; withRange.hslSecondary = Self.skinWarm()
        let ok_withRange = fx.applyColorEdit(from: before, to: withRange, atLocal: nil); #expect(ok_withRange)
        #expect(fx.colorData.hslSecondary == Self.skinWarm())
        var stale = base; stale.basic.temperature = 12
        let ok_stale = fx.applyColorEdit(from: base, to: stale, atLocal: nil); #expect(ok_stale)
        #expect(fx.colorData.hslSecondary == Self.skinWarm())
        // Reset (nil) removes it.
        let shown = fx.colorEffect(atLocal: nil, id: 1)
        var reset = shown; reset.reset(.hslSecondary, isPrimary: true)
        let ok_reset = fx.applyColorEdit(from: shown, to: reset, atLocal: nil); #expect(ok_reset)
        #expect(fx.colorData.hslSecondary == nil)
    }

    @Test func clipColorSettersKeepTheRange() {
        var c = ColorGradeLinkTests.clip("A")
        var col = c.color
        col.effects[0].hslSecondary = Self.skinWarm()
        c.color = col
        #expect(c.color.effects[0].hslSecondary == Self.skinWarm())
        col.resetSection(.hslSecondary, in: col.effects[0].id)
        c.color = col
        #expect(c.color.effects[0].hslSecondary == nil)
    }

    // MARK: File version

    @Test func aRangeWritesV48AndRoundTrips() throws {
        var c = ColorGradeLinkTests.clip("A")
        var col = c.color
        col.effects[0].hslSecondary = Self.skinWarm()
        c.color = col
        let p = ColorGradeLinkTests.project([c])
        #expect(p.containsColorRangeQualifiers)
        #expect(try ColorGradeLinkTests.writtenVersion(p) == 48)
        #expect(ProjectFile.currentVersion >= 48)
        let back = try ProjectFile.decode(ProjectFile.encode(p), migrations: ProjectFile.migrations)
        #expect(ColorGradeLinkTests.find(back, c.id).color.effects[0].hslSecondary == Self.skinWarm())
        #expect(back == p)
    }

    @Test func withoutARangeTheLowerVersionStays() throws {
        let p = ColorGradeLinkTests.project([ColorGradeLinkTests.clip("A")])
        #expect(!p.containsColorRangeQualifiers)
        #expect(try ColorGradeLinkTests.writtenVersion(p) < 48)
    }

    @Test func aV47FileMigratesUnchanged() throws {
        let hasStep = ProjectFile.realMigrations.keys.contains(47)
        #expect(hasStep)
        let p = ColorGradeLinkTests.project([ColorGradeLinkTests.clip("A")])
        var obj = try #require(try JSONSerialization.jsonObject(with: ProjectFile.encode(p)) as? [String: Any])
        obj["formatVersion"] = 47
        let data = try JSONSerialization.data(withJSONObject: obj)
        let back = try ProjectFile.decode(data, migrations: ProjectFile.migrations)
        #expect(back == p)
    }
}
