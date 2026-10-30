import Foundation
import SQLibrary
import SQInspectorUI
import SQEditorSession

/// Saved title templates in the Library: the thumbnail of a row, read once from the payload (the template itself is
/// not decoded for a list row).
extension LibraryPanelModel {
    private struct ThumbnailOnly: Decodable { var thumbnail: Data? }

    @MainActor private static var thumbnailCache: [String: Data?] = [:]

    /// PNG bytes saved with the template, nil without one.
    @MainActor
    public func titleTemplateThumbnailData(for preset: PresetItem) -> Data? {
        guard preset.kind == .titleTemplate else { return nil }
        let key = "\(preset.id.uuidString)-\(preset.payload.count)"
        if let hit = Self.thumbnailCache[key] { return hit }
        let data = (try? JSONDecoder().decode(ThumbnailOnly.self, from: preset.payload))?.thumbnail
        Self.thumbnailCache[key] = .some(data)
        return data
    }
}
