/// Whether the key press the host is delivering is an auto-repeat (key held down). The Mac key route ignores repeats of
/// every command that is not `isRepeatable` (a held Space must not toggle play, a held Delete must not delete clip after
/// clip); `InputEvent.keyDown` carries no flag, so the host publishes it beside the event (like `HostGesture`).
/// shortcut: a flag beside the event instead of inside it, so the panels that pattern-match `.keyDown` keep compiling;
/// upgrade by moving it into the event when those files are free to change.
public final class HostKeyRepeat: @unchecked Sendable {
    public static let shared = HostKeyRepeat()
    public var isRepeat = false
    public init() {}

    /// Runs `deliver` with the repeat flag set to `repeating`.
    public func with<T>(_ repeating: Bool, _ deliver: () -> T) -> T {
        isRepeat = repeating
        defer { isRepeat = false }
        return deliver()
    }
}
