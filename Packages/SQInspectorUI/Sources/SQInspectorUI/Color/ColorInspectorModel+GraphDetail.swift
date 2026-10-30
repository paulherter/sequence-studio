import Foundation
import SQCore

/// One slider of a Step's window (the shape that limits the Step to part of the frame). Positions, sizes and softness
/// show as percent, the model keeps fractions (`StepWindow`).
public enum StepWindowParam: Int, CaseIterable, Sendable {
    case centerX, centerY, width, height, rotation, softness

    public var title: String {
        switch self {
        case .centerX: "Position X"
        case .centerY: "Position Y"
        case .width: "Width"
        case .height: "Height"
        case .rotation: "Rotation"
        case .softness: "Softness"
        }
    }

    public var range: ClosedRange<Float> {
        switch self {
        case .centerX, .centerY: 0...100
        case .width, .height: 1...200
        case .rotation: -180...180
        case .softness: 0...100
        }
    }

    public var neutral: Float { read(StepWindow()) }
    public var decimals: Int { 1 }

    public func read(_ w: StepWindow) -> Float {
        switch self {
        case .centerX: w.centerX * 100
        case .centerY: w.centerY * 100
        case .width: w.width * 100
        case .height: w.height * 100
        case .rotation: w.rotation
        case .softness: w.softness * 100
        }
    }

    public func write(_ value: Float, into w: inout StepWindow) {
        let v = min(max(value, range.lowerBound), range.upperBound)
        switch self {
        case .centerX: w.centerX = v / 100
        case .centerY: w.centerY = v / 100
        case .width: w.width = v / 100
        case .height: w.height = v / 100
        case .rotation: w.rotation = v
        case .softness: w.softness = v / 100
        }
    }
}

extension StepWindow.Shape {
    public var title: String {
        switch self {
        case .ellipse: "Ellipse"
        case .rectangle: "Rectangle"
        case .linear: "Linear"
        }
    }
}

extension ColorQualifier {
    /// The qualifier as a Color Range (so the Simple-mode `ColorRangeParam` reads and writes it), and back.
    fileprivate init(_ r: HSLSecondary) {
        self.init()
        hueCenter = r.hueCenter; hueWidth = r.hueWidth; satMin = r.satMin; satMax = r.satMax
        lumMin = r.lumMin; lumMax = r.lumMax; softness = r.softness; invert = r.invert
    }
}

extension ColorInspectorModel {
    // MARK: Curves (RGB and Hue Saturation) of a Step. The same value types and wrap rule as the Simple section.

    public func stepCurves(_ id: UUID) -> RGBCurves { step(id)?.curves ?? RGBCurves() }

    public func setStepCurves(_ id: UUID, _ c: RGBCurves) { editStep(id) { $0.curves = c } }

    public func stepHueCurve(_ id: UUID, _ kind: HueCurveKind) -> [CurvePoint] {
        kind.points(step(id)?.hueCurves ?? HueCurves())
    }

    public func setStepHueCurve(_ id: UUID, _ kind: HueCurveKind, _ pts: [CurvePoint]) {
        editStep(id) { s in kind.set(kind.wrapped(pts, previous: kind.points(s.hueCurves)), in: &s.hueCurves) }
    }

    public func resetStepHueCurve(_ id: UUID, _ kind: HueCurveKind) {
        gesture { setStepHueCurve(id, kind, HueCurves.flat) }
    }

    // MARK: Qualifier (the Color Range ranges)

    /// Turns the qualifier on (a new one: skin tones) or off (the Step then works on every pixel).
    public func setStepQualifierEnabled(_ id: UUID, _ on: Bool) {
        editStep(id) { s in
            if on { if s.qualifier == nil { s.qualifier = ColorQualifier() } } else { s.qualifier = nil }
        }
    }

    public func stepQualifierValue(_ id: UUID, _ p: ColorRangeParam) -> Float {
        p.read(step(id)?.qualifier?.asColorRange ?? HSLSecondary())
    }

