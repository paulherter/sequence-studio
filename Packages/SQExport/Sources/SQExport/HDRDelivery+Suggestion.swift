import Foundation
import SQCore

extension HDRDelivery.Transfer {
    /// The delivery transfer the export dialog suggests when clips target these spaces: PQ beats HLG (it carries the
    /// brighter range), a Rec.2020 SDR or Rec.709 target suggests nothing. The user can still override it.
    public static func suggested(for targets: some Sequence<TargetSpace>) -> HDRDelivery.Transfer? {
        let set = Set(targets)
        if set.contains(.rec2020PQ) { return .pq }
        if set.contains(.rec2020HLG) { return .hlg }
        return nil
    }
}
