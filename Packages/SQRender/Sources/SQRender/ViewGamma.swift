import Foundation
import Synchronization

/// How the monitors show Rec.709 code values: a display preview only (export is never touched, it writes the
/// same BT.709 code values whatever is chosen). The layer is tagged CoreMedia 709 (effective gamma 1.96), so `mac`
/// leaves the picture unchanged; `web` and `broadcast` show what a 2.2 or 2.4 display makes of the same code values.
public enum ViewGamma: String, Sendable, CaseIterable, Equatable {
    case mac, web, broadcast

    /// The display gamma the choice stands for.
    public var gamma: Float {
        switch self {
        case .mac: 1.96
        case .web: 2.2
        case .broadcast: 2.4
        }
    }

    /// The tag of the layer's own decode (CoreMedia 709), which `mac` is defined by.
    public static let layerGamma: Float = 1.96

    public var title: String {
        switch self {
        case .mac: "Mac 1.96"
        case .web: "Web 2.2"
        case .broadcast: "Broadcast 2.4"
        }
    }

    public var tooltip: String {
        switch self {
        case .mac: "How QuickTime and Mac apps show Rec.709 video."
        case .web: "A typical web browser or phone screen (sRGB-like, about 2.2)."
        case .broadcast: "A broadcast or grading monitor in a dim room (2.4); darker midtones."
        }
    }

    /// Power applied to the code values before they reach the layer: code' ^ 1.96 == code ^ gamma, so the window
    /// server's decode ends at the luminance a display of `gamma` would show. 1 for `mac`.
    public var exponent: Float { gamma / Self.layerGamma }

    private static let store = Mutex(ViewGamma.mac)

    /// The monitors' shared choice (session-only; both monitors read it on every frame).
    public static var current: ViewGamma {
        get { store.withLock { $0 } }
        set { store.withLock { $0 = newValue } }
    }
}
