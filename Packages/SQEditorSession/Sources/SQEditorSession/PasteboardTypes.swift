import AppKit

// Drag payload types shared by the panels, the timeline and the monitor (moved here from TemplateListPanelView and
// ProjectPanelView so every UI module sees them; DECISIONS "SQEditorUI split").
extension NSPasteboard.PasteboardType {
    /// An effect dragged from the Effects panel: the effect id.
    public static let sequenceEffectID = NSPasteboard.PasteboardType("com.sequencestudio.effect-id")
    /// A user folder row of the Effects panel being dragged to a new place in the list: the folder's UUID string.
    public static let sequenceEffectFolder = NSPasteboard.PasteboardType("com.sequencestudio.effect-folder")
    /// A text template dragged from the Library: the `TextTemplateCatalog` entry id as a string.
    public static let sequenceTextTemplate = NSPasteboard.PasteboardType("com.sequencestudio.text-template")
    /// The item IDs dragged out of the Project panel (see `ProjectPanelModel.encodeItems`).
    public static let sequenceMediaIDs = NSPasteboard.PasteboardType(ProjectPanelModel.pasteboardTypeName)
}
