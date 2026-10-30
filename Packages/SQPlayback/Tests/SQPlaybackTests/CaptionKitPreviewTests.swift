import Foundation
import Testing
import SQCore
import SQText
@testable import SQPlayback

/// W8.3: the monitor draws captions through the project's own kit (explicit library), not the process-wide one.
@Suite struct CaptionKitPreviewTests {
    let canvas = SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30))

    @Test func explicitLibraryDecidesTheCaptionStyle() throws {
        var kit = StyleKit()
        kit.fonts["brand"] = "Futura-Bold"
        kit.caption = CaptionStyleSpec(baseStyle: "default", font: .token("brand"))
        let item = CaptionItem(lines: ["Hi"], range: TimeRange(start: .zero, end: Time(1, 1)), styleRef: StyleKit.captionStyleRef)
        let withKit = CaptionPreview.template(for: item, canvas: canvas, library: CaptionLookRegistry.shared.library(for: kit))
        let without = CaptionPreview.template(for: item, canvas: canvas, library: CaptionLookRegistry.shared.library(for: nil))
        #expect(withKit.style.fontName == "Futura-Bold")
        #expect(without.style.fontName != "Futura-Bold")
        let a = try CaptionPreview.ref(for: item, canvas: canvas, library: CaptionLookRegistry.shared.library(for: kit))
        let b = try CaptionPreview.ref(for: item, canvas: canvas, library: CaptionLookRegistry.shared.library(for: nil))
        #expect(a != b)
    }

    @Test func ownPositionBeatsTheKitPosition() {
        var item = CaptionItem(lines: ["Hi"], range: TimeRange(start: .zero, end: Time(1, 1)), styleRef: "default")
        let lib = CaptionLookRegistry.shared.library(for: StyleKit(captionPosition: CaptionPosition(vertical: .top)))
        let kit = CaptionPreview.position(for: item, canvas: canvas, library: lib)
        item.position = CaptionPosition(vertical: .bottom, offsetX: 0.1)
        let own = CaptionPreview.position(for: item, canvas: canvas, library: lib)
        #expect(kit.y < 0 && own.y > 0 && abs(own.x - 192) < 1e-9)
    }

    /// FB-Y: the kit's caption position moves the monitor caption (box center and text alignment).
    @Test func kitPositionPlacesTheMonitorCaption() {
        let item = CaptionItem(lines: ["Hi"], range: TimeRange(start: .zero, end: Time(1, 1)), styleRef: "default")
        let p = CaptionPosition(vertical: .top, horizontal: .left, offsetX: 0.1)
        let lib = CaptionLookRegistry.shared.library(for: StyleKit(captionPosition: p))
        let top = CaptionPreview.position(for: item, canvas: canvas, library: lib)
        let bottom = CaptionPreview.position(for: item, canvas: canvas, library: CaptionLookRegistry.shared.library(for: nil))
        #expect(top.y < 0 && bottom.y > 0)
        #expect(abs(top.x - 0.1 * 1920) < 1e-9 && bottom.x == 0)
        let t = CaptionPreview.template(for: item, canvas: canvas, library: lib)
        #expect(t.style.alignment == .left && t.style.verticalAlignment == .top)
    }

    /// Karaoke + pill: the plain layer draws one pill per word (a different raster from the single-box plain caption), and
    /// stays one raster for the whole caption.
    @Test func karaokePillCaptionUsesPerWordPillInThePlainLayer() throws {
        let words = [("so", 0, 3), ("this", 4, 8)].map {
            CaptionWord(text: $0.0, range: TimeRange(start: Time(Int64($0.1), 10), end: Time(Int64($0.2), 10)))
        }
        let item = CaptionItem(lines: ["so this"], range: TimeRange(start: .zero, end: Time(2, 1)), styleRef: CaptionPill.styleID,
                               words: words)
        let a = try CaptionPreview.plan(for: item, karaoke: KaraokeStyle(), canvas: canvas, at: Time(1, 10))
        let b = try CaptionPreview.plan(for: item, karaoke: KaraokeStyle(), canvas: canvas, at: Time(5, 10))
        let none = try CaptionPreview.plan(for: item, karaoke: nil, canvas: canvas, at: Time(1, 10))
        #expect(a.plain == b.plain && a.plain != none.plain)
    }
}
