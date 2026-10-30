#if canImport(CoreVideo)
import CoreVideo
import SQCore
import SQFrame
import SQFrameCoreVideo

// Mac conveniences: render inputs built from a CVPixelBuffer wrap it without copying (`SQFrame(pixelBuffer:)`). The
// stored types are `SQFrame` (Windows plan, seam 1); callers that already hold a `DecodedFrame` pass its `frame`.

public extension RenderLayer.Content {
    static func frame(_ pixelBuffer: CVPixelBuffer, colorHint: VideoTrackInfo) -> Self {
        .frame(SQFrame(pixelBuffer: pixelBuffer), colorHint: colorHint)
    }
    static func linearPremultiplied(_ pixelBuffer: CVPixelBuffer, width: Double, height: Double) -> Self {
        .linearPremultiplied(SQFrame(pixelBuffer: pixelBuffer, colorSpace: .linearRec709), width: width, height: height)
    }
}

public extension FrameBlend {
    init(next: CVPixelBuffer, weight: Float, flow: OpticalFlowRequest? = nil) {
        self.init(next: SQFrame(pixelBuffer: next), weight: weight, flow: flow)
    }
}

public extension TemporalFrames {
    init(filter: TemporalFilter, before: [CVPixelBuffer], after: [CVPixelBuffer] = []) {
        self.init(filter: filter, before: before.map { SQFrame(pixelBuffer: $0) }, after: after.map { SQFrame(pixelBuffer: $0) })
    }
}

public extension Compositor {
    func warmPlaneTextures(_ buffers: [CVPixelBuffer]) { warmPlaneTextures(buffers.map { SQFrame(pixelBuffer: $0) }) }
}
#endif
