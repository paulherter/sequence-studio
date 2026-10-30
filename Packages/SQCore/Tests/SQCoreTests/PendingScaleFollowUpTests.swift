import Foundation
import Testing
@testable import SQCore

/// H6 3/4 review fixes: a clip marked `pendingSourcePixelScale` (v9 file, no probe info yet) must not be converted twice
/// after Scale was written in the new semantics, Relink runs the owed step, the marker is version gated (v35), and
/// variant overrides of Scale/Anchor convert with the base Scale.
@Suite struct PendingScaleFollowUpTests {
    private func s(_ n: Int64) -> Time { Time(n, 1) }
    private let fd = Time(1, 30)

    private func info(w: Int, h: Int) -> MediaInfo {
        let v = VideoTrackInfo(width: w, height: h, codec: "hvc1", bitDepth: 10, chroma: "4:2:0",
                               nominalFrameDuration: Time(1, 30), isVariableFrameRate: false)
        return MediaInfo(duration: s(10), video: v)
    }

    /// 1920x1080 sequence, one pending clip at Scale 200 % on 3840x2160 media without probe info (fit 0.5).
    private func pendingProject() -> (Project, MediaRef.ID) {
        let m = MediaRef(name: "m", path: "/m.mov", fingerprint: MediaFingerprint(size: 1), duration: s(10), info: nil)
        var c = Clip(name: "c", media: m.id, kind: .video, source: TimeRange(start: .zero, duration: s(5)), start: .zero)
        c.animation.scale = AnimatedProperty(Vec2(2, 2))
        c.animation.anchor = AnimatedProperty(Vec2(100, 50))
        c.pendingSourcePixelScale = true
        var p = Project(name: "t", timelines: [Timeline(name: "T", format: SequenceFormat(width: 1920, height: 1080, frameDuration: fd),
                                                        tracks: [Track(kind: .video, clips: [c])])])
        p.add(m)
        return (p, m.id)
    }

    private func setInfo(_ p: inout Project, _ id: MediaRef.ID) {
        let i = p.media.firstIndex { $0.id == id }!
        p.media[i].info = info(w: 3840, h: 2160)
    }

    private func firstClip(_ p: Project) -> Clip { p.timelines[0].tracks[0].clips[0] }

    // MARK: (1) Scale written in the new semantics clears the marker

