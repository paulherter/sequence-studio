import Foundation
import SQCore
@testable import SQInspectorUI

/// The first Rounded Corners instance of a clip as a section / property (effects are addressed by instance id).
extension EffectSection {
    static func roundedCorners(of c: Clip) -> EffectSection {
        .effect(c.roundedCorners!.id, kind: ClipEffect.roundedCornersKind)
    }
}

extension EffectProperty {
    static func radius(of c: Clip) -> EffectProperty {
        .fx(c.roundedCorners!.id, kind: ClipEffect.roundedCornersKind, key: ClipEffect.radiusKey)
    }
}
