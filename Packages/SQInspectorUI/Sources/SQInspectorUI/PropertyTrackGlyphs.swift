import Foundation
import SQCore
import SQUIKit

// Portable (Windows too): the lanes, the Graph Editor sampling and the draw-list Controls read the same glyphs.

extension PropertyTrack {
    /// Id, clip-local time and glyph of every key a lane shows.
    var glyphs: [(id: UUID, time: Time, glyph: KeyGlyph)] {
        let all: [(id: UUID, time: Time, glyph: KeyGlyph)] = switch self {
        case .scalar(let t): KeyGlyph.glyphs(of: t)
        case .vector(let t): KeyGlyph.glyphs(of: t)
        case .color(let t): KeyGlyph.glyphs(of: t)
        case .path(let t): KeyGlyph.glyphs(of: t)
        }
        let shown = times
        if shown.count == all.count { return all }
        let ids = Set(shown.map(\.id))
        return all.filter { ids.contains($0.id) }
    }
}
