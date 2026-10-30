import Foundation
import SQUIKit
import SQLibrary
import SQInspectorUI
import SQEditorSession

/// SQ rows for the Library panel menus (sidebar folder, file item, preset). Pure: the panel maps `Action`s to calls.
public enum LibraryMenus {
    public enum Action: Equatable {
        case rescan, removeFolder
        case toggleFavorite, whoosh, addToSFX, reveal
        case insertTitleBlock, applyPreset, applyAbsolute, applyRelative, toggleDefaultApply
        case exportPreset, importPresets, deletePreset
        case exportPack, importPack
        /// Organizing a preset or built-in template: favorite, shelf (nil = back to the default shelf), tag on/off.
        case toggleFavoritePreset, setCategory(PresetCategory?), toggleTag(String)
    }

    /// Current organizing state of the clicked preset or template (nil in the context = no organize rows).
    public struct Organize: Equatable {
        public var isFavorite: Bool
        public var category: PresetCategory
        public var defaultCategory: PresetCategory
        public var tags: [String]
        public init(isFavorite: Bool, category: PresetCategory, defaultCategory: PresetCategory, tags: [String]) {
            self.isFavorite = isFavorite; self.category = category; self.defaultCategory = defaultCategory; self.tags = tags
        }
    }

    public struct Context: Equatable {
        public var showsPresets: Bool
        public var hasAudio: Bool
        public var canWhoosh: Bool
        public var presetIsTitleBlock: Bool
        public var presetIsEffect: Bool
        public var hasPreset: Bool
        public var relativeDefault: Bool
        public var organize: Organize?

        public init(showsPresets: Bool = false, hasAudio: Bool = false, canWhoosh: Bool = false, presetIsTitleBlock: Bool = false,
                    presetIsEffect: Bool = false, hasPreset: Bool = false, relativeDefault: Bool = false, organize: Organize? = nil) {
            self.showsPresets = showsPresets; self.hasAudio = hasAudio; self.canWhoosh = canWhoosh
            self.presetIsTitleBlock = presetIsTitleBlock; self.presetIsEffect = presetIsEffect
            self.hasPreset = hasPreset; self.relativeDefault = relativeDefault; self.organize = organize
        }
    }

    @MainActor
    public static func folderItems(run: @escaping @MainActor (Action) -> Void) -> [SQMenuItem] {
        [SQMenuItem(title: "Rescan", action: { run(.rescan) }), .separator,
         SQMenuItem(title: "Remove Folder", action: { run(.removeFolder) })]
    }

    /// Sidebar menu of a pack folder.
    @MainActor
    public static func packItems(run: @escaping @MainActor (Action) -> Void) -> [SQMenuItem] {
        [SQMenuItem(title: "Export as Pack…", action: { run(.exportPack) }),
         SQMenuItem(title: "Import Pack…", action: { run(.importPack) })]
    }

    /// File items, or the preset items of the Presets section.
    @MainActor
    public static func itemItems(_ c: Context, run: @escaping @MainActor (Action) -> Void) -> [SQMenuItem] {
        func row(_ title: String, _ a: Action, _ enabled: Bool = true) -> SQMenuItem {
            SQMenuItem(title: title, isEnabled: enabled, action: { run(a) })
        }
        guard c.showsPresets else {
            return [row("Toggle Favorite", .toggleFavorite),
                    row("Whoosh at Selected Cuts", .whoosh, c.hasAudio && c.canWhoosh),
                    row("Add to SFX Folder", .addToSFX, c.hasAudio),
                    row("Reveal in Finder", .reveal)]
        }
        var organise: [SQMenuItem] = []
        if let o = c.organize {
            let tags = PresetMetaTable.suggestedTags + o.tags.filter { !PresetMetaTable.suggestedTags.contains($0) }
            organise = [
                SQMenuItem(title: o.isFavorite ? "Remove from Favorites" : "Add to Favorites", action: { run(.toggleFavoritePreset) }),
                SQMenuItem(title: "Category", submenu: PresetCategory.allCases.map { cat in
                    SQMenuItem(title: cat.title, isChecked: o.category == cat) { run(.setCategory(cat == o.defaultCategory ? nil : cat)) }
                }),
                SQMenuItem(title: "Tags", submenu: tags.map { tag in
                    SQMenuItem(title: tag, isChecked: o.tags.contains(tag)) { run(.toggleTag(tag)) }
                }),
                .separator,
            ]
        }
        return organise + [row("Insert at Playhead", .insertTitleBlock, c.presetIsTitleBlock),
                row("Apply to Selected Clips", .applyPreset, c.presetIsEffect),
                row("Apply Absolute (Replace Values)", .applyAbsolute, c.presetIsEffect),
                row("Apply Relative (Add to Clip)", .applyRelative, c.presetIsEffect),
                row(c.relativeDefault ? "Default Apply: Relative (switch to Absolute)" : "Default Apply: Absolute (switch to Relative)",
                    .toggleDefaultApply),
                row("Export…", .exportPreset, c.hasPreset),
                row("Import Presets…", .importPresets),
                row("Export as Pack…", .exportPack, c.hasPreset),
                row("Import Pack…", .importPack),
                .separator,      // destructive entry last
                row("Delete", .deletePreset, c.hasPreset)]
    }
}
