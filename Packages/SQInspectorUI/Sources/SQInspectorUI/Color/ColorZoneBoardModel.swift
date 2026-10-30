import Foundation
import SQCore

/// The Zone Board section: four zones (Global, Shadows, Midtones, Highlights), each with a color puck, a saturation and an
/// exposure value. Lives in the effect's grade data (`ColorEffect.zoneBoard`, not keyframable, like the curves); the first
/// edit creates the board.
extension ColorInspectorModel {
    /// The effect's board; a fresh (neutral) one when none exists yet.
    public func zoneBoard(_ effect: Int) -> ZoneBoard { color.effect(effect)?.zoneBoard ?? ZoneBoard() }

    private func editZone(_ effect: Int, _ zone: BoardZone, _ change: (inout ZoneSetting) -> Void) {
        editEffect(effect) { e in
            var b = e.zoneBoard ?? ZoneBoard()
            var z = b[zone]
            change(&z)
            b[zone] = z.clamped()
            e.zoneBoard = b
        }
    }

    /// The puck as a wheel position (hue degrees, amount 0...1).
    public func setZonePuck(_ effect: Int, _ zone: BoardZone, hue: Float, amount: Float) {
        let p = ZoneSetting.puck(WheelValue(hue: hue, amount: min(max(amount, 0), 1)))
        editZone(effect, zone) { $0.puckX = p.x; $0.puckY = p.y }
    }

    /// Exposure from the wheel's side slider (-1...1, 0 = unchanged).
    public func setZoneExposure(_ effect: Int, _ zone: BoardZone, slider: Float) {
        editZone(effect, zone) { $0.exposure = 0.5 + min(max(slider, -1), 1) / 2 }
    }

    /// Saturation in percent (0...200, 100 = unchanged).
    public func setZoneSaturation(_ effect: Int, _ zone: BoardZone, percent: Float) {
        editZone(effect, zone) { $0.saturation = min(max(percent, 0), 200) / 200 }
    }

    public func zoneSaturationPercent(_ effect: Int, _ zone: BoardZone) -> Float { zoneBoard(effect)[zone].saturation * 200 }
    public func zoneExposureSlider(_ effect: Int, _ zone: BoardZone) -> Float { (zoneBoard(effect)[zone].exposure - 0.5) * 2 }
    public func zonePuckWheel(_ effect: Int, _ zone: BoardZone) -> WheelValue { zoneBoard(effect)[zone].wheelValue }

    /// Resets one zone; no board yet: nothing to reset (no undo step).
    public func resetZone(_ effect: Int, _ zone: BoardZone) {
        guard color.effect(effect)?.zoneBoard != nil else { return }
        gesture { editZone(effect, zone) { $0 = ZoneSetting() } }
    }
}
