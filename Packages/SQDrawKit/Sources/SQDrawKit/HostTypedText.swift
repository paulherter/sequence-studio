/// The text the keyboard layout made of the key press the host is delivering (capitals, @, the German y and z, symbols
/// on the Option or AltGr layer). `InputEvent.keyDown` carries the key position for shortcuts; a text field types this
/// text instead of the key when it is set (`TextEditState.handle`), so every field follows the system layout.
/// The host publishes it beside the event like `HostKeyRepeat`: Mac from `interpretKeyEvents`, Windows from WM_CHAR.
public final class HostTypedText: @unchecked Sendable {
    public static let shared = HostTypedText()
    public var text: String?
    public init() {}

    /// Runs `deliver` with the typed text set to `text`.
    public func with<T>(_ text: String?, _ deliver: () -> T) -> T {
        self.text = text
        defer { self.text = nil }
        return deliver()
    }
}
