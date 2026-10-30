import Foundation
import Testing
import SQCore
import SQAudioFX
import SQDrawKit
import SQUIKit
@testable import SQInspectorUI

/// The shared-toolkit Multiband setup (`MultibandEditorDraw`): its controls reach the same model calls as the Mac window.
@MainActor @Suite struct MultibandEditorDrawTests {
    func rig() -> (EffectControlsModel, ClipEffect.ID, MultibandEditorDraw) {
        var clip = Clip(name: "Voice", media: UUID(), kind: .audio,
                        source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero)
        let id = clip.addEffect(kind: ClipEffect.audioMultibandKind)!
        let m = EffectControlsModel()
        m.setClip(clip)
        m.onEdit = { [weak m] c, _, _ in m?.setClip(c) }
        let e = MultibandEditorDraw(effect: id, model: m)
        e.clock = { 100 }
        return (m, id, e)
    }

    func click(_ e: MultibandEditorDraw, _ k: MultibandEditorDraw.Control) {
        let f = e.frames[k]!
        let p = CGPoint(x: f.midX, y: f.midY)
        e.mouseDown(at: p, clickCount: 1)
        e.mouseUp(at: p)
    }

    @Test func layoutFitsAndEveryFieldHasAFrame() {
        let (_, _, e) = rig()
        #expect(e.size.width == 560 && e.size.height > 500 && e.size.height < 640)
        for key in MultibandEditorDraw.fieldKeys { #expect(e.frames[.field(key)] != nil) }
        #expect(MultibandEditorDraw.fieldKeys.count == 1 + 3 + 20 + 4)
        // Nothing overlaps another control.
        let all = Array(e.frames.values)
        for (i, a) in all.enumerated() { for b in all[(i + 1)...] { #expect(!a.intersects(b)) } }
        #expect(e.clipName == "Voice")
    }

    @Test func togglesAndPresetMenuEditTheEffect() {
        let (m, id, e) = rig()
        click(e, .solo(1))
        #expect(m.multibandSolo(id, band: 1))
        click(e, .bypass(2))
        #expect(m.multibandBypass(id, band: 2))
        click(e, .link)
        #expect(m.multibandLinked(id))
        click(e, .limiter)
        #expect(m.multibandValue(id, ClipEffect.mbLimiterOnKey) >= 0.5)
        var menu: [SQMenuItem] = []
        e.onMenu = { items, _ in menu = items }
        click(e, .preset)
        #expect(menu.count == MultibandEditor.presets.count + 1)
        menu[1].action?()
        #expect(m.multibandValue(id, ClipEffect.mbCrossoverKey(3)) == 6910)
        click(e, .power)
        #expect(!m.isEffectEnabled(.effect(id, kind: ClipEffect.audioMultibandKind)))
    }

    @Test func fieldsDragTypeAndLinkBands() {
        let (m, id, e) = rig()
        m.setMultibandLink(id, true)
        let key = ClipEffect.mbGainKey(1), f = e.frames[.field(key)]!
        let before = (1...4).map { m.multibandValue(id, ClipEffect.mbGainKey($0)) }
        e.mouseDown(at: CGPoint(x: f.midX, y: f.midY), clickCount: 1)
        e.mouseDragged(to: CGPoint(x: f.midX + 40, y: f.midY))
        e.mouseUp(at: CGPoint(x: f.midX + 40, y: f.midY))
        let after = (1...4).map { m.multibandValue(id, ClipEffect.mbGainKey($0)) }
        #expect(after[0] > before[0])
        #expect(abs((after[3] - before[3]) - (after[0] - before[0])) < 0.001)       // linked: same delta
        // Typing into a crossover field.
        let x = e.frames[.field(ClipEffect.mbCrossoverKey(2))]!
        e.mouseDown(at: CGPoint(x: x.midX, y: x.midY), clickCount: 1)
        e.mouseUp(at: CGPoint(x: x.midX, y: x.midY))
        for ch in "2000" { _ = e.key(.character(ch), modifiers: []) }
        for _ in 0..<8 { _ = e.key(.backspace, modifiers: []) }
        for ch in "2000" { _ = e.key(.character(ch), modifiers: []) }
        _ = e.key(.enter, modifiers: [])
        #expect(m.multibandValue(id, ClipEffect.mbCrossoverKey(2)) == 2000)
    }

    @Test func stripDragsACrossoverAndMetersFeedTheBars() {
        let (m, id, e) = rig()
        let s = e.frames[.strip]!, g = CompressorBandsGeometry(width: s.width)
        let x0 = s.minX + g.x(forHz: m.crossovers(id)[0])
        e.mouseDown(at: CGPoint(x: x0, y: s.midY), clickCount: 1)
        e.mouseDragged(to: CGPoint(x: x0 + 30, y: s.midY))
        e.mouseUp(at: CGPoint(x: x0 + 30, y: s.midY))
        #expect(m.crossovers(id)[0] > 130)
        e.feed(MultibandMeterReading(sequence: 3, inputPeak: SIMD4(0.5, 0, 0, 0), gainReductionDB: SIMD4(6, 0, 0, 0),
                                     limiterReductionDB: 1), at: 1)
        #expect(e.meters.isLive && e.meters.gainReductionDB[0] == 6)
        var c = Canvas(width: 600, height: 600, atlas: nil, scale: 1)
        e.draw(&c)
    }

    @Test func spectrumCurveFeedsAndInputToggleIsKept() {
        let key = MultibandEditorDraw.spectrumInputDefaultsKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.set(false, forKey: key)
        let (_, _, e) = rig()
        e.feedSpectrum(sequence: 1, at: 0) { (0..<SpectrumDisplay.points).map { -30 - Float($0 % 7) } }
        #expect(e.spectrum.levelsDB.count == SpectrumDisplay.points)
        var c = Canvas(width: 600, height: 600, atlas: nil, scale: 1)
        e.draw(&c)
        e.feedSpectrum(sequence: 1, at: 1) { [] }              // stale: the curve goes away
        #expect(e.spectrum.levelsDB.isEmpty)
        click(e, .spectrumInput)
        #expect(e.spectrumAtInput)
        #expect(e.help(at: CGPoint(x: e.frames[.spectrumInput]!.midX, y: e.frames[.spectrumInput]!.midY)) != nil)
        click(e, .spectrumInput)
        #expect(!e.spectrumAtInput)
    }

    @Test func escClosesAndAGoneEffectReportsIt() {
        let (m, id, e) = rig()
        var closed = 0
        e.onClose = { closed += 1 }
        #expect(e.key(.escape, modifiers: []))
        #expect(closed == 1)
        #expect(!e.key(.space, modifiers: []))                    // Space is left to the shell (play)
        var clip = m.clip!
        clip.effects.removeAll { $0.id == id }
        m.setClip(clip)
        #expect(!e.sync())
    }
}
