import CLZFSE
import Foundation

/// LZFSE decoding that works on every platform (Apple's BSD-3 reference decoder, vendored as `CLZFSE`; docs/THIRD_PARTY.md).
/// The Mac Magic Mask cache stores its 8-bit frames LZFSE-compressed; Windows reads them through this.
public enum LZFSE {
    /// The `size` bytes `data` decodes to, or nil when it is damaged or decodes to another length.
    public static func decode(_ data: Data, size: Int) -> Data? {
        guard size > 0, !data.isEmpty else { return nil }
        var out = [UInt8](repeating: 0, count: size)
        let written = data.withUnsafeBytes { src -> Int in
            out.withUnsafeMutableBufferPointer { dst -> Int in
                guard let s = src.bindMemory(to: UInt8.self).baseAddress, let d = dst.baseAddress else { return 0 }
                return lzfse_decode_buffer(d, size, s, data.count, nil)
            }
        }
        // A full buffer is also what a longer stream returns, so only an exact fit counts.
        return written == size ? Data(out) : nil
    }
}
