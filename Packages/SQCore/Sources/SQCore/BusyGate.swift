/// One long-running operation at a time (e.g. a project import): `enter()` refuses while one runs.
/// Callers pair it with `defer { gate.leave() }` so an early return or throw never leaves it locked.
public struct BusyGate: Sendable {
    public private(set) var isBusy = false
    public init() {}
    /// True when the caller may start; false when an operation is already running.
    public mutating func enter() -> Bool {
        if isBusy { return false }
        isBusy = true
        return true
    }
    public mutating func leave() { isBusy = false }
}
