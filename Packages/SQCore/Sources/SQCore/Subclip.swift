import Foundation

// Make Subclip (v57): a range of a media item becomes its own Project item, filed right after its parent. It is an
// ordinary `MediaRef` over the same file (so playback, thumbnails, drag to the timeline and relink treat it like any media)
// with `subclip` set. Its bounds are soft, like Premiere with "Restrict trims to subclip boundaries" off: the range seeds the
// item's In/Out and poster frame, and clips cut from it can still be trimmed into the rest of the file.

/// Where a subclip comes from.
public struct Subclip: Sendable, Hashable, Codable {
    /// The media item over the whole file (a subclip of a subclip points at the file's item, never at another subclip).
    public var parent: MediaRef.ID
    /// The part of the media it covers (media time).
    public var range: TimeRange
    public init(parent: MediaRef.ID, range: TimeRange) { self.parent = parent; self.range = range }
}

extension MediaRef {
    /// True for an item made with Make Subclip.
    public var isSubclip: Bool { subclip != nil }
}

extension Project {
    /// Make Subclip: a new media item over `range` of media `id` (clamped to the media's length when known), named `name`
    /// or "<parent> Subclip" (" 2", " 3"... when taken), filed right after `id` in its bin. Its In/Out marks are `range`
    /// and its poster frame the range start. Returns the new item's id. Unknown media: `.clipNotFound`; a range with
    /// nothing left after clamping: `.emptyClip`.
    @discardableResult
    public mutating func makeSubclip(of id: MediaRef.ID, range: TimeRange, name: String? = nil) throws -> MediaRef.ID {
        guard let source = media(id) else { throw EditError.clipNotFound }
        let parentID = source.subclip?.parent ?? id
        let parent = media(parentID) ?? source
        var start = max(range.start, .zero), end = range.end
        if let d = parent.duration { end = min(end, d); start = min(start, d) }
        guard end > start else { throw EditError.emptyClip }
        let r = TimeRange(start: start, end: end)

        let base = parent.name + " Subclip"
        let taken = Set(media.map(\.name))
        var label = base, n = 2
        while taken.contains(label) { label = "\(base) \(n)"; n += 1 }
        let given = name?.trimmingCharacters(in: .whitespaces) ?? ""

        var ref = MediaRef(name: given.isEmpty ? label : given, path: parent.path, bookmark: parent.bookmark,
                           fingerprint: parent.fingerprint, duration: parent.duration, info: parent.info, label: source.label,
                           posterTime: r.start)
        ref.subclip = Subclip(parent: parentID, range: r)
        media.append(ref)
        if let bin = rootBin.parent(of: .media(id)) {
            rootBin.modify(bin) { b in
                let i = b.children.firstIndex { $0.ref == .media(id) }.map { $0 + 1 } ?? b.children.count
                b.children.insert(.media(ref.id), at: i)
            }
        } else {
            rootBin.children.append(.media(ref.id))
        }
        sourceMarks[ref.id] = SourceMarks(markIn: r.start, markOut: r.end)
        return ref.id
    }
}
