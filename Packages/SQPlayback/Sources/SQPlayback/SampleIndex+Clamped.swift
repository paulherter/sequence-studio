import SQCore
import SQMedia

extension SampleIndex {
    /// The frame showing `sourceTime`, clamped to the first / last frame outside the media. The index must not be empty.
    func clampedFrame(at sourceTime: Time) -> Int {
        if let f = frame(at: sourceTime) { return f }
        return sourceTime < entries[0].pts ? 0 : count - 1
    }
}
