import CSQWin
import Foundation

// Usage: SQWinSpike [--video file.mp4] [--sw] [--seconds N] [--shot out.png] [--resize-test]
let args = Array(CommandLine.arguments.dropFirst())
func value(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}
var opts = GPUWindow.Options()
opts.seconds = Double(value("--seconds") ?? "") ?? 0
opts.screenshot = value("--shot")
opts.resizeTest = args.contains("--resize-test")
opts.shaderDir = value("--shaders")
opts.timeline = args.contains("--timeline")
opts.dragTest = args.contains("--drag-test")
let gradeTest = args.contains("--grade-test")  // 256x256 test image through the Slang HLSL, 1:1

var decoded = SQDecoded()
if let video = value("--video") {
    var err = [CChar](repeating: 0, count: 256)
    if sq_decode_first_frame(video, args.contains("--sw") ? 0 : 1, &decoded, &err, 256) == 0 {
        print("decoder: \(withUnsafePointer(to: &decoded.decoder) { $0.withMemoryRebound(to: CChar.self, capacity: 96) { String(cString: $0) } })")
        print(String(format: "frame %dx%d: open %.1f ms, first frame %.1f ms, convert %.1f ms",
                     decoded.width, decoded.height, decoded.openMs, decoded.firstFrameMs, decoded.convertMs))
        opts.frame = decoded
    } else {
        print("decode failed: \(String(cString: err))")
    }
}

if gradeTest {  // mirrored in SQGradeMac
    var px = [UInt8](repeating: 255, count: 256 * 256 * 4)
    for y in 0..<256 { for x in 0..<256 {
        let i = (y * 256 + x) * 4
        px[i] = UInt8(x); px[i + 1] = UInt8(y); px[i + 2] = (((x >> 5) ^ (y >> 5)) & 1) == 1 ? 220 : 40
    } }
    decoded.rgba = UnsafeMutablePointer<UInt8>.allocate(capacity: px.count)
    decoded.rgba.initialize(from: px, count: px.count)
    decoded.width = 256; decoded.height = 256
    opts.frame = decoded
}
let size = gradeTest ? (256, 256) : opts.timeline ? (960, 300) : (960, 540)
guard let window = GPUWindow(title: "Sequence Studio Windows spike", width: Int32(size.0), height: Int32(size.1)) else {
    print("window failed")
    exit(1)
}
let code = window.run(opts)
if !gradeTest { sq_decoded_free(&decoded) }
exit(code)
