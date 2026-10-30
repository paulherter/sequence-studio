import Foundation
import SQCore
import SQUIKit

/// F7.10: the "Audio Channels" rows of a Project item's menu (source settings): which channels of the file the item's
/// clips play. Pure: builds SQ rows, the panel applies the picked map.
public enum AudioChannelsMenu {
    /// Up to this many channels every pair is offered; beyond it only the neighbors (1 + 2, 3 + 4, ...), so a
    /// 16-channel file does not open a list of 120 pairs.
    static let allPairsLimit = 4

    /// Channel pairs offered for Stereo and Dual Mono (0-based, first < second).
    static func pairs(channels: Int) -> [(Int, Int)] {
        guard channels >= 2 else { return [] }
        if channels <= allPairsLimit { return (0..<channels).flatMap { a in ((a + 1)..<channels).map { (a, $0) } } }
        return stride(from: 0, to: channels - 1, by: 2).map { ($0, $0 + 1) }
    }

    /// Rows for a file with `channels` channels; `current` is the item's map (nil = the file's layout). Empty for files
    /// with fewer than two channels: there is nothing to choose.
    @MainActor
    public static func items(channels: Int, current: AudioChannelMap?,
                             pick: @escaping @MainActor (AudioChannelMap?) -> Void) -> [SQMenuItem] {
        guard channels >= 2 else { return [] }
        func row(_ title: String, _ map: AudioChannelMap?) -> SQMenuItem {
            SQMenuItem(title: title, isChecked: map != nil && map == current, action: { pick(map) })
        }
        let mono = (0..<channels).map { row("Channel \($0 + 1)", .mono($0)) }
        let all = pairs(channels: channels)
        let stereo = all.map { row("\($0.0 + 1) + \($0.1 + 1)", .stereo($0.0, $0.1)) }
        let dual = all.map { row("\($0.0 + 1) + \($0.1 + 1)", .dualMono($0.0, $0.1)) }
        func group(_ title: String, _ rows: [SQMenuItem]) -> SQMenuItem {
            SQMenuItem(title: title, isChecked: rows.contains(where: \.isChecked), submenu: rows)
        }
        return [SQMenuItem(title: "File Layout", isChecked: current == nil, action: { pick(nil) }), .separator,
                group("Mono", mono), group("Stereo", stereo), group("Dual Mono", dual)]
    }
}
