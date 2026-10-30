import Foundation
import Observation
import SQCore
import SQEditorSession

/// Built-in and user project templates. User templates are `.sqtemplate` files in
/// `~/Library/Application Support/Sequence Studio/Templates` (never inside a project file).
@MainActor @Observable
final class TemplateStore {
    private(set) var user: [ProjectTemplate] = []
    private let folder: TemplateFolder

    init(folder: TemplateFolder = TemplateStore.defaultFolder) {
        self.folder = folder
        reload()
    }

    nonisolated static var defaultFolder: TemplateFolder { .standard }

    var all: [ProjectTemplate] { ProjectTemplate.builtIn + user }

    func template(id: String) -> ProjectTemplate? { all.first { $0.id == id } }

    func reload() { user = folder.load() }

    /// Saves the sequence's format, track counts, variants and the project's Style Kit as a user template.
    @discardableResult
    func saveTemplate(from timeline: Timeline, name: String, styleKit: StyleKit? = nil) throws -> ProjectTemplate {
        let t = ProjectTemplate(capturing: timeline, name: name, styleKit: styleKit)
        try folder.save(t)
        reload()
        return t
    }

    func rename(_ t: ProjectTemplate, to name: String) throws {
        let free = ProjectTemplate.freeName(name, taken: all.filter { $0.id != t.id }.map(\.name))
        try folder.rename(t, to: free)
        reload()
    }

    func delete(_ t: ProjectTemplate) {
        try? folder.delete(t)
        reload()
    }
}
