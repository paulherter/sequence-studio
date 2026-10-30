import Foundation
import SQCore

extension EditorSession {
    /// Lane drag-out: moves (or copies) layers of Graphic `source` to another Graphic or a new one, one undo step
    /// "Move Layer Out". Returns the receiving Graphic and the layers' IDs there; a refusal goes to `lastError`.
    @discardableResult
    public func moveGraphicsLayers(_ ids: [UUID], from source: Clip.ID, to dest: GraphicsLayerDestination,
                                   copy: Bool = false) -> (clip: Clip.ID, layers: [UUID])? {
        var landed: (clip: Clip.ID, layers: [UUID])?
        do { try perform(copy ? "Copy Layer Out" : "Move Layer Out") { landed = try $0.moveGraphicsLayers(ids, from: source, to: dest, copy: copy) } }
        catch { setError(Self.message(for: error)); return nil }
        return landed
    }
}
