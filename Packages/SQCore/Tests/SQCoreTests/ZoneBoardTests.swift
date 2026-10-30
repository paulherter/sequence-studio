import Foundation
import Testing
@testable import SQCore

/// v94: Zone Board maths, storage, gate, and the color-volume mask mode of Color Range.
@Suite struct ZoneBoardTests {
    @Test func freshBoardIsNeutralAndWritesNothing() throws {
        let b = ZoneBoard()
        #expect(b.isNeutral && b == b.clamped())
        #expect(String(decoding: try JSONEncoder().encode(b), as: UTF8.self) == "{}")
        #expect(ZoneSetting().saturationFactor == 1 && ZoneSetting().exposureStops == 0 && ZoneSetting().wheelValue.isNeutral)
    }

    @Test func puckMapsToWheelValueAndBack() {
        var s = ZoneSetting(); s.puckX = 1; s.puckY = 0.5
        #expect(s.wheelValue.hue == 0 && s.wheelValue.amount == 1)
        s.puckX = 0.5; s.puckY = 1
        #expect(abs(s.wheelValue.hue - 90) < 1e-3)
        s.puckX = 0.0; s.puckY = 0.5
        #expect(abs(s.wheelValue.hue - 180) < 1e-3)
        s.puckX = 1; s.puckY = 1                 // outside the circle: rim
        #expect(s.wheelValue.amount == 1)
        let p = ZoneSetting.puck(WheelValue(hue: 270, amount: 0.5))
        #expect(abs(p.x - 0.5) < 1e-5 && abs(p.y - 0.25) < 1e-5)
    }

    @Test func saturationAndExposureScales() {
        var s = ZoneSetting()
        s.saturation = 0; #expect(s.saturationFactor == 0)
        s.saturation = 1; #expect(s.saturationFactor == 2)
        s.exposure = 1; #expect(s.exposureStops == 1.5)
        s.exposure = 0; #expect(s.exposureStops == -1.5)
        s.exposure = 7; #expect(s.clamped().exposure == 1)
        s.exposure = .nan; #expect(s.clamped().exposure == 0.5)
    }

    @Test func sectionNeutralResetAndToggle() {
        var e = ColorEffect(id: 1)
        #expect(e.zoneBoard == nil && e.isNeutral(.zoneBoard))
        e.zoneBoard = ZoneBoard()
        #expect(e.isNeutral(.zoneBoard))
        e.zoneBoard?.shadows.exposure = 0.7
        #expect(!e.isNeutral(.zoneBoard))
        #expect(!ClipColor(effects: [e]).isIdentity(rec709Source: true))
        e.setEnabled(.zoneBoard, false)
        #expect(ClipColor(effects: [e]).isIdentity(rec709Source: true))
        e.reset(.zoneBoard, isPrimary: true)
        #expect(e.zoneBoard == nil && !e.isEnabled(.zoneBoard))
    }

    @Test func gradeDataCarriesTheBoardAndRoundTrips() throws {
        var e = ColorEffect(id: 1)
        var b = ZoneBoard(); b.highlights = ZoneSetting(puckX: 0.8, puckY: 0.6, saturation: 0.4, exposure: 0.55)
        e.zoneBoard = b
        e.setEnabled(.zoneBoard, false)
        let fx = ClipEffect.colorGrade(e)
        #expect(fx.grade?.zoneBoard == b && fx.grade?.zoneBoardOff == true)
        let back = fx.colorEffect(atLocal: nil, id: 1)
        #expect(back.zoneBoard == b && !back.isEnabled(.zoneBoard))
        let data = try JSONEncoder().encode(fx.grade)
        #expect(try JSONDecoder().decode(ColorGradeData.self, from: data).zoneBoard == b)
        let plain = String(decoding: try JSONEncoder().encode(ColorGradeData()), as: UTF8.self)
        #expect(!plain.contains("zoneBoard"))
    }

    @Test func rangeFadeMovesTheBoardToNeutral() {
        var e = ColorEffect(id: 1)
        var b = ZoneBoard(); b.global = ZoneSetting(puckX: 0.9, puckY: 0.5, saturation: 1, exposure: 1)
        e.zoneBoard = b
        let half = e.scaled(by: 0.5).zoneBoard?.global
        #expect(half == ZoneSetting(puckX: 0.7, puckY: 0.5, saturation: 0.75, exposure: 0.75))
        #expect(e.scaled(by: 0).zoneBoard?.isNeutral == true)
    }

    private func project(_ e: ColorEffect) -> Project {
        var c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)), start: .zero)
        c.effects = [ClipEffect.colorGrade(e)]
        return Project(name: "P", timelines: [Timeline(name: "S", format: SequenceFormat(width: 640, height: 360, frameDuration: Time(1, 25)),
                                                        tracks: [Track(kind: .video, clips: [c])])])
    }

    @Test func boardAndVolumeGateV94() throws {
        let plain = project(ColorEffect(id: 1))
        #expect(!plain.containsV94Content && ProjectFile.writtenVersion(for: plain) < 94 && ProjectFile.currentVersion >= 94)
        var withBoard = ColorEffect(id: 1)
        withBoard.zoneBoard = ZoneBoard()
        withBoard.zoneBoard?.midtones.saturation = 0.2
        let pb = project(withBoard)
        #expect(pb.containsV94Content && ProjectFile.writtenVersion(for: pb) == 94)
        for m in [nil, ProjectFile.migrations] {
            let back = try ProjectFile.decode(try ProjectFile.encode(pb), migrations: m)
            let g = back.timelines[0].tracks[0].clips[0].effects[0].grade
            #expect(g?.zoneBoard == withBoard.zoneBoard)
        }
        var vol = ColorEffect(id: 1)
        var h = HSLSecondary(); h.maskMode = .volume; h.volumeRadius = 40; h.exposure = 1
        vol.hslSecondary = h
        let pv = project(vol)
        #expect(pv.containsV94Content)
        let back = try ProjectFile.decode(try ProjectFile.encode(pv), migrations: nil)
        #expect(back.timelines[0].tracks[0].clips[0].effects[0].grade?.hslSecondary == h)
    }

    @Test func rangeModeWritesNoVolumeKeys() throws {
        var h = HSLSecondary(); h.saturation = 120
        let s = String(decoding: try JSONEncoder().encode(h), as: UTF8.self)
        #expect(!s.contains("maskMode") && !s.contains("volume"))
        h.maskMode = .volume; h.volumeSat = 30
        let back = try JSONDecoder().decode(HSLSecondary.self, from: JSONEncoder().encode(h))
        #expect(back == h)
        var wild = HSLSecondary(); wild.volumeRadius = 400; wild.volumeSat = -3
        #expect(wild.clamped().volumeRadius == 100 && wild.clamped().volumeSat == 0)
    }
}
