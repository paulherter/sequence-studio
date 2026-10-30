import SQCore
import SQRender
import SQText

extension RenderLayer {
    /// This text clip's layer with the footage fill of the text ref's style (`TextStyle.footageFill`) attached; the
    /// layer unchanged for a color fill. Playback and export build their text layers through it.
    public func withFootageFill(of ref: GeneratorRef) -> RenderLayer {
        guard let fill = TextGenerator.footageFill(ref: ref) else { return self }
        var l = self
        l.footageFill = fill == .stencil ? .stencil : .inverted
        return l
    }
}
