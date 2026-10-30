import Foundation

/// F7.3: the shape of one stored pixel, width / height, as an exact ratio (2:1 = a 2x anamorphic lens, 4:3 = HDV or a
/// 1.33x lens, 1:1 = square). The picture is shown `stored width x ratio` wide and its stored height high: the engines
/// draw the decoded frame at that size inside the source-to-sequence transform (no pass of its own).
///
/// Always reduced and within 1:4 ... 4:1; anything else is a broken tag and has no value (callers fall back to square).
public struct PixelAspect: Hashable, Sendable, Codable {
    public let num: Int, den: Int

    public static let square = PixelAspect(unchecked: 1, 1)
    /// What the source settings offer: square and the common anamorphic squeeze factors (1.33 is the exact 4:3).
    public static let presets: [PixelAspect] = [
        .square, PixelAspect(unchecked: 5, 4), PixelAspect(unchecked: 4, 3), PixelAspect(unchecked: 3, 2),
        PixelAspect(unchecked: 8, 5), PixelAspect(unchecked: 9, 5), PixelAspect(unchecked: 2, 1)]

    private init(unchecked num: Int, _ den: Int) { self.num = num; self.den = den }

    /// nil for a ratio that is not positive or lies outside 1:4 ... 4:1.
    public init?(_ num: Int, _ den: Int) {
        guard num > 0, den > 0, num <= den.multipliedReportingOverflow(by: 4).partialValue,
              den <= num.multipliedReportingOverflow(by: 4).partialValue,
              !den.multipliedReportingOverflow(by: 4).overflow, !num.multipliedReportingOverflow(by: 4).overflow else { return nil }
        var a = num, b = den
        while b != 0 { (a, b) = (b, a % b) }
        self.num = num / a; self.den = den / a
    }

    public var isSquare: Bool { num == den }
    /// For display and for import mapping only; sizes are computed from the ratio.
    public var value: Double { Double(num) / Double(den) }

    /// Width in whole pixels at which `stored` pixels of this shape are shown. Square pixels keep the stored width; any
    /// other shape gives the nearest even number (at least 2): this one value is the layer size in playback and export
    /// and the width of a sequence made from the clip, and encoders take even sizes only (720 at 10:11 is 654).
    public func displayWidth(ofStored stored: Int) -> Int {
        guard stored > 0 else { return 0 }
        if isSquare { return stored }
        let (wide, overflow) = stored.multipliedReportingOverflow(by: num)
        guard !overflow else { return stored }
        return max(2, 2 * ((wide + den) / (2 * den)))
    }

    private enum CodingKeys: String, CodingKey { case num, den }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        guard let v = PixelAspect(try c.decode(Int.self, forKey: .num), try c.decode(Int.self, forKey: .den)) else {
            throw DecodingError.dataCorruptedError(forKey: .num, in: c, debugDescription: "pixel aspect outside 1:4 ... 4:1")
        }
        self = v
    }
}

extension VideoTrackInfo {
    /// The pixel aspect the picture is shown with: the one chosen for the media item, else the file's own.
    public var displayPixelAspect: PixelAspect { pixelAspectOverride ?? pixelAspect }

    /// Stored width desqueezed, before any rotation: with `height`, the size the decoded frame is drawn at for Scale 1.
    public var desqueezedWidth: Int { displayPixelAspect.displayWidth(ofStored: width) }

    /// A decoder's info of a file, read the way the project reads that media item (`project` = `MediaRef.info.video`):
    /// the item's pixel aspect and its override replace the decoder's. An item probed before pixel aspect existed says
    /// square, so old projects keep their picture. nil (media the project has no info for: a legacy item, a file not yet
    /// probed) is square too: only the project decides, a picture never changes shape by being opened.
    public func adoptingPixelAspect(of project: VideoTrackInfo?) -> VideoTrackInfo {
        var out = self
        out.pixelAspect = project?.pixelAspect ?? .square
        out.pixelAspectOverride = project?.pixelAspectOverride
        return out
    }
}

extension Project {
    /// The pixel aspect `id`'s picture is shown with; nil for unknown media and media without a (probed) picture.
    public func pixelAspect(of id: MediaRef.ID) -> PixelAspect? { media(id)?.info?.video?.displayPixelAspect }

    /// Source settings > Pixel Aspect: how `id`'s pixels are read from now on, for every clip of it (a setting of the
    /// media item, not of a clip; subclips share their file's setting). nil = what the file says. Clips keep their Scale,
    /// so the picture changes width where it is used. Returns whether anything changed; false for unknown media and for
    /// media without a probed picture.
    @discardableResult
    public mutating func setPixelAspect(_ aspect: PixelAspect?, for id: MediaRef.ID) -> Bool {
        guard let item = media(id) else { return false }
        let file = item.subclip?.parent ?? id
        var changed = false
        for i in media.indices where media[i].id == file || media[i].subclip?.parent == file {
            guard let v = media[i].info?.video else { continue }
            let value = aspect == v.pixelAspect ? nil : aspect
            guard value != v.pixelAspectOverride else { continue }
            media[i].info?.video?.pixelAspectOverride = value
            changed = true
        }
        return changed
    }
}
