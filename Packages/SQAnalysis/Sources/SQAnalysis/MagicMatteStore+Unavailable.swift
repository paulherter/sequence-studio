#if !canImport(Vision)
import Foundation

// shortcut: no Magic Mask off the Mac (Vision); the store is empty and keeps nothing. Upgrade when a Windows subject
// segmenter exists (the Windows port plan): then MagicMask.swift's store moves into a portable file.

/// Some stored frames of one key (none off the Mac): the undo state of deleting tracked frames.
public struct MagicFrameSnapshot: Sendable {
    let key: String
    public var isEmpty: Bool { true }
    public var count: Int { 0 }
    public var times: [Double] { [] }
    public var storeKey: String { key }
}

/// Per-frame Magic mattes by cache key: always empty off the Mac.
public final class MagicMatteStore: Sendable {
    public static let shared = MagicMatteStore()
    public init() {}
    public func times(key: String) -> [Double] { [] }
    @discardableResult public func removeFrames(key: String, times: [Double]) -> Int { 0 }
    @discardableResult public func removeFrames(matching snapshot: MagicFrameSnapshot) -> [Double] { [] }
    public func snapshotFrames(key: String, times: [Double]) -> MagicFrameSnapshot { MagicFrameSnapshot(key: key) }
    public func restore(_ snapshot: MagicFrameSnapshot) {}
    public func save(key: String) {}
    public func saveLater(key: String) {}
}
#endif