    /// Writes one range value; a Step without a qualifier is left alone (the switch comes first).
    public func setStepQualifier(_ id: UUID, _ p: ColorRangeParam, _ v: Float) {
        guard p.isQualifier else { return }
        editStep(id) { s in
            guard let q = s.qualifier else { return }
            var r = q.asColorRange
            p.write(v, into: &r)
            s.qualifier = ColorQualifier(r)
        }
    }

    public func resetStepQualifierParameter(_ id: UUID, _ p: ColorRangeParam) {
        guard step(id)?.qualifier != nil else { return }
        setStepQualifier(id, p, p.read(ColorQualifier().asColorRange))
    }

    public func setStepQualifierInvert(_ id: UUID, _ on: Bool) {
        editStep(id) { $0.qualifier?.invert = on }
    }

    // MARK: Window

    public func setStepWindowEnabled(_ id: UUID, _ on: Bool) {
        editStep(id) { s in
            if on { if s.window == nil { s.window = StepWindow() } } else { s.window = nil }
        }
    }

    public func stepWindowValue(_ id: UUID, _ p: StepWindowParam) -> Float {
        p.read(step(id)?.window ?? StepWindow())
    }

    public func setStepWindow(_ id: UUID, _ p: StepWindowParam, _ v: Float) {
        editStep(id) { s in
            guard var w = s.window else { return }
            p.write(v, into: &w)
            s.window = w
        }
    }

    public func resetStepWindowParameter(_ id: UUID, _ p: StepWindowParam) {
        guard step(id)?.window != nil else { return }
        setStepWindow(id, p, p.neutral)
    }

    /// The Step and window the Program monitor shows handles for: Pro grade, the selected Step, its window on.
    public var windowEditTarget: (step: UUID, window: StepWindow)? {
        guard activeGrade == .pro, let id = selectedStep, let w = step(id)?.window else { return nil }
        return (id, w)
    }

    /// A drag of the monitor handles: position, size and angle of the window. Shape, softness and invert stay the
    /// panel's; a Step without a window is left alone.
    public func setStepWindowGeometry(_ id: UUID, _ w: StepWindow) {
        editStep(id) { s in
            guard var cur = s.window else { return }
            cur.centerX = w.centerX; cur.centerY = w.centerY
            cur.width = w.width; cur.height = w.height
            cur.rotation = w.rotation
            s.window = cur
        }
    }

    public func setStepWindowShape(_ id: UUID, _ shape: StepWindow.Shape) {
        editStep(id) { $0.window?.shape = shape }
    }

    public func setStepWindowInvert(_ id: UUID, _ on: Bool) {
        editStep(id) { $0.window?.invert = on }
    }
}

// MARK: Primaries wheels (version 9 Pro Primaries)

/// How a Primaries row reads in the value column (version 9 shows whole numbers, 50 = neutral for Contrast and Saturation).
enum StepPrimaryRow: CaseIterable {
    case saturation, contrast, pivot

    var param: StepParam { switch self { case .saturation: .saturation; case .contrast: .contrast; case .pivot: .pivot } }
    var title: String { param.title }
    /// Shown value = engine value x scale.
    var scale: Float { switch self { case .saturation, .contrast: 50; case .pivot: 100 } }
    var range: ClosedRange<Float> { param.range.lowerBound * scale...param.range.upperBound * scale }
    var neutral: Float { param.neutral * scale }
    var decimals: Int { 0 }
}

extension ColorInspectorModel {
    /// The puck and master (-1...1) of one wheel of a Step.
    public func stepWheel(_ id: UUID, _ w: PrimaryWheel) -> (puck: ColorWheelMath.Value, master: Double) {
        let t = w.triple((step(id) ?? ColorStep(id: id, label: "")).primaries)
        return (w.puck(of: t), w.master(of: t))
    }

    /// Writes one wheel from the controls' puck and master (an undo step; inside a drag the host groups the changes).
    public func setStepWheel(_ id: UUID, _ w: PrimaryWheel, puck: ColorWheelMath.Value, master: Double) {
        editStep(id) { w.write(w.triple(puck: puck, master: master), into: &$0.primaries) }
    }
}
