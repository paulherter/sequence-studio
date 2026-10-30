import Testing
import Foundation
import SQCore
import SQMedia
@testable import SQPlayback

/// Scrubbing over a tone clip sounds the tone (the scrub mixer opens the same synthetic source as playback). Headless: asserts buffers.
@Suite struct ScrubToneTests {
    private func render(_ v: ScrubVoice, _ frames: Int) -> [Float] {
        let l = UnsafeMutablePointer<Float>.allocate(capacity: frames), r = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        defer { l.deallocate(); r.deallocate() }
        _ = v.render(left: l, right: r, count: frames)
        return Array(UnsafeBufferPointer(start: l, count: frames))
    }

    @Test func scrubbingOverAToneClipPlaysTheTone() throws {
        var p = Project(name: "P", timelines: [Timeline(name: "T", frameDuration: Time(1, 30), tracks: [Track(kind: .audio)])])
        let tl = p.timelines[0]
        let spec = ToneSpec(frequencyHz: 1000, levelDB: -6)
        try p.addToneClip(spec, in: tl.id, at: .zero, track: tl.tracks[0].id, duration: Time(4, 1))
        let s = ScrubAudio(resolver: { _ in throw CocoaError(.fileNoSuchFile) }, inline: true)
        s.setTimeline(p.timelines[0], sequences: [:])
        s.begin(at: Time(48_000, 48_000), hostNanos: 0)
        var out: [Float] = []
        for k in 1...10 {
            s.scrub(to: Time(48_000 + Int64(k) * 400, 48_000), hostNanos: Int64(k) * 8_000_000)
            out += render(s.voice, 384)
        }
        let amp = Float(pow(10.0, -6.0 / 20))
        let peak = out.map { abs($0) }.max() ?? 0
        #expect(peak > amp * 0.9 && peak <= amp + 1e-4)
        // Frequency from rising zero crossings over the settled part: 1 kHz at 48 kHz = 48 samples per period.
        let body = Array(out[1000...])
        let rises = zip(body, body.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
        let seconds = Double(body.count) / 48_000
        #expect(abs(Double(rises) / seconds - 1000) < 100)
    }
}