    @Test func pasteAttributesFromAConvertedClipClearsTheMarker() {
        var (p, id) = pendingProject()
        var src = Clip(name: "s", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(5)), start: .zero)
        src.animation.scale = AnimatedProperty(Vec2(0.5, 0.5))
        let pasted = firstClip(p).pastingAttributes(from: src)
        #expect(!pasted.pendingSourcePixelScale)
        p.timelines[0].tracks[0].replace(pasted)
        setInfo(&p, id)
        p.applyPendingScaleMigration()
        #expect(firstClip(p).animation.scale.value == Vec2(0.5, 0.5))   // not converted a second time
    }

    @Test func pasteAttributesFromAPendingClipCarriesTheMarker() {
        let (p, _) = pendingProject()
        let target = Clip(name: "t", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(5)), start: .zero)
        #expect(target.pastingAttributes(from: firstClip(p)).pendingSourcePixelScale)
    }

    @Test func absolutePresetWithScaleClearsTheMarkerRelativeKeepsIt() {
        let (p, _) = pendingProject()
        let preset = EffectPreset(referenceDuration: s(5), scale: AnimatedProperty(Vec2(0.75, 0.75)))
        var abs = firstClip(p)
        abs.applyPreset(preset, mode: .absolute)
        #expect(!abs.pendingSourcePixelScale)
        var rel = firstClip(p)
        rel.applyPreset(preset, mode: .relative)
        #expect(rel.pendingSourcePixelScale)   // a factor on the old value keeps its meaning
        var opacityOnly = firstClip(p)
        opacityOnly.applyPreset(EffectPreset(referenceDuration: s(5), opacity: AnimatedProperty(0.5)), mode: .absolute)
        #expect(opacityOnly.pendingSourcePixelScale)
    }

    // MARK: (2) Relink runs the owed step

    @Test func relinkWithProbeInfoRunsThePendingStep() {
        var (p, id) = pendingProject()
        #expect(p.mediaAwaitingProbeForPendingScale([id: "/new.mov"]) == [id])
        p.relink([id: "/new.mov"], probed: [id: info(w: 3840, h: 2160)])
        #expect(p.media(id)?.path == "/new.mov")
        #expect(p.media(id)?.info?.video?.width == 3840)
        #expect(firstClip(p).animation.scale.value == Vec2(1, 1))
        #expect(!firstClip(p).pendingSourcePixelScale)
        #expect(p.mediaAwaitingProbeForPendingScale([id: "/new.mov"]).isEmpty)
    }

    @Test func relinkOfMediaThatAlreadyHasInfoRunsThePendingStep() {
        var (p, id) = pendingProject()
        setInfo(&p, id)
        #expect(p.mediaAwaitingProbeForPendingScale([id: "/new.mov"]).isEmpty)
        p.relink([id: "/new.mov"])
        #expect(firstClip(p).animation.scale.value == Vec2(1, 1))
        #expect(!firstClip(p).pendingSourcePixelScale)
    }

    @Test func relinkWithoutInfoKeepsTheMarker() {
        var (p, id) = pendingProject()
        p.relink([id: "/new.mov"])
        #expect(firstClip(p).pendingSourcePixelScale)
        #expect(firstClip(p).animation.scale.value == Vec2(2, 2))
    }

    // MARK: (3) Version gate

    private func writtenVersion(_ p: Project) throws -> Int {
        let obj = try #require(JSONSerialization.jsonObject(with: ProjectFile.encode(p)) as? [String: Any])
        return try #require(obj["formatVersion"] as? Int)
    }

    @Test func currentVersionIs35() { #expect(ProjectFile.currentVersion >= 35) }

    @Test func pendingClipsAreWrittenWithAVersionV34BuildsRefuse() throws {
        let (p, _) = pendingProject()
        #expect(try writtenVersion(p) >= ProjectFile.pendingScaleVersion)
        #expect(ProjectFile.pendingScaleVersion > 34)
        let back = try ProjectFile.decode(ProjectFile.encode(p), migrations: ProjectFile.migrations)
        #expect(firstClip(back).pendingSourcePixelScale)
    }

    @Test func filesWithoutPendingClipsStayReadableByV34() throws {
        var (p, id) = pendingProject()
        setInfo(&p, id)
        p.applyPendingScaleMigration()
        let v = try writtenVersion(p)
        #expect(v == ProjectFile.writtenVersion(for: p))   // v36 after W9.7, v37 only with subject masks (W9.8)
        let back = try ProjectFile.decode(ProjectFile.encode(p), migrations: ProjectFile.migrations)
        #expect(back == p)
    }

    @Test func newerVersionIsRefused() throws {
        let (p, _) = pendingProject()
        var obj = try #require(JSONSerialization.jsonObject(with: ProjectFile.encode(p)) as? [String: Any])
        obj["formatVersion"] = ProjectFile.currentVersion + 1
        let data = try JSONSerialization.data(withJSONObject: obj)
        #expect(throws: ProjectFileError.newerVersion(found: ProjectFile.currentVersion + 1, supported: ProjectFile.currentVersion)) {
            _ = try ProjectFile.decode(data, migrations: ProjectFile.migrations)
        }
    }

    // MARK: (4) Variant overrides convert with the base Scale

    /// Overrides come from `Timeline.detach` (base Scale x the conform factor), so they convert with the base fit.
    /// 1920x1080 sequence, 3840x2160 picture (f 0.5), 1080x1920 fill variant (k 1.778): 177.8 % -> 88.9 %.
    @Test func variantOverridesConvertWithTheBaseFit() {
        var (p, id) = pendingProject()
        let variant = FormatVariant(name: "9:16", width: 1080, height: 1920)
        p.timelines[0].variants = [variant]
        var c = firstClip(p)
        c.animation.scale = AnimatedProperty(Vec2(1, 1))
        let k = 1920.0 / 1080.0
        var scale = AnimatedProperty(Vec2(k, k))
        scale.track.insert(Keyframe(time: s(1), value: Vec2(2 * k, 2 * k)))
        c.variantOverrides[variant.id] = VariantOverride(position: AnimatedProperty(Vec2(10, 20)), scale: scale,
                                                         anchor: AnimatedProperty(Vec2(90, 45)))
        p.timelines[0].tracks[0].replace(c)
        setInfo(&p, id)
        p.applyPendingScaleMigration()
        let o = firstClip(p).variantOverrides[variant.id]
        #expect(o?.scale?.value == Vec2(k * 0.5, k * 0.5))
        #expect(o?.scale?.track.keys.first?.value == Vec2(k, k))
        #expect(o?.anchor?.value == Vec2(180, 90))
        #expect(o?.position?.value == Vec2(10, 20))
        #expect(firstClip(p).animation.scale.value == Vec2(0.5, 0.5))
    }

    /// Scale tangents scale with the values (as `SequenceConform.scaled`); Anchor tangents divide.
    @Test func scaleKeyTangentsConvertWithTheValues() {
        var (p, id) = pendingProject()
        let variant = FormatVariant(name: "9:16", width: 1080, height: 1920)
        p.timelines[0].variants = [variant]
        var c = firstClip(p)
        var key = Keyframe(time: s(1), value: Vec2(4, 4))
        key.inTangent = Vec2(0.2, 0.4); key.outTangent = Vec2(0.6, 0.8)
        c.animation.scale.track.insert(key)
        var akey = Keyframe(time: s(1), value: Vec2(10, 10))
        akey.inTangent = Vec2(2, 4)
        c.animation.anchor.track.insert(akey)
        var o = AnimatedProperty(Vec2(1, 1)); o.track.insert(key)
        c.variantOverrides[variant.id] = VariantOverride(scale: o)
        p.timelines[0].tracks[0].replace(c)
        setInfo(&p, id)
        p.applyPendingScaleMigration()
        let k = firstClip(p).animation.scale.track.keys[0]
        #expect(k.inTangent == Vec2(0.1, 0.2) && k.outTangent == Vec2(0.3, 0.4))
        #expect(firstClip(p).animation.anchor.track.keys[0].inTangent == Vec2(4, 8))
        let ok = firstClip(p).variantOverrides[variant.id]?.scale?.track.keys[0]
        #expect(ok?.inTangent == Vec2(0.1, 0.2) && ok?.outTangent == Vec2(0.3, 0.4))
    }
}
