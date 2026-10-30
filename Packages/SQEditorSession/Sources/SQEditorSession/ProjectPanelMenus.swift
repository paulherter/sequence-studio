import Foundation
import SQCore
import SQUIKit

/// SQ rows for the Project panel menus (empty area, bin, item, column header). Pure: no NSMenu, the panel maps `Action`s to calls.
/// Portable: the Mac `ProjectPanelView` and the shared `ProjectListView` (SQDrawShell) build the same rows.
public enum ProjectPanelMenus {
    public enum Action: Equatable, Sendable {
        case newFolder, newColorMatte, newSequence, importMedia, find, goUp, toggleHoverScrub
        case openInSource, openInTimeline, insert, overwrite, sequenceFromClip, makeSubclip, editOriginal
        case rename, deletePoster, reveal, replaceMedia, locateMedia, delete
        /// F7.3 source settings > Pixel Aspect: nil = From File.
        case setPixelAspect(PixelAspect?)
        case customPixelAspect
        /// Source settings > Deinterlace of the selected interlaced media items.
        case setDeinterlace(Bool)
        /// nil: back to the default label of the item's type.
        case setLabel(LabelColor?)
        case selectLabelGroup(LabelColor)
        case toggleColumn(ProjectPanelModel.Column)
        case resetColumns
        /// F7.10: the file channels the media items play (nil = the file's layout).
        case setAudioChannels(AudioChannelMap?)
        /// F7.16: the selected media items become one Angles clip.
        case createAnglesClip
        /// The selected media items fill the slots of the active sequence (Fill Reel…).
        case fillReel
        /// Like Delete, but media a sequence still uses goes offline and its clips stay.
        case clearUsedMedia
        /// The sound of the single selected media item as its own M4A item.
        case extractAudio
        /// Variable-frame-rate media items become constant-rate copies the items take over (background job).
        case conformToConstantFrameRate
    }

    /// What the menu needs to know about the clicked selection and the panel.
    public struct Context: Equatable {
        public var media: [MediaRef.ID]
        public var hasBin: Bool
        public var hasSequence: Bool
        public var targetCount: Int
        public var allMediaOnline: Bool
        public var singleMediaOffline: Bool
        public var singleMediaHasPoster: Bool
        /// The single media item has a Source In or Out (Make Subclip needs one).
        public var singleMediaHasMarks: Bool
        /// Label shared by all non-bin targets (nil when mixed or none); the label of the first non-bin target.
        public var sharedLabel: LabelColor?
        public var firstLabel: LabelColor?
        public var hasNonBinTarget: Bool
        public var isIconView: Bool
        public var canGoUp: Bool
        public var hoverScrub: Bool
        /// F7.3: the pixel aspect of the selected media items; nil = no Pixel Aspect row (no picture, offline mix...).
        public var pixelAspect: PixelAspectChoices.State?
        /// F7.10: channels of the selected media's sound (0 = none, or the items differ) and the map they share.
        public var audioChannels = 0
        public var audioChannelMap: AudioChannelMap?
        /// Deinterlace of the selected media items, all interlaced (true = on for all); nil = no Deinterlace row.
        public var deinterlace: Bool?
        /// A selected media item is still used by a sequence (Delete would be blocked: Clear Used Media is offered).
        public var anyMediaUsed = false
        /// The active sequence has clips to use as slots (Fill Reel…).
        public var canFillReel = false
        /// A selected media item is variable-frame-rate video (Conform to Constant Frame Rate).
        public var canConformToCFR = false

        public init(media: [MediaRef.ID] = [], hasBin: Bool = false, hasSequence: Bool = false, targetCount: Int = 0,
                    allMediaOnline: Bool = false, singleMediaOffline: Bool = false, singleMediaHasPoster: Bool = false,
                    singleMediaHasMarks: Bool = false, sharedLabel: LabelColor? = nil, firstLabel: LabelColor? = nil, hasNonBinTarget: Bool = false,
                    isIconView: Bool = false, canGoUp: Bool = false, hoverScrub: Bool = false,
                    pixelAspect: PixelAspectChoices.State? = nil) {
            self.pixelAspect = pixelAspect
            self.media = media; self.hasBin = hasBin; self.hasSequence = hasSequence; self.targetCount = targetCount
            self.allMediaOnline = allMediaOnline; self.singleMediaOffline = singleMediaOffline
            self.singleMediaHasPoster = singleMediaHasPoster; self.singleMediaHasMarks = singleMediaHasMarks; self.sharedLabel = sharedLabel; self.firstLabel = firstLabel
            self.hasNonBinTarget = hasNonBinTarget; self.isIconView = isIconView; self.canGoUp = canGoUp; self.hoverScrub = hoverScrub
        }
    }

    /// Shortcut text of an editor command in the current key map ("" when unbound or not showable).
    @MainActor public static func shortcut(_ command: EditorCommand, map: CommandMap = .current) -> String {
        #if canImport(AppKit)
        CommandMenuKeys.shortcut(command, map: map)
        #else
        map.binding(for: command).map { KeyBindingText.text($0) } ?? ""
        #endif
    }

