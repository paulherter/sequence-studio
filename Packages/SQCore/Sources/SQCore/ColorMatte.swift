import Foundation

/// Color Matte: a flat color layer for when there is no video. It is the `solid` generator the engine already
/// renders (transition dips, imported mattes), as an ordinary clip: move, trim, effects, opacity and blend modes work.
/// The payload is three display-encoded RGB bytes (`GeneratorRef.solid(rgb:)`), so no ProjectFile change.
public struct ColorMatteColor: Sendable, Hashable {
    public var r: UInt8, g: UInt8, b: UInt8
    public init(r: UInt8, g: UInt8, b: UInt8) { self.r = r; self.g = g; self.b = b }
    public static let `default` = ColorMatteColor(r: 40, g: 40, b: 46)
    public var bytes: [UInt8] { [r, g, b] }
}

extension GeneratorRef {
    public static func colorMatte(_ c: ColorMatteColor) -> GeneratorRef { .solid(rgb: c.bytes) }

    /// The color of a solid generator; nil for other kinds or a payload that is not three bytes.
    public var matteColor: ColorMatteColor? {
        guard kind == Self.solid, payload.count == 3 else { return nil }
        let b = [UInt8](payload)
        return ColorMatteColor(r: b[0], g: b[1], b: b[2])
    }
}

extension Clip {
    /// A Color Matte clip (solid generator).
    public var isColorMatte: Bool { generator?.kind == GeneratorRef.solid }
    public var matteColor: ColorMatteColor? { generator?.matteColor }
}

extension Project {
    /// Places a Color Matte on a video track (overwrite, like a drag onto the track). Returns the new clip's ID.
    /// Throws like `addGeneratorClip`.
    @discardableResult
    public mutating func addColorMatte(_ color: ColorMatteColor, name: String = "Color Matte", in timeline: Timeline.ID,
                                       at start: Time, track: Track.ID, duration: Time) throws -> Clip.ID {
        try addGeneratorClip(kind: GeneratorRef.solid, payload: Data(color.bytes), name: name.isEmpty ? "Color Matte" : name,
                             in: timeline, at: start, track: track, duration: duration)
    }

    /// Sets the color of a Color Matte clip. Throws `.clipNotFound` for any other clip.
    public mutating func setColorMatte(clipID: Clip.ID, _ color: ColorMatteColor) throws {
        let isMatte = timelines.contains { $0.tracks.contains { $0.clips.contains { $0.id == clipID && $0.isColorMatte } } }
        guard isMatte else { throw EditError.clipNotFound }
        try updateGenerator(clipID: clipID, payload: Data(color.bytes))
    }
}
