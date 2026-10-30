import Foundation
import SQCore
import SQUIKit
import SQLibrary
import SQInspectorUI

extension PresetKind {
    /// Presets that are placed on the timeline as titles (double-click, drag, "Insert at Playhead"): title blocks and title templates.
    public var isTitleInsert: Bool { self == .titleBlock || self == .titleTemplate }
}

/// Names and icons of the Library panel, shared by the Mac `LibraryPanelView` and the draw `LibraryDrawPanel`.
public enum LibraryLabels {
    public static func symbol(for kind: LibraryItemKind) -> SQIcon {
        switch kind {
        case .video: .film
        case .audio: .waveform
        case .image: .image
        case .overlay: .group
        case .lut: .palette
        case .font: .text
        case .other: .file
        }
    }

    public static func title(for kind: LibraryItemKind) -> String {
        switch kind {
        case .video: "Video"
        case .audio: "Audio"
        case .image: "Image"
        case .overlay: "Overlay"
        case .lut: "LUT"
        case .font: "Font"
        case .other: "Other"
        }
    }

    /// Sidebar icons of the Presets group (board `side()`).
    public static func symbol(for kind: PresetKind?) -> SQIcon {
        switch kind {
        case nil, .effect: .slidersHorizontal
        case .textTemplate, .animatedTextTemplate, .titleBlock, .titleTemplate: .text
        case .easing, .keystone: .moveHorizontal
        case .caption: .captions
        case .transition: .columns2
        }
    }

    public static func title(for kind: PresetKind?) -> String {
        switch kind {
        case nil: "All Presets"
        case .textTemplate: "Text Templates"
        case .animatedTextTemplate: "Animated Text"
        case .easing: "Easing"
        case .caption: "Captions"
        case .effect: "Effects"
        case .transition: "Transitions"
        case .keystone: "Keystones"
        case .titleBlock: "Title Blocks"
        case .titleTemplate: "Title Templates"
        }
    }

    /// What the empty list says and how to fill it (INTERACTION-AUDIT §10).
    public static func emptyText(offline: Bool, presetMode: Bool, favorites: Bool, hasFolders: Bool,
                                 query: String = "") -> (title: String, hint: String) {
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { return ("No results", "Nothing in the library matches “\(q)”.") }
        if offline { return ("Folder is offline", "The drive with this folder is not connected. Reconnect it, then right-click the folder and choose Rescan.") }
        if presetMode { return ("No presets", "Save an effect, a look or a keystone as a preset and it appears here. Right-click to import presets.") }
        if favorites { return ("No favorites yet", "Right-click an item and choose Toggle Favorite to find it here.") }
        if !hasFolders { return ("No library folders", "Add a folder of footage, music or sound effects to see its files here.") }
        return ("Nothing in this folder", "Files you add to the folder appear here.")
    }

    /// The text of a failed preset import or save (the Mac `showError`).
    public static func presetError(_ error: any Error, file: URL? = nil) -> (title: String, detail: String) {
        let title = file.map { "“\($0.lastPathComponent)” could not be imported." } ?? "The preset could not be saved."
        switch error {
        case LibraryStoreError.newerFormat: return (title, "It was made by a newer version of Sequence Studio.")
        case PresetFileError.notAPreset: return (title, "It is not a Sequence Studio preset.")
        case PresetFileError.damagedPayload: return (title, "The preset inside the file is damaged.")
        default: return (title, SQL10n.errorText(error))
        }
    }

    /// The text of a failed pack import or export (the Mac `LibraryPackFlow.message`).
    public static func packError(_ error: any Error) -> String {
        switch error {
        case SQPackError.notAPack: SQL10n.string("It is not a Sequence Studio pack.")
        case SQPackError.newerFormat: SQL10n.string("It was made by a newer version of Sequence Studio.")
        case SQPackError.tooLarge: SQL10n.string("It is larger than a pack may be.")
        case SQPackError.emptyPack: SQL10n.string("The pack holds nothing this version can read.")
        case SQPackError.missingLicense: SQL10n.string("A font in it has no recorded open font license.")
        case SQPackError.checksumMismatch, SQPackError.invalidAsset: SQL10n.string("A file inside it is damaged or not allowed.")
        case SQPackError.damagedEntry(let n): SQL10n.format("The preset “%@” inside it is damaged.", n)
        case SQPackError.invalidManifest, SQPackError.malformed: SQL10n.string("Its description is damaged.")
        default: SQL10n.errorText(error)
        }
    }
}

