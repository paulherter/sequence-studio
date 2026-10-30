import Testing
import Foundation
import SQCore
import SQText
@testable import SQPremiereImport

@Suite struct MapperTests {
    let S = PRFixture.second

    /// Every map is also checked against the output of the mapper before the speed-up (MapperGolden): same document, same
    /// canonical JSON (UUIDs renumbered). `SQ_MAP_GOLDEN_RECORD=<file>` writes the current digests instead.
    func map(_ f: PRFixture, media: [String: MediaRef] = [:], function: String = #function) throws -> PRImportResult {
        let r = PRMapper.map(try PRReader.read(data: f.data), name: "Test", media: media)
        MapperGolden.check(r, function: function)
        return r
    }
    func clips(_ r: PRImportResult, seq: String = "Main", kind: TrackKind = .video) -> [Clip] {
        r.project.timelines.first { $0.name == seq }!.tracks.filter { $0.kind == kind }.flatMap(\.clips)
    }
    /// A probed 4K clip so the mapper knows the source frame size.
    func uhd(_ path: String) -> MediaRef {
        let v = VideoTrackInfo(width: 3840, height: 2160, codec: "hvc1", bitDepth: 10, chroma: "4:2:0",
                               nominalFrameDuration: Time(1, 30), isVariableFrameRate: false)
        return MediaRef(name: "a", path: path, fingerprint: MediaFingerprint(size: 1),
                        duration: Time(60, 1), info: MediaInfo(duration: Time(60, 1), video: v))
    }

    @Test func mutedTrackStaysMuted() throws {
        let f = PRFixture()
        f.sequence("Main", video: [], audio: [f.track([], audio: true, muted: true), f.track([], audio: true)])
        let r = try map(f)
        let audio = r.project.timelines[0].tracks.filter { $0.kind == .audio }
        #expect(audio.map(\.isMuted) == [true, false])
    }

    @Test func mutedVideoTrackBecomesHidden() throws {
        let f = PRFixture()
        f.sequence("Main", video: [f.track([], muted: true), f.track([])])
        let r = try map(f)
        let video = r.project.timelines[0].tracks.filter { $0.kind == .video }
        #expect(video.map(\.isVisible) == [false, true])
        #expect(r.report.status(of: "Video track output off") == .mapped)
    }

    @Test func sequenceMarkersImport() throws {
        let f = PRFixture()
        let json = { (t: Int64, d: Int64, name: String, color: Int) in
            "{&quot;DVAMarker&quot;:{&quot;mMarkerID&quot;:&quot;x&quot;,&quot;mStartTime&quot;:{&quot;ticks&quot;:\(t)},&quot;mDuration&quot;:{&quot;ticks&quot;:\(d)},&quot;mName&quot;:&quot;\(name)&quot;,&quot;mColorIndex&quot;:\(color),&quot;mType&quot;:&quot;Comment&quot;}}"
        }
        f.sequence("Main", video: [], markers: [json(2 * S, S, "Beat", 1), json(S, 0, "Intro", 0)])
        let r = try map(f)
        let m = r.project.timelines[0].markers
        #expect(m.map(\.name) == ["Intro", "Beat"])
        #expect(m[0].time == Time(1, 1) && m[0].duration == .zero && m[0].color == .green)
        #expect(m[1].time == Time(2, 1) && m[1].duration == Time(1, 1) && m[1].color == .red)
    }

    /// Lumetri curves blob (param 39): four blocks of 520 bytes; master with the white point pulled to x 0.9 here.
    static func curvesBlob(masterWhite: Double, redMid: Double? = nil) -> String {
        func block(_ pts: [(Double, Double)]) -> [UInt8] {
            var b = [UInt8](repeating: 0, count: 520)
            b[4] = UInt8(pts.count)
            for (i, p) in pts.enumerated() {
                for (k, v) in [p.0, p.1].enumerated() {
                    withUnsafeBytes(of: v.bitPattern.littleEndian) { for j in 0..<8 { b[8 + 16 * i + 8 * k + j] = $0[j] } }
                }
            }
            return b
        }
        let diag = [(0.0, 0.0), (1.0, 1.0)]
        let red = redMid.map { [(0.0, 0.0), (0.5, $0), (1.0, 1.0)] } ?? diag
        return Data(block([(0, 0), (masterWhite, 1)]) + block(red) + block(diag) + block(diag)).base64EncodedString()
    }

    @Test func lumetriCurvesAndVignetteImport() throws {
        let f = PRFixture()
        let lum = f.component("AE.ADBE Lumetri", [f.param(3, "true"), f.param(28, "12."), f.param(31, "130."),
                                                  f.param(37, "true"), f.blobParam(39, base64: Self.curvesBlob(masterWhite: 0.9, redMid: 0.6)),
                                                  f.param(50, "true"), f.param(51, "-1.5"), f.param(52, "40."), f.param(53, "10."), f.param(54, "70.")])
        f.sequence("Main", video: [f.track([f.item(start: 0, end: S, inPoint: 0, outPoint: S, source: .graphic,
                                                     components: [lum], adjustment: true)])])
        let r = try map(f)
        let e = try #require(clips(r).first?.effects.first { $0.kind == ClipEffect.colorKind }).colorEffect(atLocal: nil, id: 1)
        #expect(e.curves.master == [CurvePoint(0, 0), CurvePoint(0.9, 1)])
        #expect(e.curves.red == [CurvePoint(0, 0), CurvePoint(0.5, 0.6), CurvePoint(1, 1)])
        #expect(e.curves.green == RGBCurves.diagonal)
        #expect(e.creative.fadedFilm == 12 && e.creative.saturation == 130)
        #expect(e.vignette.amount == -1.5 && e.vignette.midpoint == 40 && e.vignette.roundness == 10 && e.vignette.feather == 70)
        #expect(r.report.status(of: "Lumetri RGB curves") == .mapped)
        #expect(r.report.status(of: "Lumetri vignette") == .mapped)
    }

    @Test func disabledCurvesSectionAndNeutralBlobMapNothing() throws {
        let f = PRFixture()
        let off = f.component("AE.ADBE Lumetri", [f.param(3, "true"), f.param(37, "false"), f.blobParam(39, base64: Self.curvesBlob(masterWhite: 0.9))])
        let neutral = f.component("AE.ADBE Lumetri", [f.param(3, "true"), f.param(37, "true"), f.blobParam(39, base64: Self.curvesBlob(masterWhite: 1))])
        f.sequence("Main", video: [f.track([f.item(start: 0, end: S, inPoint: 0, outPoint: S, source: .graphic, components: [off], adjustment: true),
                                            f.item(start: S, end: 2 * S, inPoint: 0, outPoint: S, source: .graphic, components: [neutral], adjustment: true)])])
        let r = try map(f)
        for c in clips(r) {
            let e = try #require(c.effects.first { $0.kind == ClipEffect.colorKind }).colorEffect(atLocal: nil, id: 1)
            #expect(e.curves.isNeutral)
        }
        #expect(r.report.status(of: "Lumetri RGB curves") == nil)
    }

    /// Lumetri Color Wheels blob (param 47): little-endian doubles, three per wheel (puck a, luma slider 0...1 with 0.5 =
    /// neutral, puck b). Premiere 25/26 writes four wheels (Shadows, Midtones, Highlights, HDR Specular); older presets three.
    static func wheelsBlob(_ v: [Double]) -> String {
        var d = Data()
        for x in v { withUnsafeBytes(of: x.bitPattern.littleEndian) { d.append(contentsOf: $0) } }
        return d.base64EncodedString()
    }

    func lumetriWheels(_ blob: String, on: Bool = true, function: String = #function) throws -> (ColorEffect, PRImportReport) {
        let f = PRFixture()
        let lum = f.component("AE.ADBE Lumetri", [f.param(3, "true"), f.param(46, on ? "true" : "false"), f.blobParam(47, base64: blob)])
        f.sequence("Main", video: [f.track([f.item(start: 0, end: S, inPoint: 0, outPoint: S, source: .graphic, components: [lum], adjustment: true)])])
        let r = try map(f, function: function)
        let e = try #require(clips(r).first?.effects.first { $0.kind == ClipEffect.colorKind }).colorEffect(atLocal: nil, id: 1)
        return (e, r.report)
    }

    /// The one edited wheel blob in the maintainer's projects (iPhone 18 Pro Leaks_1): only luma sliders moved. The sliders are decoded
    /// but NOT applied: scale and wheel order are inferred from this single sample and SQ's wheel maths is not Lumetri's
    /// (the design notes), so the grade stays untouched and the loss is reported.
    @Test func colourWheelLumaSlidersAreDecodedButNotApplied() throws {
        let blob = Self.wheelsBlob([0, 0.4977, 0, 0, 0.4388, 0, 0, 0.5, 0, 0, 0.5, 0])
        guard case .values(let w) = Mapping.wheels(blob) else { Issue.record("blob not decoded"); return }
        #expect(abs(w.luma(0) - -0.46) < 0.001 && abs(w.luma(1) - -12.24) < 0.001 && w.luma(2) == 0)
        #expect(w.lumaEdited && !w.pucksEdited && !w.specularEdited)
        let (e, report) = try lumetriWheels(blob)
        #expect(e.wheels.isNeutral)
        #expect(report.status(of: "Lumetri color wheels") == .dropped)
        #expect(report.entries.first { $0.feature == "Lumetri color wheels" }?.note.contains("luma sliders decoded, not applied") == true)
    }

