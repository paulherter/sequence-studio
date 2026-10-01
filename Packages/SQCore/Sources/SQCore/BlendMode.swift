import Foundation

/// How a video clip's picture is combined with what is below it (Opacity > Blend Mode). Listed in Premiere's order
/// (Normal, then the Darken, Lighten and Contrast groups); only the everyday ones are built. The maths runs in the
/// compositor's working-linear space (see `BlendModes` in SQRender).
public enum BlendMode: String, Sendable, Hashable, Codable, CaseIterable {
    case normal, multiply, screen, add, overlay

    public var title: String {
        switch self {
        case .normal: "Normal"
        case .multiply: "Multiply"
        case .screen: "Screen"
        case .add: "Linear Dodge (Add)"
        case .overlay: "Overlay"
        }
    }
}