/// One row of the Library sidebar tree (v9): "Library" (every folder) > Favorites + the watched folders; "Presets" >
/// the preset kinds; "Packs" > the imported packs.
public struct LibrarySidebarRow: Equatable, Sendable {
    public var title: String
    public var symbol: SQIcon
    /// What a click selects (nil: a plain group heading).
    public var section: LibrarySection?
    public var isGroup: Bool
    public var isOffline = false

    public static func rows(folders: [LibraryFolderRow], packNames: [String]) -> [LibrarySidebarRow] {
        var out = [LibrarySidebarRow(title: "Library", symbol: .folder, section: .all, isGroup: true),
                   LibrarySidebarRow(title: "Favorites", symbol: .star, section: .favorites, isGroup: false)]
        out += folders.map {
            let off = $0.state == .offline
            return LibrarySidebarRow(title: $0.folder.displayName, symbol: off ? .driveOffline : .folder, section: .folder($0.id),
                                     isGroup: false, isOffline: off)
        }
        out.append(LibrarySidebarRow(title: "Presets", symbol: .folder, section: nil, isGroup: true))
        let kinds: [PresetKind?] = [nil] + PresetKind.allCases.filter { $0 != .titleBlock && $0 != .titleTemplate }.map { Optional($0) }
        out += kinds.map { LibrarySidebarRow(title: LibraryLabels.title(for: $0), symbol: LibraryLabels.symbol(for: $0), section: .presets($0), isGroup: false) }
        if !packNames.isEmpty {
            out.append(LibrarySidebarRow(title: "Packs", symbol: .folder, section: nil, isGroup: true))
            out += packNames.map { LibrarySidebarRow(title: $0, symbol: .package, section: .pack($0), isGroup: false) }
        }
        return out
    }
}

/// A row or tile of the presets section: a built-in text template or a preset the user saved.
public enum LibraryPresetCell: Equatable, Sendable {
    case template(TextTemplateCatalog.Entry)
    case user(PresetItem)

    public var name: String {
        switch self {
        case .template(let t): t.name
        case .user(let p): p.name
        }
    }

    public var symbol: SQIcon {
        switch self {
        case .template(let t): t.graphicPresetID == nil ? .text : .sparkles
        case .user(let p): LibraryLabels.symbol(for: p.kind)
        }
    }

    /// The use-counter key (`PresetKey`).
    public var presetKey: String {
        switch self {
        case .template(let t): PresetKey.builtIn(t.id)
        case .user(let p): PresetKey.user(p.id)
        }
    }

    /// What dragging the cell carries (the Mac pasteboard writer); nil = not draggable.
    public var dragPayload: LibraryDragPayload? {
        switch self {
        case .template(let t): .textTemplate(t.id)
        case .user(let p) where p.kind.isTitleInsert: .titleBlock(p.id)
        case .user(let p) where p.kind == .effect: .effectPreset(p.id)
        case .user: nil
        }
    }
}

/// What a drag out of the Library carries (the Mac pasteboard types): files (onto the timeline: import and place), a
/// built-in text template or a saved title (placed where it lands), an effect preset (applied to the clip under it).
public enum LibraryDragPayload: Equatable, Sendable {
    case files([URL])
    case textTemplate(String)
    case titleBlock(UUID)
    case effectPreset(UUID)
}

/// Grid geometry of the Library tiles (v9 `.tiles`: the slider sets the smallest tile, the columns share the width).
public enum LibraryTileGeometry {
    public static let tileSizeKey = "sq.library.tileSize"
    public static let defaultFraction = 0.4
    public static let aspect: CGFloat = 10.0 / 16.0
    public static let nameGap: CGFloat = 4
    public static let nameHeight: CGFloat = 14
    public static let gap: CGFloat = 8

    /// Slider fraction (0...1) -> thumbnail width; 0.4 is the board's 96 (`LibraryTile.thumbWidth`).
    public static func thumbWidth(forFraction f: Double) -> CGFloat { (64 + 80 * CGFloat(min(max(f, 0), 1))).rounded() }

    /// Columns and the stretched tile size for the available width.
    public static func layout(width avail: CGFloat, fraction: Double) -> (columns: Int, tile: CGSize) {
        let tw = thumbWidth(forFraction: fraction)
        let columns = max(1, Int(((avail + gap) / (tw + gap)).rounded(.down)))
        let w = max(((avail - CGFloat(columns - 1) * gap) / CGFloat(columns)).rounded(.down), tw)
        return (columns, CGSize(width: w, height: (w * aspect).rounded() + nameGap + nameHeight))
    }
}
