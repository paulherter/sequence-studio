import SQUIKit
import AppKit
import Observation
import SQCore
import SQLibrary

extension NSPasteboard.PasteboardType {
    /// A keystone dragged from the Keystones panel: its payload JSON (self-contained, so the drop ghost knows its length).
    public static let sequenceKeystone = NSPasteboard.PasteboardType("com.sequencestudio.keystone")
}

/// Keystone drags on the Mac pasteboard (the payload string itself is portable, KeystoneBar.swift).
extension KeystoneDrag {
    public static func write(_ keystone: Keystone, to pb: NSPasteboard) {
        guard let s = string(for: keystone) else { return }
        pb.setString(s, forType: .sequenceKeystone)
    }

    public static func read(from pb: NSPasteboard) -> Keystone? {
        pb.string(forType: .sequenceKeystone).flatMap(keystone(from:))
    }
}
