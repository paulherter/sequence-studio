import AVFoundation
import CoreVideo

/// Trivial custom compositor: records when each frame request arrives, returns an empty output buffer.
final class SpikeCompositor: NSObject, AVVideoCompositing {
    nonisolated(unsafe) static var log: [(t: Double, wall: Double)] = []
    nonisolated(unsafe) static var srcFormat: OSType = 0
    nonisolated(unsafe) static var wantFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    static let lock = NSLock()
    static func reset() { lock.lock(); log = []; lock.unlock() }
    static func arrival(of t: Double, tol: Double) -> Double? {
        lock.lock(); defer { lock.unlock() }
        return log.first { abs($0.t - t) < tol }?.wall
    }
    static var count: Int { lock.lock(); defer { lock.unlock() }; return log.count }

    var sourcePixelBufferAttributes: [String: any Sendable]? { [kCVPixelBufferMetalCompatibilityKey as String: true, kCVPixelBufferPixelFormatTypeKey as String: Self.wantFormat] }
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferMetalCompatibilityKey as String: true, kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf]
    }
    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}
    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        let wall = nowMs()
        if let id = request.sourceTrackIDs.first?.int32Value, let src = request.sourceFrame(byTrackID: id) {
            Self.srcFormat = CVPixelBufferGetPixelFormatType(src)
        }
        Self.lock.lock(); Self.log.append((request.compositionTime.seconds, wall)); Self.lock.unlock()
        if let out = request.renderContext.newPixelBuffer() { request.finish(withComposedVideoFrame: out) }
        else { request.finishCancelledRequest() }
    }
}

func makeComposition(url: URL, info: ClipInfo) async throws -> (AVMutableComposition, AVMutableVideoComposition) {
    let asset = AVURLAsset(url: url)
    let src = try await asset.loadTracks(withMediaType: .video)[0]
    let comp = AVMutableComposition()
    let dur = try await asset.load(.duration)
    let track = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
    try track.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: src, at: .zero)
    let vc = AVMutableVideoComposition()
    vc.customVideoCompositorClass = SpikeCompositor.self
    vc.frameDuration = info.frameDuration.isValid ? info.frameDuration : CMTime(value: 1, timescale: 30)
    vc.renderSize = CGSize(width: info.width, height: info.height)
    let instr = AVMutableVideoCompositionInstruction()
    instr.timeRange = CMTimeRange(start: .zero, duration: dur)
    let li = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
    instr.layerInstructions = [li]
    vc.instructions = [instr]
    return (comp, vc)
}
