import Foundation
import Testing
import SQCore
@testable import SQInspectorUI

/// Pre-release audit: every parameter of every catalog effect behaves the same way in Effect Controls.
@MainActor @Suite struct EffectControlsCatalogAuditTests {
    func rig(kind: String, audio: Bool) -> (EffectControlsModel, EffectSection)? {
        var clip = Clip(name: "c", media: UUID(), kind: audio ? .audio : .video,
                        source: TimeRange(start: .zero, duration: Time(10, 1)), start: Time(5, 1))
        guard let id = clip.addEffect(kind: kind) else { return nil }
        let m = EffectControlsModel()
        m.onEdit = { _, _, _ in }
        m.setClip(clip); m.playhead = Time(6, 1)
        return (m, .effect(id, kind: kind))
    }

    var allSpecs: [(EffectSpec, Bool)] {
        EffectCatalog.all.map { ($0, false) } + EffectCatalog.audio.map { ($0, true) }
    }

    @Test func everyColourAndPointRowEditsResetsAndKeys() {
        var problems: [String] = []
        for (spec, audio) in allSpecs {
            guard let (m, section) = rig(kind: spec.kind, audio: audio) else { continue }
            for p in section.properties where p.kind == .color || p.kind == .vector {
                let name = "\(spec.kind).\(p.title)"
                // A newly applied Blur/Sharpen/Spherize/Stereo Width starts at a visible value (AUDIT G13), not at the Reset default.
                if !m.isDefault(p), ClipEffect.appliedStartValues[spec.kind] == nil { problems.append("\(name): fresh row is not default"); continue }
                if p.kind == .color {
                    let probe = EffectColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.4)
                    if !m.setColor(p, to: probe) || m.colorValue(p) != probe { problems.append("\(name): color does not commit") }
                } else {
                    let probe = p.pair?.linkable == true ? Vec2(12, 12) : Vec2(12, -7)      // a linked Scale keeps Width = Height
                    if !m.setVector(p, to: probe) || m.vectorValue(p) != probe { problems.append("\(name): point does not commit") }
                }
                if m.isDefault(p) { problems.append("\(name): edited row still default") }
                m.resetAll(p)
                if !m.isDefault(p) { problems.append("\(name): reset does not restore default") }
                if m.toggleStopwatch(p) != .added || !m.isAnimated(p) { problems.append("\(name): stopwatch add failed"); continue }
                if m.toggleStopwatch(p, confirmRemoval: true) != .removed || m.isAnimated(p) { problems.append("\(name): stopwatch remove failed") }
            }
        }
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    @Test func nonFiniteInputIsRefused() {
        var clip = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero)
        _ = clip.addEffect(kind: ClipEffect.gaussianBlurKind)
        let m = EffectControlsModel(); m.onEdit = { _, _, _ in }
        m.setClip(clip); m.playhead = Time(1, 1)
        for p in EffectSection.motion.properties {
            #expect(!m.setValue(p, to: .nan) && !m.setValue(p, to: .infinity))
        }
        #expect(m.clip?.animation.opacity.value == 1)
    }

    @Test func relativeKeyEditStaysInsideRange() {
        var clip = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero)
        _ = clip.addEffect(kind: ClipEffect.gaussianBlurKind)
        let m = EffectControlsModel(); m.onEdit = { _, _, _ in }
        m.setClip(clip); m.playhead = .zero
        m.setValue(.opacity, to: 0.5)
        #expect(m.toggleStopwatch(.opacity) == .added)
        m.playhead = Time(2, 1)
        m.setValue(.opacity, to: 0.9)
        m.selectKeys(in: Time.zero...Time(2, 1), properties: [.opacity], extend: false)
        m.playhead = Time(2, 1)
        m.setValue(.opacity, to: 5)       // typed 500 %: all selected keys shift together but stay <= 100 %
        #expect(m.track(.opacity)!.times.allSatisfy { _ in true })
        #expect(m.clip!.animation.opacity.track.keys.allSatisfy { $0.value <= 1 && $0.value >= 0 })
    }

    @Test func everyScalarRowResetsAndKeys() {
        var problems: [String] = []
        for (spec, audio) in allSpecs {
            guard let (m, section) = rig(kind: spec.kind, audio: audio) else { problems.append("\(spec.kind): cannot add"); continue }
            for p in section.properties where p.kind == .scalar {
                let name = "\(spec.kind).\(p.title)"
                guard let def = m.defaultValue(p) else { problems.append("\(name): no default (reset is a no-op)"); continue }
                // A newly applied Blur/Sharpen/Spherize/Stereo Width starts at a visible value (AUDIT G13), not at the Reset default.
                if !m.isDefault(p), ClipEffect.appliedStartValues[spec.kind] == nil { problems.append("\(name): fresh row is not default"); continue }
                let r = p.displayRange
                guard r.lowerBound > -1e9, r.upperBound < 1e9 else { continue }
                for (probe, bound) in [(r.upperBound + 1000, r.upperBound), (r.lowerBound - 1000, r.lowerBound)] {
                    m.setValue(p, to: p.native(fromDisplay: probe))
                    let shown = p.display(m.scalarValue(p))
                    if abs(shown - bound) > 1e-6 { problems.append("\(name): \(probe) stored as \(shown), range \(r)") }
                }
                m.resetAll(p)
                if !m.isDefault(p) || m.scalarValue(p) != def.value { problems.append("\(name): reset does not restore default") }
                if m.toggleStopwatch(p) != .added { problems.append("\(name): stopwatch add failed"); continue }
                if !m.isAnimated(p) { problems.append("\(name): not animated after stopwatch") }
                if m.toggleStopwatch(p, confirmRemoval: true) != .removed || m.isAnimated(p) { problems.append("\(name): stopwatch remove failed") }
            }
        }
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }
}
