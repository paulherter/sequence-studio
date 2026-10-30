import CoreMedia
import Foundation
import Testing
import SQCore
import SQMedia
@testable import SQEditorSession

@Suite struct ProxyLookupBoxTests {
    /// 2026-10-29 crash: every read of the lookup (each proxyDemuxer call) wrote a re-thunked closure back into the Mutex; thousands of reads stacked thousands of thunks.
    @Test func readingTheLookupDoesNotGrowTheCallChain() {
        let resolver = ProjectMediaResolver(demuxer: { _ in throw CancellationError() })
        let target = URL(fileURLWithPath: "/tmp/x")
        resolver.setProxyLookup { _, _ in target }
        for _ in 0..<20_000 {
            _ = resolver.currentProxyLookup
        }
        #expect(resolver.currentProxyLookup?(UUID(), "p") == target)    // overflowed the stack when each round added thunks
    }
}
