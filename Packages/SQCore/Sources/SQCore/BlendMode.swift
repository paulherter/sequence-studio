import Foundation

/// How a video clip's picture is combined with what is below it (Opacity > Blend Mode). The one blend system: clips,
/// nested sequences, adjustment layers, transition pairs and graphics layers all carry this value and the compositor draws
/// it in one shader. Listed in the editors' standard order (Normal, then the Darken, Lighten, Contrast, Inversion and
/// Component groups; `group` starts a menu section). The maths runs in the compositor's working-linear space (see
/// `BlendModes` in SQRender). Raw values are the file format: never rename one.
public enum BlendMode: String, Sendable, Hashable, Codable, CaseIterable {
    case normal, dissolve
    case darken, multiply, colorBurn, linearBurn, darkerColor
    case lighten, screen, colorDodge, add, lighterColor
    case overlay, softLight, hardLight, vividLight, linearLight, pinLight, hardMix
    case difference, exclusion, subtract, divide
    case hue, saturation, color, luminosity

    public var title: String {
        switch self {
        case .normal: "Normal"
        case .dissolve: "Dissolve"
        case .darken: "Darken"
        case .multiply: "Multiply"
        case .colorBurn: "Color Burn"
        case .linearBurn: "Linear Burn"
        case .darkerColor: "Darker Color"
        case .lighten: "Lighten"
        case .screen: "Screen"
        case .colorDodge: "Color Dodge"
        case .add: "Add"
        case .lighterColor: "Lighter Color"
        case .overlay: "Overlay"
        case .softLight: "Soft Light"
        case .hardLight: "Hard Light"
        case .vividLight: "Vivid Light"
        case .linearLight: "Linear Light"
        case .pinLight: "Pin Light"
        case .hardMix: "Hard Mix"
        case .difference: "Difference"
        case .exclusion: "Exclusion"
        case .subtract: "Subtract"
        case .divide: "Divide"
        case .hue: "Hue"
        case .saturation: "Saturation"
        case .color: "Color"
        case .luminosity: "Luminosity"
        }
    }

    /// The menu section this mode belongs to (0 Normal, 1 Darken, 2 Lighten, 3 Contrast, 4 Inversion, 5 Component).
    public var group: Int {
        switch self {
        case .normal, .dissolve: 0
        case .darken, .multiply, .colorBurn, .linearBurn, .darkerColor: 1
        case .lighten, .screen, .colorDodge, .add, .lighterColor: 2
        case .overlay, .softLight, .hardLight, .vividLight, .linearLight, .pinLight, .hardMix: 3
        case .difference, .exclusion, .subtract, .divide: 4
        case .hue, .saturation, .color, .luminosity: 5
        }
    }

    /// `allCases` cut into the menu sections (a separator goes between two of them).
    public static var menuSections: [[BlendMode]] {
        var out: [[BlendMode]] = []
        for m in allCases {
            if let last = out.last?.last, last.group == m.group { out[out.count - 1].append(m) } else { out.append([m]) }
        }
        return out
    }

    /// The five modes of v22. Every other one needs a newer build to open (`minimumFileVersion`).
    public var isLegacy: Bool { minimumFileVersion == 22 }

    /// The first project file version that knows this mode: 22 for the first five, 41 for the W9.6 set, 55 for the rest
    /// of the standard set (`ProjectFile.fullBlendVersion`).
    public var minimumFileVersion: Int {
        switch self {
        case .normal, .multiply, .screen, .add, .overlay: 22
        case .darken, .colorBurn, .linearBurn, .lighten, .colorDodge, .softLight, .hardLight, .difference, .exclusion: 41
        default: 55
        }
    }
}
