import Foundation
import SQUIKit

/// The host window's screen color sampler (the Mac `SQLoupe`): drawn eyedropper buttons call `begin`, the host arms its
/// loupe and answers once with the picked color (nil = canceled). nil while the host cannot sample: the buttons hide.
/// Set once by the app (Windows: `InspectorHost`, GDI under the pointer).
@MainActor
public enum ScreenColorSampler {
    public static var begin: ((_ done: @escaping @MainActor (SQColorValue?) -> Void) -> Void)?
}
