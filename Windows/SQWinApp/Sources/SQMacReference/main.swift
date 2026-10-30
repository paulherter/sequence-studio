import CoreMedia
import CoreVideo
import Foundation
import SQCore
import SQDrawEditor
import SQDrawKit
import SQEditorSession
import SQExport
import SQMedia
import SQPlayback

// The Mac side of the Windows app comparisons (scripts/win-app.sh "compare"): builds the same SampleProject from the
// same file and renders sequence frame N through the Mac pipeline (TimelineFrameSource, Metal compositor).
// No editor shot: the PC draws the full shell (AppController, Windows only), the old bare EditorScreen here compared
// two different layouts (10.8 dB). The editor is checked by the PC's own GPU vs software render ("ui gpu vs
// software") and the shared UI shots against the Mac app.
//   SQMacReference <sample.mp4> <frame N> <out dir>   -> mac-frame.rgba(.png)
//   SQMacReference --project <x.sqproj> <frame N> <out dir>   the project's first sequence through the Mac export path
//                                                            (ExportSourceBuilder, grades and color management as the app)
setvbuf(stdout, nil, _IONBF, 0)
let args = CommandLine.arguments
func rgba(_ buf: CVPixelBuffer) -> RGBAImage {
    CVPixelBufferLockBaseAddress(buf, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
    let w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf), stride = CVPixelBufferGetBytesPerRow(buf)
    let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
    var px = [UInt8](repeating: 255, count: w * h * 4)
    for y in 0..<h {
        for x in 0..<w {   // BGRA -> RGBA
            let s = y * stride + x * 4, d = (y * w + x) * 4
            px[d] = base[s + 2]; px[d + 1] = base[s + 1]; px[d + 2] = base[s]
        }
    }
    return RGBAImage(width: w, height: h, pixels: px)
}
if args.count >= 5, args[1] == "--project", let n = Int(args[3]) {
    do {
        let project = try ProjectFile.read(from: URL(fileURLWithPath: args[2]))
        let timeline = project.timelines[0]
        let resolver = ProjectMediaResolver()
        resolver.setProjectFolder(URL(fileURLWithPath: args[2]).deletingLastPathComponent())
        resolver.update(project.media)
        let offline = project.media.filter { resolver.isOffline($0.id) }.count
        var settings = ExportSettings()
        settings.video.width = timeline.format.width; settings.video.height = timeline.format.height
        settings.video.frameDuration = timeline.format.frameDuration
        let sources = try ExportSourceBuilder.make(timeline: timeline, sequences: Dictionary(uniqueKeysWithValues: project.timelines.map { ($0.id, $0) }),
                                                   settings: settings, resolver: resolver, pixelFormat: .bgra8)
        let frame = rgba(try await sources.video.frame(at: n))
        let out = URL(fileURLWithPath: args[4])
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try Data(frame.pixels).write(to: out.appendingPathComponent("mac-frame.rgba"))
        try PNGWriter.write(frame, to: out.appendingPathComponent("mac-frame.png"))
        print("mac project frame \(n): \(frame.width)x\(frame.height), \(offline) of \(project.media.count) media offline")
        exit(0)
    } catch { print("error: \(error)"); exit(1) }
}
guard args.count >= 4, let n = Int(args[2]) else { print("error: SQMacReference <media> <frame> <outdir>"); exit(1) }
let mediaURL = URL(fileURLWithPath: args[1]), outDir = URL(fileURLWithPath: args[3])

do {
    let demuxer = try await AVDemuxer(url: mediaURL)
    let dims = CMVideoFormatDescriptionGetDimensions(demuxer.formatDescription)
    let e = demuxer.index.entries
    let fd = e.count > 1 ? e[1].pts - e[0].pts : Time(1, 25)
    let size = (try FileManager.default.attributesOfItem(atPath: mediaURL.path)[.size] as? NSNumber)?.int64Value ?? 0
    let project = SampleProject.make(mediaPath: mediaURL.path, fileSize: size, width: Int(dims.width),
                                     height: Int(dims.height), frameDuration: fd, frames: Int64(e.count),
                                     title: ProcessInfo.processInfo.environment["SQ_SAMPLE_TITLE"] == "1" ? try SampleTitle.ref() : nil)
    let timeline = project.timelines[0]
    let media = project.media[0].id
    let provider = DecoderFrameProvider(resolver: StaticMediaResolver(demuxers: [media: demuxer]))
    let source = try TimelineFrameSource(timeline: timeline, provider: provider, width: Int(dims.width),
                                         height: Int(dims.height), frameDuration: fd, frameCount: n + 1)
    let frame = rgba(try await source.frame(at: n))
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    try Data(frame.pixels).write(to: outDir.appendingPathComponent("mac-frame.rgba"))
    try PNGWriter.write(frame, to: outDir.appendingPathComponent("mac-frame.png"))
    print("mac frame \(n): \(frame.width)x\(frame.height)")

} catch {
    print("error: \(error)")
    exit(1)
}
