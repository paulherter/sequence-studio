import CoreVideo
import Foundation

/// Stamps a frame number into a pixel buffer as 16 black/white 16x16 blocks (bit 0 = leftmost) in the top-left corner,
/// and reads it back from decoded buffers (BGRA, 420v/420f, x420/xf20). Blocks are macroblock aligned, so they survive
/// H.264/HEVC compression; reading thresholds the mean luma of each block centre at mid-level.
public enum FrameStamp {
    public static let bitCount = 16
    public static let blockSize = 16
    public static let minimumWidth = bitCount * blockSize
    public static let minimumHeight = blockSize
    public static let supportedFormats: [OSType] = [
        kCVPixelFormatType_32BGRA,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
    ]

    // MARK: luma model

    private enum Layout { case bgra, bi8(video: Bool), bi10(video: Bool) }

    private static func layout(_ format: OSType) -> Layout? {
        switch format {
        case kCVPixelFormatType_32BGRA: .bgra
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: .bi8(video: true)
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: .bi8(video: false)
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange: .bi10(video: true)
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange: .bi10(video: false)
        default: nil
        }
    }

    /// Encodes normalised luma 0...1 into the buffer's luma code value.
    private static func lumaCode(_ v: Double, _ l: Layout) -> UInt16 {
        switch l {
        case .bgra: UInt16((v * 255).rounded())
        case .bi8(let video): UInt16(video ? (16 + v * 219).rounded() : (v * 255).rounded())
        case .bi10(let video): UInt16((video ? (64 + v * 876) : (v * 1023)).rounded()) << 6
        }
    }

    private static func lumaNormalised(_ code: Double, _ l: Layout) -> Double {
        switch l {
        case .bgra: code / 255
        case .bi8(let video): video ? (code - 16) / 219 : code / 255
        case .bi10(let video): video ? ((code / 64) - 64) / 876 : (code / 64) / 1023
        }
    }

    // MARK: writing

    /// Creates a buffer in `format` filled with a non-flat neutral background (varies with `frame`), then stamps `frame`.
    public static func makePixelBuffer(width: Int, height: Int, format: OSType, frame: Int) -> CVPixelBuffer? {
        precondition(width >= minimumWidth && height >= minimumHeight, "frame too small for stamp")
        guard let l = layout(format) else { return nil }
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]]
        var out: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, width, height, format, attrs as CFDictionary, &out) == kCVReturnSuccess,
              let pb = out else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        // Background below the stamp row: gentle gradient with a drifting band, luma 0.3...0.7 (never near 0/1 edges).
        func bg(_ x: Int, _ y: Int) -> Double { 0.3 + 0.25 * Double(x) / Double(width) + 0.15 * Double((y + frame * 3) % 48) / 48 }
        switch l {
        case .bgra:
            let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
            let bpr = CVPixelBufferGetBytesPerRow(pb)
            for y in 0..<height { for x in 0..<width {
                let c = UInt8(lumaCode(bg(x, y), l)); let p = base + y * bpr + x * 4
                p[0] = c; p[1] = c; p[2] = c; p[3] = 255
            } }
        case .bi8:
            let yp = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
            let ybpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            for y in 0..<height { for x in 0..<width { yp[y * ybpr + x] = UInt8(lumaCode(bg(x, y), l)) } }
            fillChroma8(pb, height: height)
        case .bi10:
            let yp = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt16.self)
            let ybpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0) / 2
            for y in 0..<height { for x in 0..<width { yp[y * ybpr + x] = lumaCode(bg(x, y), l) } }
            let cp = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!.assumingMemoryBound(to: UInt16.self)
            let cbpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 1) / 2
            for y in 0..<CVPixelBufferGetHeightOfPlane(pb, 1) { for x in 0..<CVPixelBufferGetWidthOfPlane(pb, 1) * 2 { cp[y * cbpr + x] = 512 << 6 } }
        }
        stampLocked(frame, pb, l)
        return pb
    }

    private static func fillChroma8(_ pb: CVPixelBuffer, height: Int) {
        let cp = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!.assumingMemoryBound(to: UInt8.self)
        let cbpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        for y in 0..<CVPixelBufferGetHeightOfPlane(pb, 1) { for x in 0..<CVPixelBufferGetWidthOfPlane(pb, 1) * 2 { cp[y * cbpr + x] = 128 } }
    }

    /// Stamps `frame` (0...65535) into an existing buffer of a supported format (overwrites the top-left 256x16 px).
    @discardableResult
    public static func stamp(_ frame: Int, into pb: CVPixelBuffer) -> Bool {
        guard (0..<(1 << bitCount)).contains(frame), let l = layout(CVPixelBufferGetPixelFormatType(pb)),
              CVPixelBufferGetWidth(pb) >= minimumWidth, CVPixelBufferGetHeight(pb) >= minimumHeight else { return false }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        stampLocked(frame, pb, l)
        return true
    }

    private static func stampLocked(_ frame: Int, _ pb: CVPixelBuffer, _ l: Layout) {
        for bit in 0..<bitCount {
            let code = lumaCode((frame >> bit) & 1 == 1 ? 1 : 0, l)
            for y in 0..<blockSize { for x in (bit * blockSize)..<((bit + 1) * blockSize) { put(pb, l, x, y, code) } }
        }
    }

    private static func put(_ pb: CVPixelBuffer, _ l: Layout, _ x: Int, _ y: Int, _ code: UInt16) {
        switch l {
        case .bgra:
            let p = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self) + y * CVPixelBufferGetBytesPerRow(pb) + x * 4
            p[0] = UInt8(code); p[1] = UInt8(code); p[2] = UInt8(code); p[3] = 255
        case .bi8:
            CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)[y * CVPixelBufferGetBytesPerRowOfPlane(pb, 0) + x] = UInt8(code)
        case .bi10:
            CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt16.self)[y * (CVPixelBufferGetBytesPerRowOfPlane(pb, 0) / 2) + x] = code
        }
    }

    // MARK: reading

    /// Reads the stamped frame number from a decoded buffer, or nil when the format is unsupported or any block is ambiguous.
    public static func read(_ pb: CVPixelBuffer) -> Int? {
        guard let l = layout(CVPixelBufferGetPixelFormatType(pb)),
              CVPixelBufferGetWidth(pb) >= minimumWidth, CVPixelBufferGetHeight(pb) >= minimumHeight else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        var value = 0
        for bit in 0..<bitCount {
            var sum = 0.0, n = 0.0
            for y in 4..<12 { for x in (bit * blockSize + 4)..<(bit * blockSize + 12) { sum += sample(pb, l, x, y); n += 1 } }
            let v = lumaNormalised(sum / n, l)
            if v > 0.3 && v < 0.7 { return nil }     // ambiguous
            if v >= 0.7 { value |= 1 << bit }
        }
        return value
    }

    private static func sample(_ pb: CVPixelBuffer, _ l: Layout, _ x: Int, _ y: Int) -> Double {
        switch l {
        case .bgra:
            let p = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self) + y * CVPixelBufferGetBytesPerRow(pb) + x * 4
            return 0.114 * Double(p[0]) + 0.587 * Double(p[1]) + 0.299 * Double(p[2])
        case .bi8:
            return Double(CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)[y * CVPixelBufferGetBytesPerRowOfPlane(pb, 0) + x])
        case .bi10:
            return Double(CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt16.self)[y * (CVPixelBufferGetBytesPerRowOfPlane(pb, 0) / 2) + x])
        }
    }
}
