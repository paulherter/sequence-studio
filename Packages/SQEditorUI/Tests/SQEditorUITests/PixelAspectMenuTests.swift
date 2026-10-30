import Testing
import SQCore
@testable import SQEditorUI
@testable import SQInspectorUI

private func video(tag: PixelAspect = .square, override: PixelAspect? = nil) -> VideoTrackInfo {
    VideoTrackInfo(width: 1440, height: 1080, codec: "avc1", bitDepth: 8, chroma: "4:2:0", nominalFrameDuration: Time(1, 25),
                   isVariableFrameRate: false, pixelAspect: tag, pixelAspectOverride: override)
}

@Suite struct PixelAspectMenuTests {
    @Test func customRatioIsValidated() {
        #expect(PixelAspectMenu.aspect(fromRatio: 1) == .square)
        #expect(PixelAspectMenu.aspect(fromRatio: 2) == PixelAspect(2, 1))
        #expect(PixelAspectMenu.aspect(fromRatio: 1.3333) == PixelAspect(13333, 10000))
        #expect(PixelAspectMenu.aspect(fromRatio: 0.25) == PixelAspect(1, 4))
        #expect(PixelAspectMenu.aspect(fromRatio: 4) == PixelAspect(4, 1))
        #expect(PixelAspectMenu.aspect(fromRatio: 0) == nil)
        #expect(PixelAspectMenu.aspect(fromRatio: -2) == nil)
        #expect(PixelAspectMenu.aspect(fromRatio: 0.1) == nil)        // beyond 1:4
        #expect(PixelAspectMenu.aspect(fromRatio: 5) == nil)          // beyond 4:1
        #expect(PixelAspectMenu.aspect(fromRatio: .nan) == nil)
        #expect(PixelAspectMenu.aspect(fromRatio: .infinity) == nil)
    }

    @Test func ratioTextTrimsZeros() {
        #expect(PixelAspectMenu.ratioText(.square) == "1")
        #expect(PixelAspectMenu.ratioText(PixelAspect(2, 1)!) == "2")
        #expect(PixelAspectMenu.ratioText(PixelAspect(10, 11)!) == "0.909")
        #expect(PixelAspectMenu.ratioText(PixelAspect(4, 3)!) == "1.33")
    }

    @Test func stateReadsFileAndChoice() {
        let two = PixelAspect(2, 1)!, four3 = PixelAspect(4, 3)!
        let same = PixelAspectMenu.State(files: [four3, four3], overrides: [nil, nil])
        #expect(same.sharedFile == four3 && same.fromFile && same.sharedChoice == nil)
        let mixed = PixelAspectMenu.State(files: [four3, .square], overrides: [two, nil])
        #expect(mixed.sharedFile == nil && !mixed.fromFile && mixed.sharedChoice == nil)
        let chosen = PixelAspectMenu.State(files: [four3, .square], overrides: [two, two])
        #expect(chosen.sharedChoice == two && !chosen.fromFile)
    }

    @MainActor @Test func rowsCheckTheChoiceAndCustomShowsItsRatio() {
        let named = PixelAspectMenu.State(files: [.square], overrides: [PixelAspect(40, 33)])
        let rows = PixelAspectMenu.items(named, pick: { _ in }, custom: {})
        #expect(rows.filter(\.isChecked).map(\.title) == ["DV NTSC 16:9 (1.21)"])
        let odd = PixelAspectMenu.State(files: [.square], overrides: [PixelAspect(13333, 10000)])
        let oddRows = PixelAspectMenu.items(odd, pick: { _ in }, custom: {})
        #expect(oddRows.filter(\.isChecked).map(\.title) == ["Custom (1.33)\u{2026}"])
        let file = PixelAspectMenu.State(files: [PixelAspect(4, 3)!], overrides: [nil])
        let fileRows = PixelAspectMenu.items(file, pick: { _ in }, custom: {})
        #expect(fileRows.filter(\.isChecked).map(\.title) == ["From File (1.33)"])
    }
}
