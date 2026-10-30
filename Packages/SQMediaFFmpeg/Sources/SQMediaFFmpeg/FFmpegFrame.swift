import Foundation
import CSQFFmpeg
import SQCore
import SQFrame

/// `SQFrameStorage` of a decoded FFmpeg picture: a reference to the AVFrame. A hardware frame is a slice of a D3D11
/// texture array owned by the decoder's pool (the slice returns to the pool when the last reference goes); a software
/// frame holds its pixels in memory. `download()` gives the pixels in the frame's `SQFramePixelFormat` layout
/// (NV12 or P010, planes packed).
public final class FFmpegFrame: SQFrameStorage, @unchecked Sendable {
    private let handle: OpaquePointer
    public let isHardware: Bool
    /// `ID3D11Texture2D*` of a hardware frame (nil for software frames). Valid while this object lives.
    public let d3d11Texture: UnsafeMutableRawPointer?
    /// Array slice of `d3d11Texture`.
    public let textureIndex: Int
    let ptsTicks: Int64
    let width: Int, height: Int
    /// AVPixelFormat of the pixels (NV12, P010, YUV420P...).
    let sourcePixelFormat: Int32

    /// Takes ownership of an `SQFFFrame*`.
    init(handle: OpaquePointer) {
        self.handle = handle
        var info = SQFFFrameInfo()
        sq_frame_info(handle, &info)
        isHardware = info.hardware != 0
        d3d11Texture = info.texture
        textureIndex = Int(info.textureIndex)
        ptsTicks = info.pts
        width = Int(info.width); height = Int(info.height)
        sourcePixelFormat = info.swFormat
    }

    deinit { sq_frame_free(handle) }

    /// Pixels in the frame's layout (a GPU copy for hardware frames). Blocking.
    public func download() throws -> [UInt8] {
        let size = Int(sq_frame_download_size(handle))
        guard size > 0 else { throw FFmpegError.failed("frame size", Int32(size)) }
        var out = [UInt8](repeating: 0, count: size)
        let r = out.withUnsafeMutableBufferPointer { sq_frame_download(handle, $0.baseAddress, Int32(size)) }
        guard r == 0 else { throw FFmpegError.failed("frame download", r) }
        return out
    }

    /// Pixels in the same layout, box-reduced by `divisor` (1, 2, 4) in one pass on `threads` threads (no zero fill, no
    /// full-size copy first); nil when this frame's size or format has no such path (use `download()`). Blocking.
    public func download(divisor: Int, threads: Int = 8) throws -> (bytes: [UInt8], width: Int, height: Int)? {
        var w: Int32 = 0, h: Int32 = 0
        let size = Int(sq_frame_download_reduced_size(handle, Int32(divisor), &w, &h))
        guard size > 0 else { return nil }
        var r: Int32 = 0
        let out = [UInt8](unsafeUninitializedCapacity: size) { buf, n in
            r = sq_frame_download_reduced(handle, Int32(divisor), Int32(threads), buf.baseAddress, Int32(size))
            n = size
        }
        if r == 1 { return nil }   // not this format
        guard r == 0 else { throw FFmpegError.failed("frame download", r) }
        return (out, Int(w), Int(h))
    }
}

/// Pixels in memory (frame sources and tests on Windows): planes packed in the `SQFrame`'s pixel format layout.
public final class MemoryFrame: SQFrameStorage, @unchecked Sendable {
    public let bytes: [UInt8]
    /// Bytes per row of the first plane.
    public let bytesPerRow: Int
    public init(bytes: [UInt8], bytesPerRow: Int) { self.bytes = bytes; self.bytesPerRow = bytesPerRow }
}

public enum FFmpegError: Error, LocalizedError, Sendable, Equatable, CustomStringConvertible {
    case failed(String, Int32)
    case message(String)
    /// The text the status line and dialogs show (without it they print "The operation could not be completed. (... error 1.)").
    public var errorDescription: String? { description }
    public var description: String {
        switch self {
        case .failed(let what, let code): "\(what) failed (\(code))"
        case .message(let m): m
        }
    }

    /// The C side's error text, or the code.
    static func from(_ what: String, _ code: Int32, _ err: [CChar]) -> FFmpegError {
        let text = String(decoding: err.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return text.isEmpty ? .failed(what, code) : .message("\(what): \(text)")
    }
}