    @Test func colourWheelsSwitchedOffOrNeutralSayNothing() throws {
        let (e, report) = try lumetriWheels(Self.wheelsBlob([0, 0.4977, 0, 0, 0.4388, 0, 0, 0.5, 0, 0, 0.5, 0]), on: false)
        #expect(e.wheels.isNeutral)
        #expect(report.status(of: "Lumetri color wheels") == nil)
        let (_, neutral) = try lumetriWheels(Self.wheelsBlob([0, 0.5, 0, 0, 0.5, 0, 0, 0.5, 0, 0, 0.5, 0]))
        #expect(neutral.status(of: "Lumetri color wheels") == nil)
    }

    /// Three-wheel blobs (older Lumetri presets, 72 bytes) decode the same way.
    @Test func threeWheelBlobDecodesLuma() throws {
        guard case .values(let w) = Mapping.wheels(Self.wheelsBlob([0, 0.5, 0, 0, 0.5, 0, 0, 0.6, 0])) else {
            Issue.record("blob not decoded"); return
        }
        #expect(abs(w.luma(2) - 20) < 0.001)
    }

    /// No sample has a moved puck, so its two values cannot be mapped yet: counted as dropped, never silent.
    @Test func editedWheelColoursAndSpecularAreReportedAsDropped() throws {
        let (e, report) = try lumetriWheels(Self.wheelsBlob([0, 0.5, 0, 0.3, 0.5, 0.1, 0, 0.5, 0, 0, 0.5, 0]))
        #expect(e.wheels.isNeutral)
        #expect(report.status(of: "Lumetri color wheels") == .dropped)
        let (_, spec) = try lumetriWheels(Self.wheelsBlob([0, 0.5, 0, 0, 0.5, 0, 0, 0.5, 0, 0, 0.7, 0]))
        #expect(spec.status(of: "Lumetri HDR specular wheel") == .dropped)
    }

    /// A wheel blob that does not read as wheel values (out of range, non-finite, unknown length) is reported, never ignored.
    @Test func unreadableWheelBlobIsReportedAsDropped() throws {
        for values in [[0, 0.5, 0, 0, 5, 0, 0, 0.5, 0, 0, 0.5, 0], [0, 0.5, 0, 0, .nan, 0, 0, 0.5, 0, 0, 0.5, 0], [0, 0.5, 0, 0, 0.5]] {
            let (e, report) = try lumetriWheels(Self.wheelsBlob(values))
            #expect(e.wheels.isNeutral)
            #expect(report.status(of: "Lumetri color wheels") == .dropped)
        }
    }

    /// Hue Saturation Curves blobs (42 Hue vs Sat, 106 Hue vs Hue, 108 Hue vs Luma, 110 Luma vs Sat, 112 Sat vs Sat): 520
    /// bytes, UInt32 axis kind (3 = hue axis, 2 = luma/sat axis; 1 in old presets), UInt32 point count, 32 (x, y) doubles.
    /// Every one of the maintainer's 809 Lumetri instances has count 0 (flat); an edited curve's y scale is unknown, so it is reported.
    static func hueCurveBlob(kind: UInt32, points: [(Double, Double)]) -> String {
        var b = [UInt8](repeating: 0, count: 520)
        withUnsafeBytes(of: kind.littleEndian) { for j in 0..<4 { b[j] = $0[j] } }
        withUnsafeBytes(of: UInt32(points.count).littleEndian) { for j in 0..<4 { b[4 + j] = $0[j] } }
        // Flat blobs still carry Premiere's stale default points (0, 0), (1, 1) after the zero count.
        let stored = points.isEmpty ? [(0.0, 0.0), (1.0, 1.0)] : points
        for (i, p) in stored.enumerated() {
            for (k, v) in [p.0, p.1].enumerated() {
                withUnsafeBytes(of: v.bitPattern.littleEndian) { for j in 0..<8 { b[8 + 16 * i + 8 * k + j] = $0[j] } }
            }
        }
        return Data(b).base64EncodedString()
    }

    @Test func flatHueCurvesSayNothingAndEditedOnesAreReported() throws {
        let f = PRFixture()
        let flat = f.component("AE.ADBE Lumetri", [f.param(3, "true"), f.blobParam(42, base64: Self.hueCurveBlob(kind: 3, points: [])),
                                                   f.blobParam(110, base64: Self.hueCurveBlob(kind: 2, points: []))])
        let edited = f.component("AE.ADBE Lumetri", [f.param(3, "true"),
                                                     f.blobParam(106, base64: Self.hueCurveBlob(kind: 3, points: [(0.1, 0.5), (0.2, 0.7), (0.3, 0.5)]))])
        f.sequence("Main", video: [f.track([f.item(start: 0, end: S, inPoint: 0, outPoint: S, source: .graphic, components: [flat], adjustment: true)]),
                                   f.track([f.item(start: 0, end: S, inPoint: 0, outPoint: S, source: .graphic, components: [edited], adjustment: true)])])
        let r = try map(f)
        #expect(r.report.count(of: "Lumetri hue saturation curves") == 1)
        #expect(r.report.status(of: "Lumetri hue saturation curves") == .dropped)
        for c in clips(r) {
            let e = try #require(c.effects.first { $0.kind == ClipEffect.colorKind }).colorEffect(atLocal: nil, id: 1)
            #expect(e.hueCurves.isNeutral)
        }
    }

    /// Clip markers (VideoClip/AudioClip `Clip/MarkerOwner`) are in media ticks, like the in point. Only the ones inside
    /// the used range are kept, as SQ source time.
    @Test func clipMarkersImportInSourceTime() throws {
        let f = PRFixture()
        let m = f.media(path: "/v/a.mov", title: "a.mov")
        let marks = [9 * S, 11 * S, 14 * S, 20 * S].map(PRFixture.plainMarker)
        f.sequence("Main", video: [f.track([f.item(start: 0, end: 4 * S, inPoint: 10 * S, outPoint: 14 * S, source: .media(m), markers: marks),
                                            f.item(start: 4 * S, end: 6 * S, inPoint: 10 * S, outPoint: 14 * S, speed: 2, source: .media(m),
                                                   markers: [PRFixture.plainMarker(12 * S)])])])
        let r = try map(f)
        let cs = clips(r)
        let a = try #require(cs.first?.markers)
        #expect(a.map(\.time) == [Time(11, 1)])
        #expect(a[0].name == "" && a[0].color == .green && a[0].duration == .zero)
        let fd = r.project.timelines[0].format.frameDuration
        #expect(cs[0].visibleMarkers(frameDuration: fd).map(\.time) == [Time(1, 1)])
        #expect(cs[1].visibleMarkers(frameDuration: fd).map(\.time) == [Time(1, 1)])
        #expect(r.report.count(of: "Clip markers") == 2)
        #expect(r.report.status(of: "Clip markers outside the used range") == .dropped)
    }

    /// Markers are snapped where they show: on the sequence frame of the clip-local time, then mapped back to source time.
    /// At 200 % the source moves two frames per sequence frame, so an odd source frame lands on the frame playing across it.
    @Test func clipMarkersSnapToTheSequenceFrameInClipTime() throws {
        let f = PRFixture()
        let m = f.media(path: "/v/a.mov", title: "a.mov")
        let frame: Int64 = 8_467_200_000
        f.sequence("Main", video: [f.track([f.item(start: 0, end: 2 * S, inPoint: 10 * S, outPoint: 14 * S, speed: 2, source: .media(m),
                                                   markers: [PRFixture.plainMarker(10 * S + 3 * frame + 1000)])])])
        let r = try map(f)
        let c = try #require(clips(r).first)
        let fd = r.project.timelines[0].format.frameDuration
        let mk = try #require(c.markers?.first)
        // Source frame 3 at 200 % = clip-local 1.5 frames -> frame 2 (ties round up) -> source frame 4.
        #expect(mk.time == Time(10, 1) + fd * 4)
        #expect(c.visibleMarkers(frameDuration: fd).map(\.time) == [fd * 2])
    }

    /// Generators (graphics, mattes, adjustment layers) start their source at 0: the marker keeps its distance to the in point.
    @Test func clipMarkersOnAdjustmentLayerAreClipLocal() throws {
        let f = PRFixture()
        f.sequence("Main", video: [f.track([f.item(start: 0, end: 2 * S, inPoint: 5 * S, outPoint: 7 * S, source: .graphic, adjustment: true,
                                                   markers: [PRFixture.plainMarker(6 * S)])])])
        let r = try map(f)
        #expect(clips(r).first?.markers?.map(\.time) == [Time(1, 1)])
    }

    @Test func offlineMediaGetsUnknownSizeAndReportsIt() throws {
        let f = PRFixture()
        let m = f.media(path: "/gone/a.mov", title: "a.mov")
        f.sequence("Main", video: [f.track([f.item(start: 0, end: S, inPoint: 0, outPoint: S, source: .media(m))])])
        let r = try map(f)
        #expect(r.project.media.first?.fingerprint.size == 0)
        #expect(r.report.count(of: "Offline media") == 1)
    }

    /// A still missing at import (no probe info) is still mapped as a still: source from 0, not Premiere's huge in point.
    @Test func offlineStillImageStaysAStill() throws {
        let f = PRFixture()
        let m = f.media(path: "/gone/sun.PNG", title: "sun.PNG")
        f.sequence("Main", video: [f.track([f.item(start: 0, end: S, inPoint: 3600 * S, outPoint: 3601 * S, source: .media(m))])])
        let c = try #require(clips(try map(f)).first)
        #expect(c.isStill && c.source.start == .zero && c.source.duration == PRTicks.time(S))
    }

