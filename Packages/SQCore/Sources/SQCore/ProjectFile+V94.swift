import Foundation

// v94: the Zone Board (`ColorGradeData.zoneBoard`, `zoneBoardOff`) and the Color Range's color-volume mask mode
// (`HSLSecondary.maskMode`, `volumeSat`, `volumeLum`, `volumeRadius`). Each key is written only when set, so a file without
// them keeps the lowest version that holds its content. A v93 build would drop the board on the next save (and read a volume
// range as a plain range); at v94 it refuses the file. Identity step: all keys are optional on decode.

extension Project {
    /// A Color effect holds a Zone Board or a color-volume Color Range: the file must be v94.
    public var containsV94Content: Bool {
        allClips().contains { c in
            c.effects.contains { fx in
                guard fx.kind == ClipEffect.colorKind, let g = fx.grade else { return false }
                return g.zoneBoard != nil || g.zoneBoardOff || g.hslSecondary?.maskMode == .volume
            }
        }
    }
}
