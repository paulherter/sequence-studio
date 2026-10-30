import Foundation
import Testing
import SQCore
import SQDrawKit
import SQEditorSession
@testable import SQDrawMonitor

/// Source monitor drags onto the timeline (picture and stream handles) and the waveform view's level meter.
@MainActor
@Suite struct SourceDragTests {
    func source(waveform: Bool = false) -> MonitorPanel {
        let m = MonitorPanelModel(frameDuration: Time(1, 25), mode: .source)
        m.duration = Time(250, 25)
        m.sourceItems = [.init(id: UUID(), name: "clip.mov")]
        if waveform { m.viewerMode = .waveform }
        let p = MonitorPanel(model: m)
        p.layout(DrawRect(x: 0, y: 0, w: 800, h: 500), scale: 1)
        var c = Canvas(width: 800, height: 500, atlas: nil, scale: 1)
        p.draw(&c)
        return p
    }

    @Test func pictureDragsBothStreamsAfterFourPoints() {
        let p = source()
        var log: [(SourceStreams, MonitorDragPhase)] = []
        p.onSourceDrag = { s, ph, _, _ in log.append((s, ph)) }
        var ended = 0
        p.model.onDragEnded = { ended += 1 }
        let c = p.canvasRect
        _ = p.handle(.mouseDown(x: Float(c.midX), y: Float(c.midY), modifiers: []))
        _ = p.handle(.mouseDragged(x: Float(c.midX + 2), y: Float(c.midY)))
        #expect(log.isEmpty)                                  // under the threshold
        #expect(p.activeSourceDrag == nil)
        _ = p.handle(.mouseDragged(x: Float(c.midX + 30), y: Float(c.midY + 400)))
        #expect(p.activeSourceDrag == .both)
        _ = p.handle(.mouseUp(x: Float(c.midX + 30), y: Float(c.midY + 400)))
        #expect(log.map(\.0) == [.both, .both])
        #expect(log.map(\.1) == [.moved, .ended])
        #expect(ended == 1)
        #expect(!p.isDragging)
    }

    @Test func aClickWithoutMovementIsNoDrag() {
        let p = source()
        var calls = 0
        p.onSourceDrag = { _, _, _, _ in calls += 1 }
        let c = p.canvasRect
        _ = p.handle(.mouseDown(x: Float(c.midX), y: Float(c.midY), modifiers: []))
        _ = p.handle(.mouseUp(x: Float(c.midX), y: Float(c.midY)))
        #expect(calls == 0)
    }

    @Test func footerHandlesDragOneStreamAndEscCancels() {
        let p = source()
        #expect(p.footer.streamHandles.map(\.0) == [.videoOnly, .audioOnly])
        var log: [(SourceStreams, MonitorDragPhase)] = []
        p.onSourceDrag = { s, ph, _, _ in log.append((s, ph)) }
        let audio = p.footer.streamHandles[1].1
        _ = p.handle(.mouseDown(x: Float(audio.midX), y: Float(audio.midY), modifiers: []))
        _ = p.handle(.mouseDragged(x: Float(audio.midX - 40), y: Float(audio.midY + 60)))
        #expect(p.handle(.keyDown(.escape, modifiers: [])))
        #expect(log.map(\.0) == [.audioOnly, .audioOnly])
        #expect(log.map(\.1) == [.moved, .canceled])
        #expect(p.activeSourceDrag == nil)
    }

    @Test func programHasNoStreamHandles() {
        let m = MonitorPanelModel(frameDuration: Time(1, 25), mode: .program)
        let p = MonitorPanel(model: m)
        p.layout(DrawRect(x: 0, y: 0, w: 800, h: 500), scale: 1)
        #expect(p.footer.streamHandles.isEmpty)
    }

    @Test func narrowFooterDropsTheHandlesFirst() {
        let m = MonitorPanelModel(frameDuration: Time(1, 25), mode: .source)
        let p = MonitorPanel(model: m)
        p.layout(DrawRect(x: 0, y: 0, w: 330, h: 300), scale: 1)
        #expect(p.footer.streamHandles.isEmpty)
    }

    @Test func waveformMeterTakesItsColumnAndFollowsTheFeed() {
        let p = source(waveform: true)
        #expect(p.waveMeterRect == .zero)                    // no feed: the waveform spans the slot
        let full = p.waveMath.width
        let id = ObjectIdentifier(p)
        p.waveMeterReading = { (id, 1, [0.5, 0.25]) }
        #expect(p.waveMeterRect.width == AudioMeter.width)
        #expect(p.waveMath.width < full)
        p.pollWaveMeter(now: 1)
        #expect(p.waveMeter.meter.readout != "\u{2013}")    // a level shows
        p.waveMeterReading = nil
        #expect(p.waveMeterRect == .zero)
    }

    @Test func waveformMeterLabelSolosAndAltMutes() {
        let p = source(waveform: true)
        p.waveMeterReading = { nil }
        var changes = 0
        p.onWaveChannelMonitorChange = { _ in changes += 1 }
        let r = p.waveMeterRect
        let left = CGPoint(x: r.minX + 10, y: r.maxY - 8)    // the "L" label row
        _ = p.handle(.mouseDown(x: Float(left.x), y: Float(left.y), modifiers: []))
        #expect(p.waveMeter.channelMonitor.isSoloed(0))
        #expect(p.waveMeter.labels.first == .soloed)
        _ = p.handle(.mouseDown(x: Float(left.x), y: Float(left.y), modifiers: [.option]))
        #expect(p.waveMeter.channelMonitor.isMuted(0))
        #expect(changes == 2)
    }
}
