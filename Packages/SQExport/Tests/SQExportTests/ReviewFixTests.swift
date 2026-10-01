import Testing
import AVFoundation
import Foundation
import SQCore
@testable import SQExport

@Suite struct ReviewFixTests {
    // X1
    @Test func audioShorterThanVideoFinishes() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("short.mp4")
        var s = smallSettings(codec: .h264)
        s.audio.enabled = true
        let settings = s
        let v = TestPatternSource(width: 64, height: 112, frameCount: 90, frameDuration: Time(1, 30))   // 3 s
        let a = SineAudioSource(sampleRate: 48_000, channels: 2, duration: Time(3, 10), frequency: 440)   // 0.3 s
        let finished = try await withThrowingTaskGroup(of: Bool.self) { g in
            g.addTask { try await ExportWriter.export(video: v, audio: a, settings: settings, to: url, progress: { _ in }); return true }
            g.addTask { try await Task.sleep(for: .seconds(60)); return false }
            let r = try await g.next() ?? false
            g.cancelAll()
            return r
        }
        #expect(finished)
        #expect(try await readVideo(url).frames == 90)
    }

    // X2
    @Test func uniqueNamesAreCaseInsensitive() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let q = ExportQueue()
        func j(_ n: String) -> ExportJob {
            ExportJob(name: n, settings: smallSettings(codec: .h264), outputDirectory: dir) {
                ExportSources(video: TestPatternSource(width: 64, height: 112, frameCount: 3, frameDuration: Time(1, 30)))
            }
        }
        let a = await q.enqueue(j("Cut")), b = await q.enqueue(j("cut"))
        let ua = try #require(await q.status(a)?.outputURL), ub = try #require(await q.status(b)?.outputURL)
        #expect(ua.path.lowercased() != ub.path.lowercased())
        await q.runAll()
        #expect(FileManager.default.fileExists(atPath: ua.path))
        #expect(FileManager.default.fileExists(atPath: ub.path))
    }

    // X3
    @Test func staleSidecarIsNotOverwritten() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let stale = dir.appendingPathComponent("Clip.srt")
        try "stale".write(to: stale, atomically: true, encoding: .utf8)
        var s = smallSettings(codec: .h264); s.captions = .sidecarSRT
        let q = ExportQueue()
        let id = await q.enqueue(ExportJob(name: "Clip", settings: s, outputDirectory: dir) {
            ExportSources(video: TestPatternSource(width: 64, height: 112, frameCount: 3, frameDuration: Time(1, 30)),
                          captions: [SRTCue(lines: ["Hi"], range: TimeRange(start: .zero, end: Time(1, 10)))])
        })
        await q.runAll()
        let st = try #require(await q.status(id))
        #expect(try String(contentsOf: stale, encoding: .utf8) == "stale")
        #expect(st.outputURL.lastPathComponent == "Clip 2.mp4")
        #expect(st.sidecarURL?.lastPathComponent == "Clip 2.srt")
    }

    @Test func sidecarFailureKeepsFinishedVideo() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        var s = smallSettings(codec: .h264); s.captions = .sidecarSRT
        let q = ExportQueue()
        // A directory where the .srt should go makes the sidecar write fail.
        let blocker = dir.appendingPathComponent("Clip.srt")
        let id = await q.enqueue(ExportJob(name: "Clip", settings: s, outputDirectory: dir) {
            try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
            return ExportSources(video: TestPatternSource(width: 64, height: 112, frameCount: 3, frameDuration: Time(1, 30)),
                                 captions: [SRTCue(lines: ["Hi"], range: TimeRange(start: .zero, end: Time(1, 10)))])
        })
        await q.runAll()
        let st = try #require(await q.status(id))
        guard case .done(let url) = st.state else { Issue.record("not done: \(st.state)"); return }
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(st.sidecarURL == nil)
        #expect(st.sidecarError != nil)
    }

    // X4
    @Test func fullyNegativeCueIsDropped() {
        let c = SRTCue(lines: ["neg"], range: TimeRange(start: Time(-5, 1), end: Time(-2, 1)))
        #expect(SRTWriter.render([c], range: .entireSequence) == "")
        let straddle = SRTCue(lines: ["x"], range: TimeRange(start: Time(-1, 1), end: Time(1, 1)))
        #expect(SRTWriter.render([straddle], range: .entireSequence) == "1\r\n00:00:00,000 --> 00:00:01,000\r\nx\r\n\r\n")
    }

    // Compat
    @Test func loudnessTargetShim() throws {
        var a = AudioSettings()
        #expect(a.loudnessTarget == nil)
        a.loudnessTarget = -16
        #expect(a.loudness == LoudnessNormalization(targetLUFS: -16, truePeakCeilingDB: -1))
        #expect(a.loudnessTarget == -16)
        a.loudness = LoudnessNormalization(targetLUFS: -14, truePeakCeilingDB: -2)
        a.loudnessTarget = -23
        #expect(a.loudness == LoudnessNormalization(targetLUFS: -23, truePeakCeilingDB: -2))   // keeps ceiling
        a.loudness = LoudnessNormalization(targetLUFS: -13.6)
        #expect(a.loudnessTarget == -14)
        a.loudnessTarget = nil
        #expect(a.loudness == nil)
        a.loudnessTarget = -14
        let json = String(decoding: try JSONEncoder().encode(a), as: UTF8.self)
        #expect(!json.contains("loudnessTarget"))
    }
}
