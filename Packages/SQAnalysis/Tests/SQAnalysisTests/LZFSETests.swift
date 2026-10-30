import Foundation
import Testing
@testable import SQAnalysis

/// Fixtures were written by Apple's `NSData.compressed(using: .lzfse)` (what the Mac matte store does): a 24 x 24 disc
/// (LZVN block, `bvxn`) and an 80 x 80 disc (LZFSE block with FSE tables, `bvx2`).
enum MacMatteFixture {
    static func disc(_ w: Int, _ h: Int) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let dx = Double(x) - Double(w) / 2, dy = Double(y) - Double(h) / 2
                let d = (dx * dx + dy * dy).squareRoot(), r = Double(w) / 3
                b[y * w + x] = UInt8(max(0, min(255, (r - d) * 40)))
            }
        }
        return b
    }
    static let small = Data(base64Encoded: "YnZ4bkACAACrAAAAaAEA8GjoDxwlKCUcDwD69OwHHzNDTFBMQzMfBwD68ewHJT9WaHR4dGhWPyU4GfLuHz9deI2boJuNeF0/HwD57g8zVniWr8HIwa+WeFYzOGTgABxDaI2vzubw5s6vjWhDHAAoAeAAJUx0m8Hm////5sGbdEwlAPjmKFB4oMjwABjm8MigeFAo+Tgw/jhg/jiQ/jjA/jjw/zkg/jlQ/zgB8D7hAAYAAAAAAAAAYnZ4JA==")!
    static let large = Data(base64Encoded: "YnZ4MgAZAADgAQAYAFcAUCDQkEQY0wBg0AAAAB38QARfgMDac6sBMQjgQARkfAHXvgavAQAAADCBckrvOu8u5sXFRS+OLi4KAAAAAAC8A5MJTOYJcMARHAFnHBxxBsABcAAHBxzwAjAALi7gggvg8uLiHgAu4OLiErgALoALLi4ALi4v4JLrCcAFXMIFcAEXwMUFlxdwwQXAJZcTgIuLS4ALBlzAJcAlAJdwwQWXk4tL4AIAuOCCCy7g4gLggqsLuIOrCXABEwC4nEyACfAIAAAAqlqz2bjAHgTrO/rQXxZoeYfdfYDbgLzi0/jI/gqPmiePxm8F5Mn6d2zxUnQJ+T1Pr2TcXGd4gUF4vai196FUImcHud5XNvN2yoRa2zXhGi95yrrUxShPCpnBU8JGLPcO3ujdUIWbdNnkGNiYynRaTVXN8WPVD1Ek70vmIK4wUKKJZ5jjeF0QXDEXzy3TGzf0yHRq7OHJCwcc4n9T9F2++Bq/TnPyKkSA/Kl69b6iPjSqzsz2uX0FvhExypUjwQpQjeyKCOjedRxUoLhoJQBthi6c9DkVp/0wevTnZyScQ0qG4DxU3lYnIz7psBpjZWggy40sBgtYXsI5Mh1ZZMvfLnTiubI6wdSPojdNHOv5i4BeOyai2TOcFIeBV400OEEoBSgw535FyuKa93aPmyWGFvGGc8BLKr0Jm+zz2u5gJXbjROdBC0cwUPfO4V80m+pmeBEl8YRDQLlhJ2aEfDJW9ohjDu2S6vADz2KAR5MfODVe0D+nPK4vWUPAqj2wLwAAAAAAAAAAAJBWQCIGip+Q/hoTpBXPKiOjMyJuM0IyZohQzAj5mBGiIiOkREYICIyQFRkhxjFCYmeEcIsR8pkRoocR0ocRAoMRMpMRYo8RksQIoTFCljBCRDBCfoyYGOlBsSADiAXvHpIkXChqrOx60gc54SPSjw+pmeB0tx5nRy01dPfZMJ8fEXoKY5oMLGw4/qDuQvQo6DA7j4FzHfWYYokwfWcTuUPMItjZtOjnBW43XtIEF49wVDdRptpM+8Rnugn/Jj8NfDz+CIh+BLpKg3didngk")!

    /// A Mac `.sqmatte` file (SQMT, version 2) with the given stored frames.
    static func file(_ frames: [(pts: Double, w: Int, h: Int, stored: Data)]) -> Data {
        var out = Data("SQMT".utf8)
        func put<T>(_ v: T) { withUnsafeBytes(of: v) { out.append(contentsOf: $0) } }
        put(UInt32(2)); put(UInt32(frames.count))
        for f in frames { put(f.pts); put(UInt32(f.w)); put(UInt32(f.h)); put(UInt32(f.stored.count)); out.append(f.stored) }
        return out
    }
}

@Suite struct LZFSETests {
    @Test func decodesAnLZVNBlockWrittenOnTheMac() {
        #expect(LZFSE.decode(MacMatteFixture.small, size: 24 * 24) == Data(MacMatteFixture.disc(24, 24)))
    }

    @Test func decodesAnLZFSEBlockWithFSETablesWrittenOnTheMac() {
        #expect(LZFSE.decode(MacMatteFixture.large, size: 80 * 80) == Data(MacMatteFixture.disc(80, 80)))
    }

    @Test func damagedOrWrongSizedDataIsRefused() {
        #expect(LZFSE.decode(MacMatteFixture.large, size: 80 * 80 + 1) == nil)
        #expect(LZFSE.decode(Data(MacMatteFixture.large.prefix(100)), size: 80 * 80) == nil)
        #expect(LZFSE.decode(Data(), size: 4) == nil)
        #expect(LZFSE.decode(Data([1, 2, 3, 4, 5]), size: 16) == nil)
    }

    @Test func aMacCacheFileWithCompressedFramesLoads() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sqmatte-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let raw = Data(MacMatteFixture.disc(24, 24))     // a raw frame sits next to the compressed ones
        let file = MacMatteFixture.file([(1.0, 24, 24, MacMatteFixture.small), (1.04, 80, 80, MacMatteFixture.large),
                                         (1.08, 24, 24, raw), (1.12, 80, 80, Data([9, 9, 9]))])
        try file.write(to: dir.appendingPathComponent("mac.sqmatte"))
        let store = FrameMatteStore(directory: dir)
        #expect(store.times(key: "mac") == [1.0, 1.04, 1.08])        // the damaged frame alone is dropped
        let a = try #require(store.matte(key: "mac", pts: 1.0)), b = try #require(store.matte(key: "mac", pts: 1.04))
        #expect(a.values == MacMatteFixture.disc(24, 24).map { Float($0) / 255 })
        #expect(b.values == MacMatteFixture.disc(80, 80).map { Float($0) / 255 })
    }
}