    @Test func cutsTrimsAndFormat() throws {
        let f = PRFixture()
        let m = f.media(path: "/f/a.mov", title: "a.mov")
        let a = f.item(start: S, end: 3 * S, inPoint: 10 * S, outPoint: 12 * S, source: .media(m))
        let b = f.item(start: 3 * S, end: 4 * S, inPoint: 0, outPoint: S, source: .media(m))
        f.sequence("Main", video: [f.track([a, b])])
        let r = try map(f)
        let t = try #require(r.project.timelines.first)
        #expect(t.format.width == 1080 && t.format.height == 1920 && t.format.frameDuration == Time(1, 30))
        let c = clips(r)
        #expect(c.count == 2)
        #expect(c[0].start == Time(1, 1) && c[0].source == TimeRange(start: Time(10, 1), duration: Time(2, 1)))
        #expect(c[1].start == Time(3, 1) && c[1].duration == Time(1, 1))
        #expect(r.project.media.count == 1 && r.project.media[0].path == "/f/a.mov")
        #expect(c[0].media == r.project.media[0].id)
        #expect(r.project.activeTimeline == t.id)
        #expect(PRMapper.mediaPaths(try PRReader.read(data: f.data)) == ["/f/a.mov"])
    }

    @Test func usesProbedMediaRef() throws {
        let f = PRFixture()
        let m = f.media(path: "/f/a.mov", title: "a.mov")
        f.sequence("Main", video: [f.track([f.item(start: 0, end: S, inPoint: 0, outPoint: S, source: .media(m))])])
        let ref = uhd("/f/a.mov")
        let r = try map(f, media: ["/f/a.mov": ref])
        #expect(r.project.media == [ref])
        #expect(clips(r)[0].media == ref.id && clips(r)[0].mediaDuration == Time(60, 1))
    }

    @Test func speedKeepsTimelineLength() throws {
        let f = PRFixture()
        let m = f.media(path: "/f/w.wav", title: "w.wav")
        let a = f.item(start: 0, end: S, inPoint: 0, outPoint: S * 8 / 5, speed: 1.6, source: .media(m), audio: true)
        f.sequence("Main", video: [], audio: [f.track([a], audio: true)])
        let c = clips(try map(f), kind: .audio)
        #expect(c[0].speed == ClipSpeed(num: 8, den: 5))
        #expect(c[0].duration == Time(1, 1))
        #expect(c[0].source.duration == Time(8, 5))
    }

    @Test func nestedSequenceBecomesNestedClip() throws {
        let f = PRFixture()
        let inner = f.reserveUID()
        let m = f.media(path: "/f/a.mov", title: "a.mov")
        let n = f.item(start: 0, end: 2 * S, inPoint: S, outPoint: 3 * S, source: .sequence(inner), name: "Nest")
        f.sequence("Main", video: [f.track([n])])
        f.sequence("Inner", video: [f.track([f.item(start: 0, end: 5 * S, inPoint: 0, outPoint: 5 * S, source: .media(m))])], uid: inner)
        let r = try map(f)
        let innerTL = try #require(r.project.timelines.first { $0.name == "Inner" })
        let c = clips(r)[0]
        #expect(c.sequence == innerTL.id && c.media == innerTL.id)
        #expect(c.source == TimeRange(start: Time(1, 1), duration: Time(2, 1)))
        // The top-level sequence is the active one, not the nested one.
        #expect(r.project.activeTimeline == r.project.timelines.first { $0.name == "Main" }?.id)
    }

    @Test func cyclicNestedSequencesAreReported() throws {
        let f = PRFixture()
        let a = f.reserveUID(), b = f.reserveUID()
        f.sequence("A", video: [f.track([f.item(start: 0, end: S, inPoint: 0, outPoint: S, source: .sequence(b), name: "toB")])], uid: a)
        f.sequence("B", video: [f.track([f.item(start: 0, end: S, inPoint: 0, outPoint: S, source: .sequence(a), name: "toA")])], uid: b)
        let r = PRMapper.map(try PRReader.read(data: f.data), name: "Test")
        #expect(r.report.entries.contains { $0.feature == "Nested sequence" && $0.status == .dropped && $0.note == "cyclic nesting" })
        let nestedClips = r.project.timelines.flatMap(\.tracks).flatMap(\.clips).filter { $0.sequence != nil }
        #expect(nestedClips.count == 1)
        #expect(r.project.activeTimeline != nil)
    }

    @Test func motionMapsToClipAnimation() throws {
        let f = PRFixture()
        let m = f.media(path: "/f/a.mov", title: "a.mov")
        let motion = f.component("AE.ADBE Motion", [
            f.param(1, "0.5:0.25", kind: "PointComponentParam"),
            f.param(2, "55."), f.param(3, "80."), f.param(4, "true"),
            f.param(5, "12."), f.param(6, "0:0", kind: "PointComponentParam"),
        ])
        let opacity = f.component("AE.ADBE Opacity", [f.param(1, "50.")])
        f.sequence("Main", video: [f.track([f.item(start: 0, end: S, inPoint: 0, outPoint: S, source: .media(m),
                                                     components: [motion, opacity])])])
        let r = try map(f, media: ["/f/a.mov": uhd("/f/a.mov")])
        let a = clips(r)[0].animation
        #expect(a.position.value == Vec2(0, -480))
        #expect(a.scale.value == Vec2(0.55, 0.55))
        #expect(a.rotation.value == 12)
        #expect(a.anchor.value == Vec2(-1920, -1080))
        #expect(a.opacity.value == 0.5)
    }

    @Test func nonUniformScaleUsesWidthParam() throws {
        let f = PRFixture()
        let m = f.media(path: "/f/a.mov", title: "a.mov")
        let motion = f.component("AE.ADBE Motion", [f.param(2, "50."), f.param(3, "80."), f.param(4, "false")])
        f.sequence("Main", video: [f.track([f.item(start: 0, end: S, inPoint: 0, outPoint: S, source: .media(m), components: [motion])])])
        #expect(clips(try map(f))[0].animation.scale.value == Vec2(0.8, 0.5))
    }

    @Test func pixelAspectBecomesHorizontalScale() throws {
        let f = PRFixture()
        let m = f.media(path: "/f/a.mov", title: "a.mov", par: "160,121")
        let motion = f.component("AE.ADBE Motion", [f.param(2, "50."), f.param(4, "true")])
        f.sequence("Main", video: [f.track([f.item(start: 0, end: S, inPoint: 0, outPoint: S, source: .media(m), components: [motion])])])
        let s = clips(try map(f))[0].animation.scale.value
        #expect(abs(s.x - 0.5 * 160 / 121) < 1e-9 && s.y == 0.5)
    }

    /// F7.3: a file whose own tag already carries the pixel aspect is desqueezed by the media item, not a second time by Scale.
    @Test func taggedPixelAspectIsNotAppliedTwice() throws {
        let f = PRFixture()
        let m = f.media(path: "/f/a.mov", title: "a.mov", par: "4,3")
        let motion = f.component("AE.ADBE Motion", [f.param(2, "50."), f.param(4, "true")])
        f.sequence("Main", video: [f.track([f.item(start: 0, end: S, inPoint: 0, outPoint: S, source: .media(m), components: [motion])])])
        var ref = uhd("/f/a.mov")
        ref.info?.video?.pixelAspect = PixelAspect(4, 3)!
        let s = clips(try map(f, media: ["/f/a.mov": ref]))[0].animation.scale.value
        #expect(abs(s.x - s.y) < 1e-9)
    }

    /// F7.3 review: a project without `OriginalPAR` says nothing about the pixels. The file's own 4:3 tag stands; no
    /// residual 0.75 squeezes the picture back.
    @Test func missingPixelAspectInTheProjectAddsNoScale() throws {
        let f = PRFixture()
        let m = f.media(path: "/f/a.mov", title: "a.mov")
        let motion = f.component("AE.ADBE Motion", [f.param(2, "50."), f.param(4, "true")])
        f.sequence("Main", video: [f.track([f.item(start: 0, end: S, inPoint: 0, outPoint: S, source: .media(m), components: [motion])])])
        var ref = uhd("/f/a.mov")
        ref.info?.video?.pixelAspect = PixelAspect(4, 3)!
        let s = clips(try map(f, media: ["/f/a.mov": ref]))[0].animation.scale.value
        #expect(abs(s.x - s.y) < 1e-9 && s.y == 0.5)
    }

    @Test func displayReferred709GetsGammaCurve() throws {
        let f = PRFixture()
        let dr = f.media(path: "/f/a.mov", title: "a.mov", colorProfile: "BT.709,8-bit,Display-Referred")
        let rgb = f.media(path: "/f/b.png", title: "b.png", colorProfile: "BT.709 RGB Full")
        f.sequence("Main", video: [f.track([
            f.item(start: 0, end: S, inPoint: 0, outPoint: S, source: .media(dr)),
            f.item(start: S, end: 2 * S, inPoint: 0, outPoint: S, source: .media(rgb)),
        ])])
        let c = clips(try map(f))
        let fx = try #require(c[0].effects.first { $0.isColor })
        let curve = fx.colorEffect(atLocal: nil, id: 1).curves.master
        #expect(curve == Mapping.lookSpaceCurve)
        #expect(!c[1].effects.contains { $0.isColor })
    }

    @Test func keyframesAreClipLocalAfterInPointAndSpeed() throws {
        let f = PRFixture()
        let m = f.media(path: "/f/a.mov", title: "a.mov")
        // Keys sit at absolute source time: In = 10 s, keys at 10.5 s and 11 s, speed 2 -> local 0.25 s and 0.5 s.
        let keys = "\(10 * S + S / 2),90.,0,0,0,0.1667,0,0.1667;\(11 * S),100.,4,0,0,0.1667,0,0.1667"
        let motion = f.component("AE.ADBE Motion", [f.param(2, "100.", keys: keys), f.param(4, "true")])
        f.sequence("Main", video: [f.track([f.item(start: 0, end: S, inPoint: 10 * S, outPoint: 12 * S, speed: 2,
                                                     source: .media(m), components: [motion])])])
        let k = clips(try map(f))[0].animation.scale.track.keys
        #expect(k.count == 2)
        #expect(k[0].time == Time(1, 4) && k[0].value == Vec2(0.9, 0.9) && k[0].interpolation == .linear)
        #expect(k[1].time == Time(1, 2) && k[1].value == Vec2(1, 1) && k[1].interpolation == .hold)
    }

