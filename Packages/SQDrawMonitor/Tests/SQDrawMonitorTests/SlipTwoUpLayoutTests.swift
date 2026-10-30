import Testing
import Foundation
import SQCore
import SQDrawKit
@testable import SQDrawMonitor

@Suite struct SlipTwoUpLayoutTests {
    @Test func panesSitSideBySideAboveTheReadout() {
        let b = CGRect(x: 0, y: 0, width: 830, height: 400)
        let f = SlipTwoUpLayout.paneFrames(in: b, gap: 10)
        #expect(f.head.width == 400 && f.tail.width == 400)
        #expect(f.head.minX == 10 && f.tail.minX == 420)
        #expect(f.head.maxY + SlipTwoUpLayout.readoutHeight == b.height)
    }

    @Test func tinyViewNeverGoesNegative() {
        let f = SlipTwoUpLayout.paneFrames(in: CGRect(x: 0, y: 0, width: 10, height: 10), gap: 10)
        #expect(f.head.width == 0 && f.head.height == 0)
    }

    @Test func readoutWording() {
        #expect(SlipTwoUpLayout.readout(offsetFrames: 12) == "Slip +12 f")
        #expect(SlipTwoUpLayout.readout(offsetFrames: -3) == "Slip -3 f")
        #expect(SlipTwoUpLayout.readout(offsetFrames: 0) == "Slip 0 f")
    }

    @Test func offsetRoundsToWholeFrames() {
        let fd = Time(1, 30)
        #expect(SlipTwoUpLayout.wholeFrames(Time(12, 30), frameDuration: fd) == 12)
        #expect(SlipTwoUpLayout.wholeFrames(Time(-3, 30), frameDuration: fd) == -3)
        #expect(SlipTwoUpLayout.wholeFrames(.zero, frameDuration: fd) == 0)
    }

    @Test func packPutsTheFirstFrameLeftAndTheLastRight() {
        let red = RGBAImage(width: 4, height: 2, fill: DrawColor(1, 0, 0, 1))
        let blue = RGBAImage(width: 8, height: 4, fill: DrawColor(0, 0, 1, 1))
        let img = SlipTwoUpLayout.pack(head: red, tail: blue, half: (width: 3, height: 2))
        #expect(img.width == 6 && img.height == 2)
        func px(_ x: Int, _ y: Int) -> [UInt8] { Array(img.pixels[(y * 6 + x) * 4 ..< (y * 6 + x) * 4 + 4]) }
        #expect(px(0, 0) == [255, 0, 0, 255] && px(2, 1) == [255, 0, 0, 255])
        #expect(px(3, 0) == [0, 0, 255, 255] && px(5, 1) == [0, 0, 255, 255])
    }

    @Test func packLeavesAMissingPictureBlack() {
        let img = SlipTwoUpLayout.pack(head: nil, tail: RGBAImage(width: 2, height: 2, fill: .white), half: (width: 2, height: 2))
        #expect(Array(img.pixels[0..<4]) == [0, 0, 0, 255])
        #expect(Array(img.pixels[8..<12]) == [255, 255, 255, 255])
    }

    @MainActor @Test func monitorDrawsBothPanesFromTheSlotInsteadOfThePicture() {
        let model = MonitorPanelModel(frameDuration: Time(1, 25), mode: .program)
        model.hasSequence = true
        let panel = MonitorPanel(model: model)
        panel.hasPicture = true
        panel.slipTwoUp = SlipTwoUpPicture(headTimecode: "00:00:01:00", tailTimecode: "00:00:04:00", offsetFrames: -4, slot: 1)
        panel.layout(DrawRect(x: 0, y: 0, w: 800, h: 500), scale: 1)
        var c = Canvas(width: 800, height: 500, atlas: nil, scale: 1)
        panel.draw(&c)
        let images = c.list.quads.filter { $0.kind == DrawQuad.Kind.image.rawValue && $0.pad == 1 }
        #expect(images.count == 2)
        #expect(images.map(\.u1).sorted() == [Float(0.5), 1])
        #expect(!c.list.quads.contains { $0.kind == DrawQuad.Kind.video.rawValue })
    }

    @Test func trimTwoUpNamesTheSidesAndMarksTheTrimmedOne() {
        let p = SlipTwoUpPicture.trim(outgoingTimecode: "00:00:02:10", incomingTimecode: nil, outgoingActive: true,
                                      incomingActive: false, note: "Ripple")
        #expect(p.headTitle == "Before the edit" && p.tailTitle == "After the edit")
        #expect(p.headTimecode == "00:00:02:10" && p.tailTimecode == "--")
        #expect(p.readout == "Ripple" && p.activeHead && !p.activeTail)
        let slip = SlipTwoUpPicture(headTimecode: "a", tailTimecode: "b", offsetFrames: 2)
        #expect(slip.headTitle == "First frame" && slip.readout == nil && !slip.activeHead)
    }

    @MainActor @Test func trimTwoUpOutlinesTheActivePaneInTheAccent() {
        func strokes(_ two: SlipTwoUpPicture) -> Int {
            let model = MonitorPanelModel(frameDuration: Time(1, 25), mode: .program)
            model.hasSequence = true
            let panel = MonitorPanel(model: model)
            panel.slipTwoUp = two
            panel.layout(DrawRect(x: 0, y: 0, w: 800, h: 500), scale: 1)
            var c = Canvas(width: 800, height: 500, atlas: nil, scale: 1)
            panel.draw(&c)
            let a = panel.theme.accent
            return c.list.quads.filter { $0.r == a.r && $0.g == a.g && $0.b == a.b }.count
        }
        let none = strokes(.trim(outgoingTimecode: "x", incomingTimecode: "y", outgoingActive: false, incomingActive: false, note: ""))
        let both = strokes(.trim(outgoingTimecode: "x", incomingTimecode: "y", outgoingActive: true, incomingActive: true, note: ""))
        #expect(both > none)
    }
}
