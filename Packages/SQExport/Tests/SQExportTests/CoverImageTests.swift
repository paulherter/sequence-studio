import CoreVideo
import Foundation
import Testing
import SQCore
@testable import SQExport

@Suite struct CoverImageTests {
    private func buffer(_ w: Int, _ h: Int) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        let b = pb!
        CVPixelBufferLockBaseAddress(b, [])
        memset(CVPixelBufferGetBaseAddress(b), 0x80, CVPixelBufferGetBytesPerRow(b) * h)
        CVPixelBufferUnlockBaseAddress(b, [])
        return b
    }

    @Test func settingsDefaultToOffAndRoundTrip() throws {
        var s = ExportSettings()
        #expect(s.coverImage == nil && s.coverTime == nil)
        s.coverImage = .jpg; s.coverTime = Time(5, 1)
        let back = try JSONDecoder().decode(ExportSettings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
    }
    @Test func oldSettingsWithoutCoverKeysDecode() throws {
        let data = try JSONEncoder().encode(ExportSettings())
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["coverImage"] == nil && obj["coverTime"] == nil)
        #expect(try JSONDecoder().decode(ExportSettings.self, from: data).coverImage == nil)
    }
    @Test func writesPNGAndJPG() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cover-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for f in CoverImageFormat.allCases {
            let url = dir.appendingPathComponent("c.\(f.fileExtension)")
            try CoverImageWriter.write(buffer(64, 36), format: f, to: url)
            let d = try Data(contentsOf: url)
            switch f {
            case .png: #expect(d.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
            case .jpg: #expect(d.prefix(3) == Data([0xFF, 0xD8, 0xFF]))
            }
        }
    }
}
