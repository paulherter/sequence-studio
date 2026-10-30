import Foundation

/// Hold-to-temp tools (Q-IX5 rec 1). A tool key switches immediately on key down; a tap (up before `threshold`) leaves it
/// as a normal sticky switch, a longer hold reverts to the tool that was active before on key up. Pure: the host feeds
/// key events and clock readings and applies the returned tool.
public struct ToolHold: Sendable {
    public static let threshold: TimeInterval = 0.25
    private var active: (key: Key, tool: EditorTool, previous: EditorTool, start: TimeInterval)?

    public init() {}

    /// A tool key went down. `previous` is the tool that was active before this press. Auto-repeats of the held key are
    /// ignored; a second tool key during a hold keeps the tool from before the chain.
    public mutating func press(_ key: Key, tool: EditorTool, previous: EditorTool, at time: TimeInterval) {
        if let a = active {
            if a.key == key { return }
            active = (key, tool, a.previous, time)
        } else {
            active = (key, tool, previous, time)
        }
    }

    /// The key came up. Returns the tool to go back to when it was a hold that changed the tool, else nil.
    public mutating func release(_ key: Key, at time: TimeInterval) -> EditorTool? {
        guard let a = active, a.key == key else { return nil }
        active = nil
        return time - a.start >= Self.threshold && a.previous != a.tool ? a.previous : nil
    }

    /// Focus loss: the held key's key-up will not come. Ends the hold as if it came now (tool to go back to, or nil).
    public mutating func releaseAll(at time: TimeInterval) -> EditorTool? {
        guard let a = active else { return nil }
        return release(a.key, at: time)
    }

    public mutating func clear() { active = nil }
}
