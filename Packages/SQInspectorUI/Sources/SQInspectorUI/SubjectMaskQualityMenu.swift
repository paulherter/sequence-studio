import Foundation
import SQAnalysis
import SQUIKit

/// Program monitor menu > Subject Mask Edges: the one choice between Quality and Speed for tracking a subject mask
/// (`SubjectMaskQuality`, stored for this Mac under `sq.subjectMask.quality`, not in the project). The next Track
/// uses it; frames tracked before keep their edge until they are tracked again.
public enum SubjectMaskQualityMenu {
    public static let title = "Subject Mask Edges"

    public static func help(_ q: SubjectMaskQuality) -> String {
        switch q {
        case .quality: "Finer hair and soft edges, tracks slower"
        case .speed: "Tracks faster, simpler edges"
        }
    }

    /// The submenu row with the stored choice checked. `changed` runs after a new choice was stored.
    @MainActor
    public static func item(defaults: UserDefaults = .standard, changed: @escaping @MainActor (SubjectMaskQuality) -> Void = { _ in }) -> SQMenuItem {
        let current = SubjectMaskQuality.stored(in: defaults)
        return SQMenuItem(title: title, submenu: SubjectMaskQuality.allCases.map { q in
            SQMenuItem(title: q.title, isChecked: q == current, help: help(q)) {
                q.store(in: defaults)
                changed(q)
            }
        })
    }
}
