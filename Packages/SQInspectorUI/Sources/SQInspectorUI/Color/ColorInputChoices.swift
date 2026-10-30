import SQCore

/// The Color page's "Input color" rows, shared by the AppKit `ColorInspectorView` (InputPickerView, FootageRows) and the
/// draw-list `ColorGradeDraw`: the color spaces "Interpret As" and "Project Input" offer, and the footage row titles.
public enum ColorInputChoices {
    private static let cameras: [CameraMake] = [.sony, .iPhone, .goPro, .dji, .panasonic, .canon, .other]
    private static let ranges: [DynamicRange] = [.sdr, .hlg, .pq]

    /// Every color space the pickers offer, in menu order, each once (the first menu entry is Automatic / None).
    public static let spaces: [ColorSpaceID] = {
        var out: [ColorSpaceID] = []
        func add(_ s: ColorSpaceID?) { if let s, !out.contains(s) { out.append(s) } }
        for r in ranges { add(space(camera: .other, log: false, range: r)) }
        for c in cameras where InputColorProfile.logAvailable(for: c) { add(space(camera: c, log: true, range: .sdr)) }
        // A camera with several log curves / color spaces (Canon) lists each of them.
        for c in cameras { InputColorProfile.logSpaces(for: c).forEach(add) }
        for c in cameras { for r in ranges { add(space(camera: c, log: false, range: r)) } }
        // Board order (Window > Project Input Color Space): the declaration order of ColorSpaceID.
        return ColorSpaceID.allCases.filter(out.contains)
    }()

    /// The spaces a picker lists for `current`: `spaces`, plus `current` at the end when it is not among them.
    public static func shown(current: ColorSpaceID?) -> [ColorSpaceID] {
        guard let current, !spaces.contains(current) else { return spaces }
        return spaces + [current]
    }

    /// The color space a camera / Log / range choice stands for.
    public static func space(camera: CameraMake, log: Bool, range: DynamicRange) -> ColorSpaceID? {
        var s = InputPickerState(override: nil)
        s.setCamera(camera)
        s.setLog(log)
        if !log { s.setRange(range) }
        return s.space
    }

    /// "Automatic (Rec. 709)": Interpret As without an override.
    public static func automaticTitle(detected: ColorSpaceID) -> String { "Automatic (\(detected.displayName))" }
    /// Project Input without a project space.
    public static let noProjectInput = "None (as tagged)"

    public static func title(_ m: LogMode) -> String {
        switch m {
        case .cameraLUT: "Camera LUT"
        case .builtIn: "Built-in Transform"
        case .off: "Off"
        }
    }

    public static func title(_ t: TargetSpace) -> String {
        switch t {
        case .rec709: "Rec. 709"
        case .rec2020: "Rec. 2020"
        case .rec2020PQ: "Rec. 2020 PQ"
        case .rec2020HLG: "Rec. 2020 HLG"
        }
    }
}