    /// Premiere's three Project menus in one place: empty area, bin, item. Entries for features we do not have are left out.
    @MainActor
    public static func items(_ c: Context, shortcut: (EditorCommand) -> String = { shortcut($0) },
                             run: @escaping @MainActor (Action) -> Void) -> [SQMenuItem] {
        var rows: [SQMenuItem] = []
        func add(_ title: String, _ a: Action, enabled: Bool = true, key: EditorCommand? = nil) {
            rows.append(SQMenuItem(title: title, shortcut: key.map(shortcut) ?? "", isEnabled: enabled, action: { run(a) }))
        }
        func sep() { rows.append(.separator) }
        if c.targetCount == 0 {
            add("New Folder", .newFolder, key: .newBin)
            add("New Sequence…", .newSequence, key: .newSequence)
            add("New Color Matte…", .newColorMatte)
            sep()
            add("Import…", .importMedia, key: .importMedia)
            sep()
            add("Find…", .find, key: .find)
            if c.isIconView {
                add("Up One Level", .goUp, enabled: c.canGoUp)
                rows.append(SQMenuItem(title: "Hover Scrub", isChecked: c.hoverScrub, action: { run(.toggleHoverScrub) }))
            }
            return rows
        }
        let single = c.media.count == 1
        if !c.media.isEmpty && !c.hasBin && !c.hasSequence {
            add("Open in Source", .openInSource, enabled: single && c.allMediaOnline)
            sep()
            add("Insert", .insert, enabled: c.allMediaOnline, key: .insert)
            add("Overwrite", .overwrite, enabled: c.allMediaOnline, key: .overwrite)
            add("New Sequence From Clip", .sequenceFromClip, enabled: single && c.allMediaOnline)
            add("Make Subclip", .makeSubclip, enabled: single && c.singleMediaHasMarks, key: .makeSubclip)
            if c.media.count >= 2 { add("Create Angles Clip…", .createAnglesClip, enabled: c.allMediaOnline) }
            if c.canFillReel { add("Fill Reel…", .fillReel, enabled: c.allMediaOnline) }
            sep()
        } else if c.hasSequence && !c.hasBin && c.media.isEmpty {
            add("Open in Timeline", .openInTimeline, enabled: c.targetCount == 1)
            sep()
            add("Insert", .insert, key: .insert)
            add("Overwrite", .overwrite, key: .overwrite)
            sep()
        }
        if c.hasBin && c.targetCount == 1 { add("New Folder", .newFolder, key: .newBin); sep() }
        add("Rename", .rename, enabled: c.targetCount == 1)
        if single, !c.hasBin, !c.hasSequence, c.singleMediaHasPoster { add("Delete Poster Frame", .deletePoster) }
        if c.hasNonBinTarget {
            sep()
            rows.append(SQMenuItem(title: "Label", submenu: labelItems(c, run: run)))
            if let first = c.firstLabel {
                rows.append(SQMenuItem(title: "Select Label Group", action: { run(.selectLabelGroup(first)) }))
            }
        }
        if !c.media.isEmpty {
            sep()
            if let pa = c.pixelAspect {
                rows.append(SQMenuItem(title: "Pixel Aspect", submenu: PixelAspectChoices.items(pa, pick: { run(.setPixelAspect($0)) },
                                                                                          custom: { run(.customPixelAspect) })))
            }
            if let on = c.deinterlace {
                rows.append(SQMenuItem(title: "Deinterlace", isChecked: on, action: { run(.setDeinterlace(!on)) }))
            }
            #if os(Windows)
            add("Show in Explorer", .reveal)
            #else
            add("Reveal in Finder", .reveal)
            #endif
            add("Edit Original", .editOriginal, enabled: c.allMediaOnline, key: .editOriginal)
            if single, c.singleMediaOffline { add("Locate…", .locateMedia) }
            if single { add(c.singleMediaOffline ? "Reconnect Media…" : "Replace Media…", .replaceMedia) }
            let channels = AudioChannelsMenu.items(channels: c.audioChannels, current: c.audioChannelMap) { run(.setAudioChannels($0)) }
            if !channels.isEmpty { rows.append(SQMenuItem(title: "Audio Channels", submenu: channels)) }
            if single, c.audioChannels > 0 { add("Extract Audio", .extractAudio, enabled: c.allMediaOnline) }
            if c.canConformToCFR { add("Conform to Constant Frame Rate", .conformToConstantFrameRate, enabled: c.allMediaOnline) }
        }
        sep()      // destructive entries last
        if c.anyMediaUsed { add("Clear Used Media", .clearUsedMedia) }
        add("Delete", .delete, key: .deleteProjectItems)
        return rows
    }

    @MainActor
    static func labelItems(_ c: Context, run: @escaping @MainActor (Action) -> Void) -> [SQMenuItem] {
        var rows = [SQMenuItem(title: "Default", action: { run(.setLabel(nil)) }), .separator]
        for l in LabelColor.allCases {
            rows.append(SQMenuItem(title: l.displayName, icon: .swatch(l.rgb), isChecked: c.sharedLabel == l, action: { run(.setLabel(l)) }))
        }
        return rows
    }

    /// Column header right-click: toggle each optional column (Name is fixed), then Reset Columns.
    @MainActor
    public static func headerItems(isVisible: (ProjectPanelModel.Column) -> Bool,
                                   run: @escaping @MainActor (Action) -> Void) -> [SQMenuItem] {
        var rows: [SQMenuItem] = []
        for col in ProjectPanelModel.Column.allCases where col != .name {
            rows.append(SQMenuItem(title: col.title, isChecked: isVisible(col), action: { run(.toggleColumn(col)) }))
        }
        rows += [.separator, SQMenuItem(title: "Reset Columns", action: { run(.resetColumns) })]
        return rows
    }
}