    @Test func bezierKeysGetEaseHandles() throws {
        let f = PRFixture()
        let m = f.media(path: "/f/a.mov", title: "a.mov")
        // 0 -> 100 over 1 s, both sides flat (slope 0) with 1/3 influence: an ease in/out.
        let keys = "0,0.,5,0,0,0.33333,0,0.33333;\(S),100.,5,0,0,0.33333,0,0.33333"
        let opacity = f.component("AE.ADBE Opacity", [f.param(1, "100.", keys: keys)])
        f.sequence("Main", video: [f.track([f.item(start: 0, end: 2 * S, inPoint: 0, outPoint: 2 * S, source: .media(m), components: [opacity])])])
        let k = clips(try map(f))[0].animation.opacity.track.keys
        #expect(k[0].interpolation == .bezier)
        #expect(abs(k[0].outHandle.dx - 0.33333) < 1e-6 && k[0].outHandle.dy == 0)
        #expect(abs(k[1].inHandle.dx - 0.33333) < 1e-6 && k[1].inHandle.dy == 0)
    }

    @Test func linearKeyAfterBezierKeepsItsInHandle() throws {
        let f = PRFixture()
        let m = f.media(path: "/f/a.mov", title: "a.mov")
        // Bezier key -> linear key: the segment is a curve and the linear key's stored in-slope (100/s = straight, 1/6) shapes it.
        let keys = "0,0.,5,0,0,0.33333,0,1;\(S),100.,0,0,100,0.16667,0,0.16667"
        let opacity = f.component("AE.ADBE Opacity", [f.param(1, "100.", keys: keys)])
        f.sequence("Main", video: [f.track([f.item(start: 0, end: 2 * S, inPoint: 0, outPoint: 2 * S, source: .media(m), components: [opacity])])])
        let k = clips(try map(f))[0].animation.opacity.track.keys
        #expect(k[0].interpolation == .bezier && k[0].outHandle.dx == 1 && k[0].outHandle.dy == 0)
        #expect(abs(k[1].inHandle.dx - 0.16667) < 1e-6 && abs(k[1].inHandle.dy - 0.16667) < 1e-6)
    }

