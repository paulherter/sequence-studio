import SQCore

extension EditorSession {
    /// The source color space a clip renders with: its override, else the media's detection under the project input,
    /// else Rec. 709 (what Color Match and Auto check).
    public func colorSource(of clip: Clip) -> ColorSpaceID {
        clip.color.source ?? media.info(of: clip.media)?.applyingProjectInput(project.inputColorSpace).colorSpace ?? .rec709
    }
}
