import Foundation
import Testing
@testable import SQLibrary

@Suite(.serialized) struct PreviewCacheRootTests {
    @Test func appCacheFollowsConfiguredCacheFolder() {
        PreviewCache.configureCacheRoot(URL(fileURLWithPath: "/Volumes/Fast/C", isDirectory: true))
        defer { PreviewCache.configureCacheRoot(nil) }
        #expect(PreviewCache.appCache().root.path == "/Volumes/Fast/C/Previews")
        PreviewCache.configureCacheRoot(nil)
        #if os(Windows)
        #expect(PreviewCache.appCache().root.path.hasSuffix("/Sequence Studio/Previews"))
        #else
        #expect(PreviewCache.appCache().root.path.hasSuffix("Library/Caches/Sequence Studio/Previews"))
        #endif
    }
}
