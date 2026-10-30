import Foundation
import Testing
@testable import SQLibrary

@Suite struct CardAtLaunchTests {
    @Test func onlyCameraCardsThatAreImportSourcesAreOfferedAtLaunch() {
        let drives = [
            DriveFacts(root: "C:\\", kind: .fixed, bus: .other, isSystem: true),
            DriveFacts(root: "D:\\", kind: .fixed, bus: .other, isSystem: false),      // internal disk with a DCIM folder
            DriveFacts(root: "E:\\", kind: .removable, bus: .other, isSystem: false),  // SD card
            DriveFacts(root: "F:\\", kind: .fixed, bus: .usb, isSystem: false),        // USB SSD, plain backup disk
            DriveFacts(root: "G:\\", kind: .fixed, bus: .usb, isSystem: false),        // Sony card in a USB reader
        ]
        let tops: [String: [String]] = ["C:\\": ["DCIM"], "D:\\": ["DCIM"], "E:\\": ["dcim", "MISC"],
                                        "F:\\": ["Backups"], "G:\\": ["PRIVATE"]]
        #expect(CardAtLaunch.offers(drives) { tops[$0] ?? [] } == ["E:\\", "G:\\"])
        #expect(!CardAtLaunch.looksLikeCameraCard(topLevel: []))
    }
}
