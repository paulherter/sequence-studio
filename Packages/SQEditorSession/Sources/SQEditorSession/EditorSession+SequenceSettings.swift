import Foundation
import SQCore

extension EditorSession {
    /// Sequence Settings of the active sequence: one undo step ("Sequence Settings"). False when nothing changed.
    @discardableResult
    public func applySequenceSettings(_ s: SequenceSettings) -> Bool {
        guard let id = activeTimelineID, let current = activeTimeline?.settings else { return false }
        var wanted = s
        if wanted.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { wanted.name = current.name }
        guard wanted != current else { return false }
        do { try perform("Sequence Settings") { try $0.setSettings(wanted, of: id) } } catch {
            setError(Self.message(for: error)); return false
        }
        return true
    }
}
