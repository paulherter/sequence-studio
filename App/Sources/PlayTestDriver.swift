import AppKit
import Metal
import SQCore
import SQEditorUI
import SQPlayback

/// Developer aid: `SQ_PLAYTEST=<media file>` imports the clip, places it at 0, seeks and plays in the real window
/// and logs what the playback engine reports (presented frames, drops, position, a readback pixel). Quits when done.
@MainActor
enum PlayTestDriver {
    /// `SQ_KEYTEST=1` (with SQ_IMPORT): posts real Space key events into the window and logs the session state.
    static func runKeyTestIfRequested(_ c: AppController) {
        guard ProcessInfo.processInfo.environment["SQ_KEYTEST"] == "1" else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            for i in 1...4 {
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: c.window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ",
                                             isARepeat: false, keyCode: 49)!
                    NSApp.postEvent(e, atStart: false)
                }
                try? await Task.sleep(for: .seconds(1))
                NSLog("KEYTEST press \(i): isPlaying=\(c.session.isPlaying) rate=\(c.session.engine.rate) playhead=\(c.session.playhead.value)/\(c.session.playhead.timescale)")
            }
            exit(0)
        }
    }

    static func runIfRequested(_ c: AppController) {
        guard let path = ProcessInfo.processInfo.environment["SQ_PLAYTEST"] else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard let engine = c.session.engine as? PlaybackEngine else { NSLog("PLAYTEST: stub engine, no Metal"); exit(1) }
            await c.panels.projectModel.importFiles([URL(fileURLWithPath: path)])
            NSLog("PLAYTEST media=\(c.session.project.media.count) failures=\(c.panels.projectModel.importFailures)")
            guard let m = c.session.project.media.first else { exit(2) }
            let placed = c.session.placeMedia([m.id], at: .zero, mode: .overwrite)
            NSLog("PLAYTEST placed=\(placed) timeline duration=\(c.session.activeTimeline?.duration.value ?? -1)/\(c.session.activeTimeline?.duration.timescale ?? 0) format=\(String(describing: c.session.activeTimeline?.format.width))x\(String(describing: c.session.activeTimeline?.format.height))")
            try? await Task.sleep(for: .seconds(1))
            report("after place (no seek)", c, engine)
            c.session.seek(to: Time(1, 1))
            try? await Task.sleep(for: .seconds(1.5))
            report("after seek 1s", c, engine)
            c.session.playPause()
            try? await Task.sleep(for: .seconds(2))
            report("playing 2s", c, engine)
            c.session.playPause()
            try? await Task.sleep(for: .seconds(0.5))
            report("paused", c, engine)
            c.session.seek(to: Time(3, 1))
            try? await Task.sleep(for: .seconds(1.5))
            report("after seek 3s", c, engine)
            exit(0)
        }
    }

    private static func report(_ label: String, _ c: AppController, _ e: PlaybackEngine) {
        let s = e.stats
        var px = "n/a"
        if let tex = e.lastRenderedTexture, tex.storageMode != .private, tex.pixelFormat == .rgba16Float {
            var bytes = [UInt16](repeating: 0, count: 4)
            tex.getBytes(&bytes, bytesPerRow: 8, from: MTLRegionMake2D(tex.width / 2, tex.height / 2, 1, 1), mipmapLevel: 0)
            px = "\(tex.width)x\(tex.height) center=\(bytes.map { Float16(bitPattern: $0) })"
        } else if let tex = e.lastRenderedTexture {
            px = "\(tex.width)x\(tex.height) storage=\(tex.storageMode.rawValue)"
        }
        let layer = c.panels.viewer.metalLayer
        NSLog("PLAYTEST [\(label)] presented=\(s.presentedFrames) dropped=\(s.droppedFrames) enginePos=\(e.position.value)/\(e.position.timescale) rate=\(e.rate.num)/\(e.rate.den) playhead=\(c.session.playhead.value)/\(c.session.playhead.timescale) rendered=\(px) layer=\(String(describing: layer?.drawableSize)) viewerFrame=\(c.panels.viewer.frame) window=\(c.panels.viewer.window != nil)")
    }
}
