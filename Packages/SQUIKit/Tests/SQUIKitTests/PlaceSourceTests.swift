import Testing
@testable import SQUIKit

@Suite struct PlaceSourceTests {
    @Test func sourceClipWinsOutsideTheProjectPanel() {
        #expect(PlaceSource.resolve(sourceLoaded: true, focus: .programMonitor, selectedMedia: 2, selectedSequences: 0) == .sourceMonitor)
        #expect(PlaceSource.resolve(sourceLoaded: true, focus: nil, selectedMedia: 0, selectedSequences: 0) == .sourceMonitor)
    }

    @Test func projectFocusUsesItsSelection() {
        #expect(PlaceSource.resolve(sourceLoaded: true, focus: .project, selectedMedia: 1, selectedSequences: 0) == .projectMedia)
        #expect(PlaceSource.resolve(sourceLoaded: true, focus: .project, selectedMedia: 0, selectedSequences: 1) == .projectSequences)
    }

    /// The menu used to look only at selected media: Insert was grayed out with a Source clip loaded and nothing selected,
    /// and with only a sequence selected, while the key worked.
    @Test func menuStateMatchesTheKey() {
        #expect(PlaceSource.resolve(sourceLoaded: false, focus: .timeline, selectedMedia: 0, selectedSequences: 1) == .projectSequences)
        #expect(PlaceSource.resolve(sourceLoaded: false, focus: .timeline, selectedMedia: 0, selectedSequences: 0) == .nothing)
        #expect(PlaceSource.resolve(sourceLoaded: true, focus: .project, selectedMedia: 0, selectedSequences: 0) == .sourceMonitor)
    }
}
