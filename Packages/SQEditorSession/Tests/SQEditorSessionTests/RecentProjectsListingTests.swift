import Testing
import Foundation
@testable import SQEditorSession

@Suite struct RecentProjectsListingTests {
    private func e(_ n: String, _ t: TimeInterval) -> RecentProjects.Entry {
        .init(path: "/p/\(n).sqproj", name: n, opened: Date(timeIntervalSince1970: t))
    }
    private var all: [RecentProjects.Entry] { [e("Clip 10", 30), e("alpha", 20), e("Clip 2", 10)] }

    @Test func emptyQueryKeepsOrder() {
        #expect(RecentProjects.listing(all, query: "  ", order: .opened) { _ in nil }.map(\.name) == ["Clip 10", "alpha", "Clip 2"])
    }
    @Test func queryIsCaseInsensitiveAndTrimmed() {
        #expect(RecentProjects.listing(all, query: " CLIP ", order: .opened) { _ in nil }.map(\.name) == ["Clip 10", "Clip 2"])
        #expect(RecentProjects.listing(all, query: "zzz", order: .opened) { _ in nil }.isEmpty)
    }
    @Test func nameOrderIsNumericAware() {
        #expect(RecentProjects.listing(all, query: "", order: .name) { _ in nil }.map(\.name) == ["alpha", "Clip 2", "Clip 10"])
    }
    @Test func sizeOrderLargestFirstUnknownLastTiesByRecency() {
        let px: [String: Int] = ["/p/alpha.sqproj": 100, "/p/Clip 2.sqproj": 100]
        let r = RecentProjects.listing(all, query: "", order: .size) { px[$0] }
        #expect(r.map(\.name) == ["alpha", "Clip 2", "Clip 10"])
    }
}
