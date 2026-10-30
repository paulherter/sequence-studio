import Foundation

// v94: the Zone Board, a four-zone color control (Global, Shadows, Midtones, Highlights) with a color puck, a saturation
// and an exposure value per zone. Every value runs 0...1 with 0.5 as "no change" (a fresh board does nothing). Stored in the
// effect's grade data (`ColorGradeData.zoneBoard`, not keyframable, like curves); nil = no board in this effect.

/// The four tonal zones of the Zone Board.
public enum BoardZone: Int, Sendable, Hashable, Codable, CaseIterable {
    case global, shadows, midtones, highlights

    public var title: String {
        switch self {
        case .global: "Global"
        case .shadows: "Shadows"
        case .midtones: "Midtones"
        case .highlights: "Highlights"
        }
    }
}

/// One zone: puck position in its square (x right, y up, 0.5 / 0.5 = centered), saturation and exposure (0.5 = unchanged).
public struct ZoneSetting: Sendable, Hashable, Codable {
    public var puckX: Float = 0.5
    public var puckY: Float = 0.5
    public var saturation: Float = 0.5
    public var exposure: Float = 0.5

    public init() {}
    public init(puckX: Float, puckY: Float, saturation: Float = 0.5, exposure: Float = 0.5) {
        self.puckX = puckX; self.puckY = puckY; self.saturation = saturation; self.exposure = exposure
    }

    public var isNeutral: Bool { self == ZoneSetting() }

    public func clamped() -> ZoneSetting {
        func c(_ v: Float) -> Float { v.isFinite ? min(max(v, 0), 1) : 0.5 }
        return ZoneSetting(puckX: c(puckX), puckY: c(puckY), saturation: c(saturation), exposure: c(exposure))
    }

    /// The puck as a color wheel value: hue in degrees (0 = right, counter-clockwise, red = 0) and amount 0...1 of the
    /// radius. A puck outside the unit circle is clamped to the rim.
    public var wheelValue: WheelValue {
        let dx = (puckX - 0.5) * 2, dy = (puckY - 0.5) * 2
        let len = (dx * dx + dy * dy).squareRoot()
        guard len > 1e-6 else { return WheelValue() }
        var hue = atan2(dy, dx) * 180 / .pi
        if hue < 0 { hue += 360 }
        return WheelValue(hue: hue, amount: min(len, 1))
    }

    /// The puck position for a wheel value (inverse of `wheelValue`).
    public static func puck(_ w: WheelValue) -> (x: Float, y: Float) {
        let a = min(max(w.amount, 0), 1), r = w.hue * .pi / 180
        return (0.5 + 0.5 * a * cos(r), 0.5 + 0.5 * a * sin(r))
    }

    /// Saturation factor: 0 -> 0 (gray), 0.5 -> 1, 1 -> 2.
    public var saturationFactor: Float { min(max(saturation, 0), 1) * 2 }
    /// Exposure in stops: 0.5 -> 0, the ends are -1.5 / +1.5 stops.
    public var exposureStops: Float { (min(max(exposure, 0), 1) - 0.5) * 3 }
}

public struct ZoneBoard: Sendable, Hashable, Codable {
    public var global = ZoneSetting()
    public var shadows = ZoneSetting()
    public var midtones = ZoneSetting()
    public var highlights = ZoneSetting()

    public init() {}

    public subscript(zone: BoardZone) -> ZoneSetting {
        get {
            switch zone { case .global: global; case .shadows: shadows; case .midtones: midtones; case .highlights: highlights }
        }
        set {
            switch zone { case .global: global = newValue; case .shadows: shadows = newValue
            case .midtones: midtones = newValue; case .highlights: highlights = newValue }
        }
    }

    /// The board does nothing to the picture.
    public var isNeutral: Bool { BoardZone.allCases.allSatisfy { self[$0].isNeutral } }

    public func clamped() -> ZoneBoard {
        var r = self
        for z in BoardZone.allCases { r[z] = self[z].clamped() }
        return r
    }

    /// Resets one zone.
    public mutating func reset(_ zone: BoardZone) { self[zone] = ZoneSetting() }

    private enum CodingKeys: String, CodingKey { case global, shadows, midtones, highlights }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        global = try c.decodeIfPresent(ZoneSetting.self, forKey: .global) ?? ZoneSetting()
        shadows = try c.decodeIfPresent(ZoneSetting.self, forKey: .shadows) ?? ZoneSetting()
        midtones = try c.decodeIfPresent(ZoneSetting.self, forKey: .midtones) ?? ZoneSetting()
        highlights = try c.decodeIfPresent(ZoneSetting.self, forKey: .highlights) ?? ZoneSetting()
    }

    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        if !global.isNeutral { try c.encode(global, forKey: .global) }
        if !shadows.isNeutral { try c.encode(shadows, forKey: .shadows) }
        if !midtones.isNeutral { try c.encode(midtones, forKey: .midtones) }
        if !highlights.isNeutral { try c.encode(highlights, forKey: .highlights) }
    }
}
