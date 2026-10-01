import AppKit
import Metal
import SQCore
import SQEditorUI
import SQPlayback
import SQText

/// Developer aids (no screenshots, results go to NSLog; the app quits when done).
///
/// - `SQ_TRANSCRIBE_TEST=<media file>`: imports the clip, places it, selects it, runs Transcribe (SpeechAnalyzer de-DE on the
///   clip's audio) through the Text panel's model, logs progress and the result, then Create Captions and the caption count.
/// - `SQ_TEXTTEST=1`: adds a text clip through the Type-tool path (`addTextClip` with a position), renders it in the real
///   engine and logs whether the picture contains text pixels around the expected position; also pans/zooms the monitor.
@MainActor
enum DevAidDrivers {
    static func runIfRequested(_ c: AppController) {
        let env = ProcessInfo.processInfo.environment
        if let path = env["SQ_TRANSCRIBE_TEST"] { runTranscribe(c, path: path) }
        if env["SQ_TEXTTEST"] == "1" { runTextTest(c) }
        ShellDevAids.runIfRequested(c)
    }

    private static func runTranscribe(_ c: AppController, path: String) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            await c.panels.projectModel.importFiles([URL(fileURLWithPath: path)])
            guard let m = c.session.project.media.first else { NSLog("TRANSCRIBE: import failed"); exit(2) }
            guard c.session.placeMedia([m.id], at: .zero, mode: .overwrite) else { NSLog("TRANSCRIBE: place failed"); exit(3) }
            guard let clip = c.session.activeTimeline?.tracks.flatMap(\.clips).first(where: { $0.kind == .video }) else {
                NSLog("TRANSCRIBE: no video clip"); exit(4)
            }
            c.session.select(clips: [clip.id])
            try? await Task.sleep(for: .seconds(0.5))
            guard let model = c.panels.textView.captionsModel(for: clip.id) else { NSLog("TRANSCRIBE: no model for the clip"); exit(5) }
            NSLog("TRANSCRIBE: source=\(model.sourceURL?.path ?? "nil") language=\(model.language) canTranscribe=\(model.canTranscribe)")
            let started = ContinuousClock.now
            model.transcribe()
            var last = ""
            while case .transcribing = model.state {
                let line = "\(model.state) note=\(model.statusNote ?? "-")"
                if line != last { NSLog("TRANSCRIBE: state \(line)"); last = line }
                try? await Task.sleep(for: .milliseconds(500))
                if ContinuousClock.now - started > .seconds(900) { NSLog("TRANSCRIBE: timeout"); exit(6) }
            }
            let took = ContinuousClock.now - started
            NSLog("TRANSCRIBE: final state \(model.state) in \(took)")
            guard model.state == .ready, let t = model.transcript else { exit(7) }
            NSLog("TRANSCRIBE: words=\(t.words.count) first=\(t.words.prefix(12).map(\.text).joined(separator: " "))")
            let captions = model.createCaptions()
            try? await Task.sleep(for: .seconds(0.3))
            let items = c.session.activeTimeline?.captionTracks.flatMap(\.items) ?? []
            NSLog("TRANSCRIBE: captions segmented=\(captions.count) on caption track=\(items.count) first=\(items.first?.lines.joined(separator: " / ") ?? "-")")
            exit(items.isEmpty ? 8 : 0)
        }
    }

    /// Private-storage textures need a blit: copies the rgba16Float frame into a shared buffer.
    private static func readback(_ tex: MTLTexture) -> [UInt16]? {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let buf = device.makeBuffer(length: tex.width * tex.height * 8, options: .storageModeShared),
              let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: tex, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: tex.width, height: tex.height, depth: 1), to: buf, destinationOffset: 0,
                  destinationBytesPerRow: tex.width * 8, destinationBytesPerImage: tex.width * tex.height * 8)
        blit.endEncoding()
        cb.commit(); cb.waitUntilCompleted()
        return Array(UnsafeBufferPointer(start: buf.contents().assumingMemoryBound(to: UInt16.self), count: tex.width * tex.height * 4))
    }

    private static func runTextTest(_ c: AppController) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard let engine = c.session.engine as? PlaybackEngine else { NSLog("TEXTTEST: stub engine"); exit(1) }
            var template = TextTemplateCatalog.all.first?.template ?? TextTemplate(name: "Text", text: "", style: TextStyle())
            template.text = "HHHH"; template.animation = nil; template.style.color = .white; template.style.size = 120
            let position = Vec2(300, -200)
            c.session.seek(to: Time(1, 1))
            guard let id = c.session.addTextClip(template: template, position: position) else { NSLog("TEXTTEST: add failed"); exit(2) }
            c.session.seek(to: Time(2, 1))   // the engine clamps seeks to the timeline length: seek again now that the clip exists
            try? await Task.sleep(for: .seconds(1))
            let fmt = c.session.activeTimeline?.format
            let w = fmt?.width ?? 1920, h = fmt?.height ?? 1080
            var lit = 0, total = 0
            if let tex = engine.lastRenderedTexture, tex.pixelFormat == .rgba16Float, let px = readback(tex) {
                let cx = tex.width / 2 + Int(position.x), cy = tex.height / 2 + Int(position.y)
                for y in max(0, cy - 120)..<min(tex.height, cy + 120) {
                    for x in max(0, cx - 250)..<min(tex.width, cx + 250) {
                        total += 1
                        if Float(Float16(bitPattern: px[(y * tex.width + x) * 4])) > 0.5 { lit += 1 }
                    }
                }
                var maxR: Float = 0
                for i in stride(from: 0, to: px.count, by: 4) { maxR = max(maxR, Float(Float16(bitPattern: px[i]))) }
                NSLog("TEXTTEST: presented=\(engine.stats.presentedFrames) maxR=\(maxR) position=\(engine.position.value)/\(engine.position.timescale)")
                NSLog("TEXTTEST: texture \(tex.width)x\(tex.height) sequence \(w)x\(h) lit pixels near the text=\(lit)/\(total)")
            } else {
                NSLog("TEXTTEST: no readable texture (storage=\(String(describing: engine.lastRenderedTexture?.storageMode.rawValue)))")
            }
            let target = c.panels.surface.overlay.mediaPixelSize
            NSLog("TEXTTEST: overlay size=\(String(describing: target)) clip=\(id)")
            // Monitor view: pinch-zoom 2x about the centre, then pan; the picture transform must not change.
            let before = c.session.activeTimeline?.tracks.flatMap(\.clips).first { $0.id == id }?.animation.position.value
            let m = c.panels.surface.mapping
            let z = m.zoomed(by: 2, about: CGPoint(x: m.viewSize.width / 2, y: m.viewSize.height / 2))
            c.panels.surface.onZoomGesture?(z)
            let z2 = c.panels.surface.mapping.panned(byViewDelta: CGSize(width: 30, height: 10))
            c.panels.surface.onZoomGesture?(z2)
            try? await Task.sleep(for: .seconds(0.5))
            let after = c.session.activeTimeline?.tracks.flatMap(\.clips).first { $0.id == id }?.animation.position.value
            NSLog("TEXTTEST: zoom=\(c.session.engine.viewerZoom) canvasRect=\(c.panels.surface.overlay.canvasRect) positionUnchanged=\(before == after)")
            exit(lit > 200 ? 0 : 3)
        }
    }
}
