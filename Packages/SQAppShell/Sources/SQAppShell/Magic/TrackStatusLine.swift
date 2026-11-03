/// Whose line the status bar shows, as far as the editor panels wrote it: a track says "Preparing…" or "Tracking…"
/// while it goes on, and a run that is stopped without a word (the tool was switched, its mask was removed, its
/// pick changed) must not leave that line standing. It is cleared only when it is still that run's line: a line
/// written since by anything else (a new pick, another run, the user's Stop) stays.
public struct TrackStatusLine: Sendable, Equatable {
    public static let preparing = "Preparing subject tracking…"

    /// The run (`MaskTrackActivity` token) whose going-on line was written last.
    private var owner: Int?

    public init() {}

    /// Any line was written to the status bar.
    public mutating func wrote() { owner = nil }

    /// The line written just now (after `wrote`) says that run `token` goes on.
    public mutating func goesOn(_ token: Int) { owner = token }

    /// Run `token` ended. True when its going-on line is still the last one written: the caller clears the status.
    public mutating func ended(_ token: Int) -> Bool {
        guard owner == token else { return false }
        owner = nil
        return true
    }
}
