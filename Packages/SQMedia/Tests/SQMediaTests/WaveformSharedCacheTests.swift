import Foundation
import Testing
@testable import SQMedia

@Suite(.serialized) struct WaveformSharedCacheTests {
    @Test func sharedCacheFollowsConfiguredDirectory() {
        defer { WaveformDiskCache.configureShared(directory: nil) }
        let dir = URL(fileURLWithPath: "/Volumes/Fast/Waveforms", isDirectory: true)
        WaveformDiskCache.configureShared(directory: dir)
        #expect(WaveformDiskCache.shared?.directory == dir)
        WaveformDiskCache.configureShared(directory: nil)
        #expect(WaveformDiskCache.shared?.directory == WaveformDiskCache.defaultDirectory)
    }
}