    @Test func effectsMapToClipEffects() throws {
        let f = PRFixture()
        let m = f.media(path: "/f/a.mov", title: "a.mov")
        let blur = f.component("AE.ADBE Gaussian Blur 2", [f.param(1, "40.")])
        let shadow = f.component("AE.ADBE Drop Shadow", [f.param(1, "18374686479671623680", kind: "VideoComponentParam"),
                                                          f.param(2, "127.5"), f.param(3, "135."), f.param(4, "10."), f.param(5, "177.")])
        let lumetri = f.component("AE.ADBE Lumetri", [f.param(3, "true"), f.param(7, "-3."), f.param(8, "1."), f.param(13, "-6.88"),
                                                      f.param(20, "50."), f.param(23, "true"), f.param(26, "80."), f.param(130, "28"),
                                                      f.blobParam(24, base64: Data("/L/Look.cube\0".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }).base64EncodedString())])
        let geo = f.component("AE.ADBE Geometry2", [f.param(1, "0.5:0.5", kind: "PointComponentParam"),
                                                    f.param(2, "0.75:0.5", kind: "PointComponentParam"), f.param(11, "true"),
                                                    f.param(3, "120."), f.param(8, "80.")])
        let crop = f.component("AE.ADBE Motion", [f.param(8, "10."), f.param(11, "5.")])
        let mirror = f.component("AE.ADBE Wave Warp", [])
        f.sequence("Main", video: [f.track([f.item(start: 0, end: S, inPoint: 0, outPoint: S, source: .media(m),
                                                     components: [crop, blur, shadow, lumetri, geo, mirror])])])
        let r = try map(f, media: ["/f/a.mov": uhd("/f/a.mov")])
        let fx = clips(r)[0].effects
        let kinds = fx.map(\.kind)
        #expect(kinds.contains(ClipEffect.cropKind))
        #expect(fx.first { $0.kind == ClipEffect.cropKind }?.parameters[ClipEffect.cropLeftKey]?.value == 10)
        #expect(fx.first { $0.kind == ClipEffect.cropKind }?.parameters[ClipEffect.cropBottomKey]?.value == 5)
        // Premiere Blurriness 40 -> SQ Blurriness 40 (the effect itself maps it to sigma).
        #expect(fx.first { $0.kind == ClipEffect.gaussianBlurKind }?.parameters[ClipEffect.blurrinessKey]?.value == 40)
        let ds = try #require(fx.first { $0.kind == ClipEffect.dropShadowKind })
        #expect(ds.parameters[ClipEffect.shadowOpacityKey]?.value == 50)
        #expect(ds.parameters[ClipEffect.shadowSoftnessKey]?.value == 177)
        #expect(ds.colors[ClipEffect.shadowColorKey]?.value == EffectColor(red: 0, green: 0, blue: 0))
        let grade = try #require(fx.first { $0.kind == ClipEffect.colorKind })
        let basic = grade.colorEffect(atLocal: nil, id: 1).basic
        #expect(basic.temperature == -3 && basic.tint == 1 && abs(basic.highlights + 6.88) < 1e-4 && basic.saturation == 50)
        // Creative look: the .cube path (UTF-16LE, NUL-terminated) and its intensity.
        let creative = grade.colorEffect(atLocal: nil, id: 1).creative
        #expect(creative.look == .file("/L/Look.cube") && creative.intensity == 80)
        // Look color space 28: the LUT output is re-encoded (power 2.4 / 1.961) as a master curve.
        let master = grade.colorEffect(atLocal: nil, id: 1).curves.master
        #expect(master.first == CurvePoint(0, 0) && master.last == CurvePoint(1, 1))
        let mid = try #require(master.first { $0.x == 0.55 })
        #expect(abs(mid.y - pow(0.55, 2.4 / 1.961)) < 1e-5)
        #expect(clips(r)[0].footageColor == ClipFootageColor(source: .rec709, useEmbeddedLUT: false))
        let stage = try #require(fx.first { $0.kind == ClipEffect.transformKind })
        #expect(stage.parameters[ClipEffect.stagePositionXKey]?.value == 960)    // 0.75 * 3840 - 1920
        #expect(stage.parameters[ClipEffect.stageAnchorXKey]?.value == 0)
        #expect(stage.parameters[ClipEffect.stageScaleKey]?.value == 120)
        #expect(stage.parameters[ClipEffect.stageOpacityKey]?.value == 80)
        #expect(r.report.status(of: "AE.ADBE Wave Warp") == .dropped)
        #expect(r.report.status(of: "AE.ADBE Gaussian Blur 2") == .mapped)
    }

    @Test func gaussianBlurRepeatEdgePixelsMapsToTheCheckbox() throws {
        let f = PRFixture()
        let m = f.media(path: "/f/a.mov", title: "a.mov")
        let on = f.component("AE.ADBE Gaussian Blur 2", [f.param(1, "40."), f.param(2, "0"), f.param(3, "true")])
        let off = f.component("AE.ADBE Gaussian Blur 2", [f.param(1, "40."), f.param(2, "0"), f.param(3, "false")])
        f.sequence("Main", video: [f.track([f.item(start: 0, end: S, inPoint: 0, outPoint: S, source: .media(m), components: [on]),
                                            f.item(start: S, end: 2 * S, inPoint: 0, outPoint: S, source: .media(m), components: [off])])])
        let r = try map(f, media: ["/f/a.mov": uhd("/f/a.mov")])
        let blurs = clips(r).map { $0.effects.first { $0.kind == ClipEffect.gaussianBlurKind } }
        #expect(blurs.count == 2)
        #expect(blurs[0]?.flag(ClipEffect.repeatEdgePixelsKey, atLocal: .zero) == true)
        #expect(blurs[1]?.flag(ClipEffect.repeatEdgePixelsKey, atLocal: .zero) == false)
    }

    @Test func adjustmentLayerBecomesAdjustmentClip() throws {
        let f = PRFixture()
        let geo = f.component("AE.ADBE Geometry2", [f.param(2, "0.5:0.5", keys: "0,0.5:0.5,0,0,0,0,0,0;254016000000,0.25:0.5,0,0,0,0,0,0", kind: "PointComponentParam")])
        let mirror = f.component("AE.ADBE Mirror", [f.param(1, "0.75:0.5", kind: "PointComponentParam"), f.param(2, "90.")])
        let lum = f.component("AE.ADBE Lumetri", [f.param(11, "1.5")])
        let text = f.component("AE.ADBE Text", [])
        let adj = f.item(start: S, end: 2 * S, inPoint: 0, outPoint: S, source: .graphic,
                         components: [text, geo, mirror, lum], adjustment: true)
        f.sequence("Main", video: [f.track([adj])])
        let r = try map(f)
        let c = try #require(clips(r).first)
        #expect(c.isAdjustment && c.start == Time(1, 1) && c.duration == Time(1, 1))
        #expect(c.effects.map(\.kind) == [ClipEffect.transformKind, ClipEffect.mirrorKind, ClipEffect.colorKind])
        let m = c.effects[1]
        #expect(m.points[ClipEffect.mirrorCenterKey]?.value == Vec2(0.25 * 1080, 0))
        #expect(m.parameters[ClipEffect.mirrorAngleKey]?.value == 90)
        #expect(c.effects[0].parameters[ClipEffect.stagePositionXKey]?.isAnimated == true)
        #expect(c.effects[2].colorEffect(atLocal: nil, id: 1).basic.exposure == 1.5)
        #expect(r.report.status(of: "Adjustment layer") == .mapped)
    }

    /// AE.ADBE Shape path blob (param 1) as in the maintainer's files: UInt32 2, UInt32 point count, per point a Float32 0 and three
    /// (x, y) Float32 pairs (vertex and its two tangents, px), then one byte 1 (closed).
    static func shapePathBlob(width: Float, height: Float) -> String {
        var d = Data()
        func put<T>(_ v: T) { withUnsafeBytes(of: v) { d.append(contentsOf: $0) } }
        put(UInt32(2).littleEndian); put(UInt32(4).littleEndian)
        for (x, y) in [(Float(0), Float(0)), (width, 0), (width, height), (0, height)] {
            put(Float(0).bitPattern.littleEndian)
            for _ in 0..<3 { put(x.bitPattern.littleEndian); put(y.bitPattern.littleEndian) }
        }
        d.append(1)
        return d.base64EncodedString()
    }

    /// The Mister Horse carrier Shape of a 1080 x 1920 sequence: a 1920 x 1080 rectangle at 177.78 %, anchored on its center.
    func carrierShape(_ f: PRFixture, width: Float = 1920, height: Float = 1080, scale: String = "177.777770996094") -> String {
        f.component("AE.ADBE Shape", [f.blobParam(1, base64: Self.shapePathBlob(width: width, height: height)),
                                      f.param(4, "0.5:0.5", kind: "PointComponentParam"), f.param(5, scale), f.param(6, scale),
                                      f.param(7, "true"), f.param(8, "0."),
                                      f.param(10, "0.8888888955116272:0.28125", kind: "PointComponentParam")])
    }

    /// All 140 adjustment-flagged graphics in the maintainer's projects are Mister Horse carriers: two Text layers ("Mister Horse
    /// Adjustment" and a help note) and a Shape covering the frame. Premiere draws none of it and the effects reach the whole
    /// frame, as SQ's adjustment layer does: nothing is lost, nothing is reported.
    @Test func adjustmentLayerWithAFrameSizedCarrierIsNotALoss() throws {
        let f = PRFixture()
        let comps = [f.component("AE.ADBE Text", []), carrierShape(f)]
        f.sequence("Main", video: [f.track([
            f.item(start: 0, end: S, inPoint: 0, outPoint: S, source: .graphic, components: comps, adjustment: true),
        ])])
        let r = try map(f)
        #expect(r.report.status(of: "Adjustment layer area") == nil)
        #expect(r.report.status(of: "Adjustment layer") == .mapped)
        #expect(r.report.count(of: "AE.ADBE Shape") == 0)
    }

    /// Without a frame-covering layer Premiere limits the effects to the shape / text; SQ's adjustment layer covers the
    /// frame, so that difference is reported (text only, a small shape, a shape with an unreadable path).
    @Test func adjustmentLayerWithoutAFrameSizedCarrierIsReported() throws {
        for kind in 0..<3 {
            let f = PRFixture()
            let comps = [[f.component("AE.ADBE Text", [])], [carrierShape(f, width: 400, height: 300, scale: "100.")],
                         [f.component("AE.ADBE Shape", [])]][kind]
            f.sequence("Main", video: [f.track([
                f.item(start: 0, end: S, inPoint: 0, outPoint: S, source: .graphic, components: comps, adjustment: true),
            ])])
            let r = try map(f)
            #expect(r.report.status(of: "Adjustment layer area") == .approximated)
            #expect(r.report.entries.first { $0.feature == "Adjustment layer area" }?.note.contains("effect area not limited to the shape/text") == true)
        }
    }

    @Test func slidePresetDropsMirrorAndMapsDirectionalBlur() throws {
        let f = PRFixture()
        let geo = f.component("AE.ADBE Geometry2", [f.param(3, "200."), f.param(11, "true")])
        let mirror = f.component("AE.ADBE Mirror", [f.param(1, "0.75:0.5", kind: "PointComponentParam")])
        let blur = f.component("AE.ADBE Motion Blur", [f.param(1, "90."), f.param(2, "30.")])
        f.sequence("Main", video: [f.track([f.item(start: 0, end: S, inPoint: 0, outPoint: S, source: .graphic,
                                                     components: [geo, mirror, blur], adjustment: true)])])
        let r = try map(f)
        let fx = try #require(clips(r).first).effects
        #expect(fx.map(\.kind) == [ClipEffect.transformKind, ClipEffect.directionalBlurKind])
        #expect(fx[1].parameters[ClipEffect.blurDirectionKey]?.value == 90 && fx[1].parameters[ClipEffect.blurLengthKey]?.value == 30)
        #expect(r.report.status(of: "AE.ADBE Mirror") == .dropped)
    }

    @Test func colourMatteBecomesSolidClip() throws {
        let f = PRFixture()
        let op = f.component("AE.ADBE Opacity", [f.param(0, "50.")])
        f.sequence("Main", video: [f.track([f.item(start: 0, end: S, inPoint: 0, outPoint: S, source: .matte(prefsHex: "3382d40001000000"), components: [op], name: "Farbfl\u{E4}che")])])
        let r = try map(f)
        let c = try #require(clips(r).first)
        #expect(c.generator?.kind == GeneratorRef.solid)
        #expect([UInt8](c.generator?.payload ?? Data()) == [0x33, 0x82, 0xd4])
        #expect(r.report.status(of: "Color matte") == .mapped)
    }

    /// A graphic with two text layers and a clip-level Drop Shadow (TCL C8L): Premiere draws the effect on the graphic as a
    /// whole, so the shadow lies under both texts. Split into two clips, the upper text's shadow darkened the lower text.
    /// It becomes one Graphics clip: the clip effects act on both layers together, each layer sits where its own clip did.
    @Test func multiTextGraphicBecomesOneGraphicsClipWithSharedEffects() throws {
        func graphic(_ f: PRFixture, texts: [(String, String)]) -> PRFixture {
            let comps = texts.map { s, pos in
                f.component("AE.ADBE Text", [f.blobParam(1, base64: FlatBlob.premiereText(s, font: "Inter-Bold", size: 60, tracking: 0).base64EncodedString()),
                                             f.param(3, pos, kind: "PointComponentParam"), f.param(4, "150.")])
            }
            let motion = f.component("AE.ADBE Motion", [f.param(1, "0.55:0.45", kind: "PointComponentParam"), f.param(2, "80."),
                                                        f.param(4, "true"), f.param(5, "10."), f.param(6, "0.5:0.5", kind: "PointComponentParam")])
            let geo = f.component("AE.ADBE Geometry2", [f.param(1, "0.4:0.6", kind: "PointComponentParam"),
                                                        f.param(2, "0.45:0.65", kind: "PointComponentParam"), f.param(3, "120."), f.param(7, "-15.")])
            let shadow = f.component("AE.ADBE Drop Shadow", [f.param(1, "18374686479671623680", kind: "VideoComponentParam"),
                                                              f.param(2, "255."), f.param(3, "135."), f.param(4, "0."), f.param(5, "177.")])
            f.sequence("Main", video: [f.track([f.item(start: 0, end: S, inPoint: 3600 * S, outPoint: 3601 * S, source: .graphic,
                                                         components: [motion, geo, shadow] + comps, name: "Graphic")])])
            return f
        }
        let r = try map(graphic(PRFixture(), texts: [("one", "0.3:0.4"), ("two", "0.6:0.7")]))
        let tl = try #require(r.project.timelines.first { $0.name == "Main" })
        #expect(tl.tracks.count == 1)
        let g = try #require(tl.tracks[0].clips.first)
        #expect(tl.tracks[0].clips.count == 1 && g.isGraphics)
        let doc = try #require(g.graphics)
        #expect(doc.layers.count == 2 && doc.layers.allSatisfy(\.isText) && doc.layers.allSatisfy { $0.effects.isEmpty })
        // One Drop Shadow, on the graphic as a whole (under both texts).
        #expect(g.effects.map(\.kind) == [ClipEffect.transformKind, ClipEffect.dropShadowKind])
        #expect(r.report.status(of: "Second text layer in a graphic") == .mapped)

        // Each layer lands where the single-layer import puts the same text: graphic(layer(p)) == clip(p).
        func apply(_ t: ClipTransform, _ p: Vec2) -> Vec2 {
            let a = t.rotation * .pi / 180, q = Vec2((p.x - t.anchor.x) * t.scale.x, (p.y - t.anchor.y) * t.scale.y)
            return Vec2(t.position.x + q.x * cos(a) - q.y * sin(a), t.position.y + q.x * sin(a) + q.y * cos(a))
        }
        let frame = Vec2(1080, 1920), at = Time(1, 2)
        let gt = g.renderTransform(at: at, frame: frame)
        for (i, text) in [("one", "0.3:0.4"), ("two", "0.6:0.7")].enumerated() {
            let single = try #require(clips(try map(graphic(PRFixture(), texts: [text]))).first)
            #expect(single.generator?.kind != GeneratorRef.graphics)
            let st = single.renderTransform(at: at, frame: frame)
            let li = doc.layers.count - 1 - i   // Premiere lists the top layer first, the document bottom first
            guard case .text(let ref) = doc.layers[li].content else { Issue.record("not text"); continue }
            #expect(ref == single.generator)
            var layer = g
            layer.animation = doc.layers[li].animation; layer.effects = doc.layers[li].effects
            let lt = layer.renderTransform(at: at, frame: frame)
            for p in [Vec2(0, 0), Vec2(100, -40), Vec2(-250, 80)] {
                let a = apply(gt, apply(lt, p)), b = apply(st, p)
                #expect(abs(a.x - b.x) < 1e-6 && abs(a.y - b.y) < 1e-6, "layer \(i) point \(p): \(a) vs \(b)")
            }
        }
    }

    @Test func textGraphicBecomesTextClip() throws {
        let f = PRFixture()
        let blob = FlatBlob.premiereText("hier sind", font: "Inter-Bold", size: 73.144, tracking: -44).base64EncodedString()
        let text = f.component("AE.ADBE Text", [f.blobParam(1, base64: blob), f.param(3, "0.5:0.5", kind: "PointComponentParam")])
        // Caption pop: Geometry2 anchor = position = 0.5:0.7, scale 90 -> 100 over 0.1 s (graphics keep source time at 3600 s).
        let k0 = 3600 * S, k1 = 3600 * S + S / 10
        let geo = f.component("AE.ADBE Geometry2", [f.param(1, "0.5:0.7", kind: "PointComponentParam"),
                                                    f.param(2, "0.5:0.7", kind: "PointComponentParam"), f.param(11, "true"),
                                                    f.param(3, "100.", keys: "\(k0),90.,0,0,0,0.1667,0,0.1667;\(k1),100.,0,0,0,0.1667,0,0.1667")])
        let g = f.item(start: 2 * S, end: 3 * S, inPoint: 3600 * S, outPoint: 3601 * S, source: .graphic, components: [geo, text], name: "Graphic")
        f.sequence("Main", video: [f.track([g])])
        let r = try map(f)
        let c = try #require(clips(r).first)
        #expect(c.start == Time(2, 1) && c.duration == Time(1, 1))
        let gen = try #require(c.generator)
        let (template, _) = try TextGenerator.decode(gen)
        #expect(template.text == "hier sind")
        #expect(template.style.fontName == "Inter-Bold")
        // Measured against Premiere's render: its glyphs are 2 % larger and its tracking 60 % of the decoded value.
        let size = 73.144 * Mapping.textSizeScale
        #expect(Mapping.textSizeScale == 1.02 && Mapping.textTrackingScale == 0.6)
        #expect(abs(template.style.size - size) < 0.001)
        #expect(abs(template.style.tracking - (-44.0 / 1000 * size * 0.6)) < 1e-3)
        #expect(template.style.alignment == .center)
        // Text centered at the Geometry2 point (0.7 * 1920 - 960 = 384 below center): Motion's anchor moves the raster there,
        // so Motion scale/rotation still pivot where Premiere's do (plus the measured glyph-center calibration).
        #expect(c.animation.position.value == .zero)
        #expect(abs(c.animation.anchor.value.y + 384 + textCentreOffsetY) < 1e-6 && c.animation.anchor.value.x == 0)
        let stage = try #require(c.effects.first { $0.kind == ClipEffect.transformKind })
        #expect(stage.parameters[ClipEffect.stagePositionYKey]?.value == 0)
        let keys = try #require(stage.parameters[ClipEffect.stageScaleKey]?.track.keys)
        #expect(keys.map(\.time) == [.zero, Time(1, 10)] && keys.map(\.value) == [90, 100])
    }

    @Test func twoLineTextWithASecondStyleKeepsBothLines() throws {
        let f = PRFixture()
        let blob = FlatBlob.premiereRuns([("Bis zu\r", 0, 136), ("3.200", 1, 195)], fonts: ["BasicSans-Regular", "BasicSans-Bold"])
        let text = f.component("AE.ADBE Text", [f.blobParam(1, base64: blob.base64EncodedString())])
        f.sequence("Main", video: [f.track([f.item(start: 0, end: S, inPoint: 3600 * S, outPoint: 3601 * S, source: .graphic,
                                                   components: [text], name: "Graphic")])])
        let r = try map(f)
        let (template, _) = try TextGenerator.decode(try #require(clips(r).first?.generator))
        #expect(template.text == "Bis zu\n3.200")
        #expect(template.style.fontName == "BasicSans-Regular" && template.style.weight == .regular)
        #expect(abs(template.style.size - 136 * Mapping.textSizeScale) < 1e-3)
        let second = try #require(template.style.secondLine)
        #expect(second.fontName == "BasicSans-Bold" && second.weight == .bold)
        #expect(abs(second.size - 195 * Mapping.textSizeScale) < 1e-3)
    }

    @Test func textBackgroundOffKeepsWhiteFill() throws {
        let f = PRFixture()
        let blob = FlatBlob.premiereText("Aa", font: "Inter-Bold", size: 80, tracking: 0,
                                         background: ((75, 203, 214), false, 100, 9, 0)).base64EncodedString()
        let text = f.component("AE.ADBE Text", [f.blobParam(1, base64: blob)])
        f.sequence("Main", video: [f.track([f.item(start: 0, end: S, inPoint: 3600 * S, outPoint: 3601 * S, source: .graphic,
                                                   components: [text], name: "Graphic")])])
        let c = try #require(clips(try map(f)).first)
        let (template, _) = try TextGenerator.decode(try #require(c.generator))
        #expect(template.style.color == .white)
        #expect(template.style.background == nil)
    }

    @Test func textBackgroundOnCarriesOver() throws {
        let f = PRFixture()
        let blob = FlatBlob.premiereText("Aa", font: "Inter-Bold", size: 80, tracking: 0,
                                         background: ((0xEE, 0x4A, 0x4A), true, 50, 10, 4)).base64EncodedString()
        let text = f.component("AE.ADBE Text", [f.blobParam(1, base64: blob)])
        f.sequence("Main", video: [f.track([f.item(start: 0, end: S, inPoint: 3600 * S, outPoint: 3601 * S, source: .graphic,
                                                   components: [text], name: "Graphic")])])
        let c = try #require(clips(try map(f)).first)
        let (template, _) = try TextGenerator.decode(try #require(c.generator))
        #expect(template.style.color == .white)
        let bg = try #require(template.style.background)
        #expect(bg.color == RGBAColor(red: 0xEE / 255.0, green: 0x4A / 255.0, blue: 0x4A / 255.0, alpha: 0.5))
        #expect(bg.padding == BoxPadding(horizontal: 10, vertical: 10) && bg.cornerRadius == 4)
    }

    @Test func textShadowCarriesOver() throws {
        let f = PRFixture()
        let blob = FlatBlob.premiereText("auf Audio", font: "Inter-Bold", size: 90, tracking: 0,
                                         shadow: ((0, 0, 0), true, 90.781, 17.764, 19.255, 20.461, 178.612)).base64EncodedString()
        let text = f.component("AE.ADBE Text", [f.blobParam(1, base64: blob)])
        f.sequence("Main", video: [f.track([f.item(start: 0, end: S, inPoint: 3600 * S, outPoint: 3601 * S, source: .graphic,
                                                   components: [text], name: "Graphic")])])
        let c = try #require(clips(try map(f)).first)
        let (template, _) = try TextGenerator.decode(try #require(c.generator))
        let s = try #require(template.style.shadow)
        #expect(s.color.red == 0 && abs(s.opacity - 0.90781) < 1e-4)
        #expect(s.distance == 0 && s.offsetX == 0 && s.offsetY == 0)  // fields 20/34 are style constants, not angle / distance
        // Size becomes the spread, Blur is scaled (Mapping.shadowBlurScale / shadowSizeScale): thin text keeps a dense shadow.
        #expect(abs(s.spread - 20.461 * Mapping.shadowSizeScale) < 0.01)
        #expect(abs(s.blur - 178.612 * Mapping.shadowBlurScale) < 0.01)
        #expect(s.spread > 5 && s.blur > 40)
    }

    /// The maintainer's Homeview graphic: Premiere panel opacity 90, angle 0, distance 0, size 25.3, blur 151 (raw fields 15 = 25.3, 16 = 151).
    @Test func textShadowSizeAndBlurLandInTheirOwnFields() throws {
        let f = PRFixture()
        let blob = FlatBlob.premiereText("Bottom", font: "Inter-Bold", size: 90, tracking: -30,
                                         shadow: ((0, 0, 0), true, 90, 0, 0, 25.3, 151)).base64EncodedString()
        let text = f.component("AE.ADBE Text", [f.blobParam(1, base64: blob)])
        f.sequence("Main", video: [f.track([f.item(start: 0, end: S, inPoint: 3600 * S, outPoint: 3601 * S, source: .graphic,
                                                   components: [text], name: "Graphic")])])
        let c = try #require(clips(try map(f)).first)
        let (template, _) = try TextGenerator.decode(try #require(c.generator))
        let s = try #require(template.style.shadow)
        #expect(s.angle == 0 && s.distance == 0)
        #expect(abs(s.spread - 25.3 * Mapping.shadowSizeScale) < 0.01 && abs(s.blur - 151 * Mapping.shadowBlurScale) < 0.01)
    }

    @Test func multiTextGraphicKeepsPremiereLayerOrder() throws {
        let f = PRFixture()
        let comps = ["Top", "Bottom"].map { s in
            f.component("AE.ADBE Text", [f.blobParam(1, base64: FlatBlob.premiereText(s, font: "Inter-Bold", size: 60, tracking: 0).base64EncodedString())])
        }
        f.sequence("Main", video: [f.track([f.item(start: 0, end: S, inPoint: 3600 * S, outPoint: 3601 * S, source: .graphic,
                                                   components: comps, name: "Graphic")])])
        let g = try #require(clips(try map(f)).first)
        let doc = try #require(g.graphics)
        let names = try doc.layers.map { l -> String in
            guard case .text(let ref) = l.content else { return "?" }
            return try TextGenerator.decode(ref).0.text
        }
        // Component order lists the top layer first; the document lists the bottom layer first.
        #expect(names == ["Bottom", "Top"])
    }

    @Test func pointTextIsPlacedByItsLayerPositionAndScale() throws {
        let f = PRFixture()
        let blob = FlatBlob.premiereText("5 Neue Features!", font: "Helvetica", size: 100, tracking: 0).base64EncodedString()
        // Point text (no paragraph box), left aligned: Text layer position = left edge / baseline; Graphic Group moves it.
        let text = f.component("AE.ADBE Text", [f.blobParam(1, base64: blob), f.param(3, "0.2:0.7", kind: "PointComponentParam"),
                                                f.param(4, "50.")])
        let group = f.component("AE.ADBE Graphic Group", [f.param(1, "0.55:0.5", kind: "PointComponentParam"),
                                                          f.param(6, "0.5:0.5", kind: "PointComponentParam")])
        let geo = f.component("AE.ADBE Geometry2", [f.param(1, "0.5:0.5", kind: "PointComponentParam"),
                                                    f.param(2, "0.5:0.5", kind: "PointComponentParam")])
        let g = f.item(start: 0, end: S, inPoint: 3600 * S, outPoint: 3601 * S, source: .graphic, components: [group, geo, text])
        f.sequence("Main", video: [f.track([g])])
        let c = try #require(clips(try map(f)).first)
        let (template, _) = try TextGenerator.decode(try #require(c.generator))
        #expect(abs(template.style.size - 50 * Mapping.textSizeScale) < 1e-9)
        let line = try #require(TextLayout.layout(text: template.text, style: template.style, maxWidth: nil).lines.first)
        let left = (0.2 + 0.05) * 1080 - 540, baseline = 0.7 * 1920 - 960
        let centre = Vec2(left + line.width / 2, baseline - line.baseline + line.height / 2)
        #expect(abs(c.animation.anchor.value.x + centre.x) < 1e-6 && abs(c.animation.anchor.value.y + centre.y) < 1e-6)
        // The Transform effect still pivots at its own anchor (canvas center): stage anchor = -(text center).
        let stage = try #require(c.effects.first { $0.kind == ClipEffect.transformKind })
        #expect(abs((stage.parameters[ClipEffect.stageAnchorXKey]?.value ?? 0) + centre.x) < 1e-6)
        // Position is P - A (an SQ stage adds it after pivoting about the anchor): a centered Transform moves nothing.
        #expect(stage.parameters[ClipEffect.stagePositionXKey]?.value == 0 && stage.parameters[ClipEffect.stagePositionYKey]?.value == 0)
    }

    @Test func audioVolumeAndLinking() throws {
        let f = PRFixture()
        let m = f.media(path: "/f/a.mov", title: "a.mov")
        // Premiere level is linear with 1.0 = +15 dB: 0.1 is -5 dB.
        let vol = f.audioComponent(displayName: "Volume", matchName: "Internal Volume Stereo",
                                   [f.param(nil, "false", kind: "AudioComponentParam", name: "Bypass"),
                                    f.param(nil, "0.1", kind: "AudioComponentParam", name: "Level")])
        let nr = f.audioComponent(displayName: "Noise Reduction", matchName: "c6762838-e451-4d22-9c90-b0eaa734605a",
                                  [f.param(nil, "false", kind: "AudioComponentParam", name: "Bypass"),
                                   f.param(nil, "0.05", kind: "AudioComponentParam", name: "Amount")])
        let v = f.item(start: 0, end: S, inPoint: 0, outPoint: S, source: .media(m))
        let a = f.item(start: 0, end: S, inPoint: 0, outPoint: S, source: .media(m), components: [vol, nr], audio: true)
        f.sequence("Main", video: [f.track([v])], audio: [f.track([a], audio: true)])
        let r = try map(f)
        let vc = clips(r)[0], ac = clips(r, kind: .audio)[0]
        #expect(vc.link != nil && vc.link == ac.link)
        #expect(abs(ac.animation.volume.value - pow(10, -5.0 / 20)) < 1e-9)
        let nrFX = try #require(ac.effects.first { $0.kind == ClipEffect.audioNoiseReductionKind })
        #expect(abs((nrFX.parameters[ClipEffect.noiseAmountReductionKey]?.value ?? -1) - 5) < 1e-9)
    }

    /// Right-click > Audio Gain lives in `AudioClip/Gain` (linear): -20 dB = 0.1. It multiplies the Volume level.
    @Test func audioGainIsImported() throws {
        let f = PRFixture()
        let m = f.media(path: "/f/a.mov", title: "a.mov")
        let a = f.item(start: 0, end: S, inPoint: 0, outPoint: S, source: .media(m), audio: true, gain: 0.1)
        let vol = f.audioComponent(displayName: "Volume", matchName: "Internal Volume Stereo",
                                   [f.param(nil, "false", kind: "AudioComponentParam", name: "Bypass"),
                                    f.param(nil, "0.1", kind: "AudioComponentParam", name: "Level")])
        let b = f.item(start: S, end: 2 * S, inPoint: 0, outPoint: S, source: .media(m), components: [vol], audio: true, gain: 0.1)
        f.sequence("Main", video: [], audio: [f.track([a, b], audio: true)])
        let cs = clips(try map(f), kind: .audio)
        // Audio Gain -> Clip.audioGainDB (SQ's Audio Gain, before the effects); the Volume level stays the volume.
        #expect(abs(cs[0].audioGainDB - (-20)) < 1e-9 && abs(cs[0].animation.volume.value - 1) < 1e-9)
        #expect(abs(cs[1].audioGainDB - (-20)) < 1e-9 && abs(cs[1].animation.volume.value - pow(10, -5.0 / 20)) < 1e-9)
    }

    @Test func crossDissolveBecomesTransition() throws {
        let f = PRFixture()
        let m = f.media(path: "/f/a.mov", title: "a.mov")
        let a = f.item(start: 0, end: 2 * S, inPoint: 0, outPoint: 2 * S, source: .media(m))
        let b = f.item(start: 2 * S, end: 4 * S, inPoint: 5 * S, outPoint: 7 * S, source: .media(m))
        let t = f.transition(start: 2 * S - S / 2, end: 2 * S + S / 2)
        f.sequence("Main", video: [f.track([a, b], transitions: [t])])
        let r = try map(f)
        let track = try #require(r.project.timelines.first?.tracks.first)
        let tr = try #require(track.transitions.first)
        #expect(tr.kind == .crossDissolve && tr.duration == Time(1, 1))
        #expect(tr.outgoing == track.clips[0].id && tr.incoming == track.clips[1].id)
    }

    /// Audio crossfades (TCL C8L): Constant Power / Gain keep their kind; other fades become Constant Power, not a video dissolve.
    @Test func audioTransitionsKeepAudioKinds() throws {
        let f = PRFixture()
        let m = f.media(path: "/f/a.wav", title: "a.wav")
        func pair(_ at: Int64) -> [String] {
            [f.item(start: at, end: at + 2 * S, inPoint: 0, outPoint: 2 * S, source: .media(m)),
             f.item(start: at + 2 * S, end: at + 4 * S, inPoint: 5 * S, outPoint: 7 * S, source: .media(m))]
        }
        let names = ["AE.ADBE Constant Power", "AE.ADBE Constant Gain", "AE.ADBE Custom Fade"]
        let tracks = names.map { name in
            f.track(pair(0), transitions: [f.transition(start: 2 * S - S / 2, end: 2 * S + S / 2, matchName: name)], audio: true)
        }
        f.sequence("Main", video: [], audio: tracks)
        let r = try map(f)
        let kinds = r.project.timelines[0].tracks.compactMap { $0.transitions.first?.kind }
        #expect(kinds == [.constantPower, .constantGain, .constantPower])
        #expect(r.report.status(of: "Transition AE.ADBE Custom Fade") == .approximated)
    }

    // MARK: Blend mode, Lumetri Sharpen, Mosaic, Tint, Flip, Noise

    private func blendClip(code: Int, index: Int?) throws -> (Clip, PRImportResult) {
        let f = PRFixture()
        let m = f.media(path: "/f/a.mov", title: "a.mov")
        var ps = [f.param(1, "100."), f.param(2, "\(code)")]
        if let index { ps.append(f.param(3, "\(index)")) }
        let opacity = f.component("AE.ADBE Opacity", ps)
        f.sequence("Main", video: [f.track([f.item(start: 0, end: S, inPoint: 0, outPoint: S, source: .media(m), components: [opacity])])])
        let r = try map(f)
        return (clips(r)[0], r)
    }

    /// Measured on the maintainer's projects: (code, menu index) pairs 18/0 Normal, 22/10 Add, 11/9 Color Dodge, 17/4 Color Burn, 12/13 Soft Light.
    @Test func blendModeIsReadFromOpacityMenuIndex() throws {
        let table: [(Int, Int, BlendMode)] = [(18, 0, .normal), (22, 10, .add), (11, 9, .colorDodge), (17, 4, .colorBurn),
                                              (12, 13, .softLight), (0, 8, .screen), (0, 3, .multiply), (0, 12, .overlay),
                                              (0, 19, .difference), (0, 20, .exclusion), (0, 2, .darken), (0, 7, .lighten)]
        for (code, idx, mode) in table {
            let (c, r) = try blendClip(code: code, index: idx)
            #expect(c.blendMode == mode)
            if mode != .normal { #expect(r.report.status(of: "Opacity blend mode") == .mapped) }
        }
    }

    @Test func blendModeFallsBackToCodeWithoutIndex() throws {
        #expect(try blendClip(code: 22, index: nil).0.blendMode == .add)
        #expect(try blendClip(code: 18, index: nil).0.blendMode == .normal)
    }

    @Test func everyMenuIndexMapsToTheFullSet() throws {
        let table: [(Int, BlendMode)] = [(1, .dissolve), (6, .darkerColor), (11, .lighterColor), (15, .vividLight),
                                         (16, .linearLight), (17, .pinLight), (18, .hardMix), (21, .subtract), (22, .divide),
                                         (23, .hue), (24, .saturation), (25, .color), (26, .luminosity)]
        for (idx, mode) in table {
            let (c, r) = try blendClip(code: 0, index: idx)
            #expect(c.blendMode == mode, "index \(idx)")
            #expect(r.report.status(of: "Opacity blend mode") == .mapped)
        }
    }

    @Test func unknownBlendIndexStaysNormalAndIsReported() throws {
        let (c, r) = try blendClip(code: 19, index: 40)
        #expect(c.blendMode == .normal)
        #expect(r.report.status(of: "Opacity blend mode") == .dropped)
    }

    @Test func lumetriSharpenBecomesSharpenAfterColour() throws {
        let f = PRFixture()
        let m = f.media(path: "/f/a.mov", title: "a.mov")
        let lumetri = f.component("AE.ADBE Lumetri", [f.param(3, "true"), f.param(7, "-3."), f.param(23, "true"), f.param(29, "20.")])
        f.sequence("Main", video: [f.track([f.item(start: 0, end: S, inPoint: 0, outPoint: S, source: .media(m), components: [lumetri])])])
        let r = try map(f)
        let fx = clips(r)[0].effects
        #expect(fx.map(\.kind) == [ClipEffect.colorKind, ClipEffect.sharpenKind])
        #expect(fx[1].parameters[ClipEffect.sharpenAmountKey]?.value == 20)
        #expect(r.report.status(of: "Lumetri sharpen") == .approximated)
    }

    @Test func lumetriNegativeOrZeroSharpenAddsNothing() throws {
        for value in ["0.", "-30."] {
            let f = PRFixture()
            let m = f.media(path: "/f/a.mov", title: "a.mov")
            let lumetri = f.component("AE.ADBE Lumetri", [f.param(3, "true"), f.param(7, "-3."), f.param(29, value)])
            f.sequence("Main", video: [f.track([f.item(start: 0, end: S, inPoint: 0, outPoint: S, source: .media(m), components: [lumetri])])])
            #expect(!clips(try map(f))[0].effects.contains { $0.kind == ClipEffect.sharpenKind })
        }
    }

    @Test func mosaicTintFlipAndNoiseMap() throws {
        let f = PRFixture()
        let m = f.media(path: "/f/a.mov", title: "a.mov")
        let mosaic = f.component("AE.ADBE Mosaic", [f.param(1, "63"), f.param(2, "106"), f.param(3, "true")])
        let tint = f.component("AE.ADBE Tint", [f.param(1, "18374686479671623680"), f.param(2, "18374966859414961920"), f.param(3, "60.")])
        let flip = f.component("AE.ADBE Horizontal Flip", [])
        let noise = f.component("AE.ADBE_Noise_FX", [f.param(3, "40."), f.param(8, "50."), f.param(10, "50.")])
        f.sequence("Main", video: [f.track([f.item(start: 0, end: S, inPoint: 0, outPoint: S, source: .media(m),
                                                     components: [mosaic, tint, flip, noise])])])
        let r = try map(f)
        let fx = clips(r)[0].effects
        #expect(fx.map(\.kind) == [ClipEffect.mosaicKind, ClipEffect.tintKind, ClipEffect.horizontalFlipKind, ClipEffect.noiseKind])
        #expect(fx[0].parameters[ClipEffect.mosaicColumnsKey]?.value == 63 && fx[0].parameters[ClipEffect.mosaicRowsKey]?.value == 106)
        #expect(fx[0].parameters[ClipEffect.mosaicSharpKey]?.value == 1)
        #expect(fx[1].parameters[ClipEffect.tintAmountKey]?.value == 60)
        #expect(fx[1].colors[ClipEffect.tintBlackKey]?.value == EffectColor(red: 0, green: 0, blue: 0))
        #expect(fx[1].colors[ClipEffect.tintWhiteKey]?.value == EffectColor(red: 1, green: 1, blue: 1))
        #expect((fx[3].parameters[ClipEffect.noiseAmountKey]?.value ?? 0) > 0)
        #expect(r.report.status(of: "AE.ADBE Mosaic") == .mapped)
        #expect(r.report.status(of: "AE.ADBE Tint") == .mapped)
        #expect(r.report.status(of: "AE.ADBE Horizontal Flip") == .mapped)
        #expect(r.report.status(of: "AE.ADBE_Noise_FX") == .approximated)
    }

    /// Param ids as in the maintainer's two Ultra Key instances (key color #4FB120, Premiere's defaults elsewhere).
    func ultraKey(colour: String, output: String = "0", function: String = #function) throws -> ([ClipEffect], PRImportReport) {
        let f = PRFixture()
        let m = f.media(path: "/f/a.mov", title: "a.mov")
        let key = f.component("AE.ADBE Ultra Key", [
            f.param(1, output), f.param(2, "3"), f.param(3, colour), f.param(5, "45."), f.param(6, "10."), f.param(7, "50."),
            f.param(8, "100."), f.param(9, "10."), f.param(12, "10."), f.param(13, "0."), f.param(14, "30."), f.param(15, "40."),
            f.param(18, "25."), f.param(19, "50."), f.param(20, "60."), f.param(21, "50."), f.param(24, "80."), f.param(25, "5."),
            f.param(26, "100."),
        ])
        f.sequence("Main", video: [f.track([f.item(start: 0, end: S, inPoint: 0, outPoint: S, source: .media(m), components: [key])])])
        let r = try map(f, function: function)
        return (clips(r)[0].effects, r.report)
    }

    @Test func ultraKeyMapsHueAndSharedControls() throws {
        let (fx, report) = try ultraKey(colour: "18374773344059793408", output: "1")
        let e = try #require(fx.first)
        #expect(fx.count == 1 && e.kind == ClipEffect.ultraKeyKind)
        func v(_ k: String) -> Double { e.parameters[k]?.value ?? .nan }
        #expect(abs(v(ClipEffect.keyHueKey) - 100.55) < 0.01)          // hue of #4FB120
        #expect(v(ClipEffect.pedestalKey) == 10 && v(ClipEffect.chokeKey) == 10)
        #expect(v(ClipEffect.keyContrastKey) == 30 && v(ClipEffect.keyMidpointKey) == 40)
        #expect(v(ClipEffect.spillKey) == 60 && v(ClipEffect.spillRangeKey) == 50)      // Premiere Spill is id 20; 18 is Desaturate
        #expect(v(ClipEffect.keySaturationKey) == 80 && v(ClipEffect.keyHueShiftKey) == 5 && v(ClipEffect.keyLumaKey) == 100)
        #expect(v(ClipEffect.keyOutputKey) == 1)
        // Matte generation is SQ's own formulation: the Green Screen preset's starting values, not Premiere's numbers.
        #expect(v(ClipEffect.toleranceKey) == 45 && v(ClipEffect.softenKey) == 20)
        #expect(report.status(of: "AE.ADBE Ultra Key") == .approximated)
    }

    @Test func ultraKeyWithoutAKeyColourIsDropped() throws {
        let (fx, report) = try ultraKey(colour: "18374686479671623680")    // Premiere's default: black, keys nothing
        #expect(fx.isEmpty)
        #expect(report.status(of: "AE.ADBE Ultra Key") == .dropped)
    }

    /// Ramp param ids as in the maintainer's instance (iPhone 18 Pro Leaks): points are 0...1 of the frame.
    @Test func rampBecomesGradient() throws {
        let f = PRFixture()
        let m = f.media(path: "/f/a.mov", title: "a.mov")
        let ramp = f.component("AE.ADBE Ramp", [
            f.param(1, "0.5:0"), f.param(2, "18374686479671623680"), f.param(3, "0.5:1"), f.param(4, "18374966859414961920"),
            f.param(5, "1"), f.param(6, "0."), f.param(7, "25."),
        ])
        f.sequence("Main", video: [f.track([f.item(start: 0, end: S, inPoint: 0, outPoint: S, source: .media(m), components: [ramp])])])
        let r = try map(f)
        let e = try #require(clips(r)[0].effects.first)
        #expect(e.kind == ClipEffect.gradientKind)
        let a = try #require(e.points[ClipEffect.gradientStartKey]?.value), b = try #require(e.points[ClipEffect.gradientEndKey]?.value)
        #expect(a.x == 0 && b.x == 0 && a.y < 0 && a.y == -b.y)        // px from the frame center, top to bottom
        #expect(e.colors[ClipEffect.gradientColor1Key]?.value == EffectColor(red: 0, green: 0, blue: 0))
        #expect(e.colors[ClipEffect.gradientColor2Key]?.value == EffectColor(red: 1, green: 1, blue: 1))
        #expect(e.parameters[ClipEffect.gradientTypeKey]?.value == 1)
        #expect(e.parameters[ClipEffect.gradientBlendKey]?.value == 75)
        #expect(r.report.status(of: "AE.ADBE Ramp") == .mapped)
    }

    /// Ramp color keys stay keys (they used to be dropped).
    @Test func rampColorKeysAreKept() throws {
        let f = PRFixture()
        let m = f.media(path: "/f/a.mov", title: "a.mov")
        let keys = "0,18374686479671623680,0,0,0,0,0,0;254016000000,18446744069414584320,0,0,0,0,0,0"
        let ramp = f.component("AE.ADBE Ramp", [
            f.param(1, "0.5:0"), f.param(2, "18374686479671623680", keys: keys), f.param(3, "0.5:1"), f.param(4, "18446744069414584320"),
            f.param(5, "0"), f.param(6, "0."), f.param(7, "0."),
        ])
        f.sequence("Main", video: [f.track([f.item(start: 0, end: S, inPoint: 0, outPoint: S, source: .media(m), components: [ramp])])])
        let r = try map(f)
        let e = try #require(clips(r)[0].effects.first)
        #expect(e.colors[ClipEffect.gradientColor1Key]?.track.keys.count == 2)
        #expect(r.report.status(of: "AE.ADBE Ramp") == .mapped)
    }
}
