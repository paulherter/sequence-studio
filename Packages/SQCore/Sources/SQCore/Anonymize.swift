import Foundation

// F7.11 Anonymize (pure part). The command covers a person with a Mosaic or a blur: every person is one Magic mask (the
// existing tracker follows the person), the cover is one effect that takes those masks as its input. Face and Skin narrow
// the person's matte per frame (`AnonymizeRefiner`); frames where that was a guess are listed for a manual check
// (`AnonymizeCheck`). Detection (Vision) sits in SQAnalysis.

/// What of a person is covered. Also what a mask made by Anonymize stores (`MagicSelection.part`).
public enum AnonymizeTarget: String, Sendable, Hashable, Codable, CaseIterable {
    case face, person, skin

    public var title: String {
        switch self {
        case .face: "Face"
        case .person: "Whole Person"
        case .skin: "Skin"
        }
    }

    /// Name of the masks a run makes ("Face 1", "Person 2").
    public var maskName: String {
        switch self {
        case .face: "Face"
        case .person: "Person"
        case .skin: "Skin"
        }
    }
}

/// What covers it.
public enum AnonymizeCover: String, Sendable, Hashable, CaseIterable {
    case mosaic, blur
    public var title: String { self == .mosaic ? "Mosaic" : "Blur" }
}

/// A box in fractions of the upright frame, origin top left, y down.
public struct AnonymizeBox: Sendable, Hashable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var center: Vec2 { Vec2(x + width / 2, y + height / 2) }

    /// The middle of the box: `share` of its width and height.
    func inner(_ share: Double) -> AnonymizeBox {
        AnonymizeBox(x: x + width * (1 - share) / 2, y: y + height * (1 - share) / 2, width: width * share, height: height * share)
    }

    /// Texel range of the box in a `w` x `h` grid (at least one texel, inside the grid); nil when it lies outside.
    func texels(_ w: Int, _ h: Int) -> (x: Range<Int>, y: Range<Int>)? {
        let x0 = max(Int((x * Double(w)).rounded(.down)), 0), y0 = max(Int((y * Double(h)).rounded(.down)), 0)
        let x1 = min(Int(((x + width) * Double(w)).rounded(.up)), w), y1 = min(Int(((y + height) * Double(h)).rounded(.up)), h)
        guard x0 < w, y0 < h, x1 > 0, y1 > 0 else { return nil }
        return (x0..<max(x1, x0 + 1), y0..<max(y1, y0 + 1))
    }
}

/// A detected face: its box and the detector's confidence 0...1.
public struct AnonymizeFace: Sendable, Hashable {
    public var box: AnonymizeBox
    public var confidence: Double
    public init(box: AnonymizeBox, confidence: Double) { self.box = box; self.confidence = confidence }
}

/// A person found on a frame: the segmented object, a point on it (a Magic pick there selects it), its extent and its
/// face when one was detected.
public struct AnonymizePerson: Sendable, Hashable {
    public var label: UInt8
    public var point: Vec2
    public var box: AnonymizeBox
    public var face: AnonymizeFace?
    public init(label: UInt8, point: Vec2, box: AnonymizeBox, face: AnonymizeFace?) {
        self.label = label; self.point = point; self.box = box; self.face = face
    }
}

public enum AnonymizePeople {
    /// A detected box belongs to the object that fills at least this share of it.
    static let minShare = 0.15

    /// The segmented objects that are people: those under a detected face or body box. Left to right. Objects no detection
    /// points at (things, animals) are left out.
    public static func find(labels: InstanceLabels, bodies: [AnonymizeBox], faces: [AnonymizeFace]) -> [AnonymizePerson] {
        var found: [UInt8] = []
        var faceOf: [UInt8: AnonymizeFace] = [:]
        for f in faces.sorted(by: { $0.confidence > $1.confidence }) {
            guard let l = dominant(labels, in: f.box.inner(0.5)), faceOf[l] == nil else { continue }
            faceOf[l] = f
            found.append(l)
        }
        for b in bodies {
            guard let l = dominant(labels, in: b), !found.contains(l) else { continue }
            found.append(l)
        }
        let people = found.compactMap { l -> AnonymizePerson? in
            guard let box = extent(of: l, in: labels) else { return nil }
            let face = faceOf[l]
            guard let p = point(on: l, in: labels, near: face?.box.center ?? box.center) else { return nil }
            return AnonymizePerson(label: l, point: p, box: box, face: face)
        }
        return people.sorted { $0.box.center.x < $1.box.center.x }
    }

    /// The object that fills most of `box` (at least `minShare` of it), nil when that is the background.
    static func dominant(_ l: InstanceLabels, in box: AnonymizeBox) -> UInt8? {
        guard let r = box.texels(l.width, l.height) else { return nil }
        var count = [Int](repeating: 0, count: 256)
        for y in r.y { for x in r.x { count[Int(l.labels[y * l.width + x])] += 1 } }
        var best = 0
        for i in 1..<256 where count[i] > count[best] || best == 0 && count[i] > 0 { best = i }
        guard best != 0, Double(count[best]) >= minShare * Double(r.x.count * r.y.count) else { return nil }
        return UInt8(best)
    }

    static func extent(of label: UInt8, in l: InstanceLabels) -> AnonymizeBox? {
        var x0 = l.width, x1 = -1, y0 = l.height, y1 = -1
        for y in 0..<l.height {
            for x in 0..<l.width where l.labels[y * l.width + x] == label {
                x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
            }
        }
        guard x1 >= 0 else { return nil }
        let w = Double(l.width), h = Double(l.height)
        return AnonymizeBox(x: Double(x0) / w, y: Double(y0) / h, width: Double(x1 - x0 + 1) / w, height: Double(y1 - y0 + 1) / h)
    }

    /// The texel center of `label` nearest `p` (frame fractions).
    static func point(on label: UInt8, in l: InstanceLabels, near p: Vec2) -> Vec2? {
        var best: Vec2?
        var bestD = Double.infinity
        let w = Double(l.width), h = Double(l.height)
        for y in 0..<l.height {
            for x in 0..<l.width where l.labels[y * l.width + x] == label {
                let q = Vec2((Double(x) + 0.5) / w, (Double(y) + 0.5) / h)
                let dx = (q.x - p.x) * w, dy = (q.y - p.y) * h
                let d = dx * dx + dy * dy
                if d < bestD { bestD = d; best = q }
            }
        }
        return best
    }
}

/// One entry of the list for a manual check: on these frames the cover of a person is a guess or missing.
public struct AnonymizeCheck: Sendable, Hashable {
    public enum Reason: String, Sendable, Hashable, CaseIterable {
        /// The tracker lost the person: from here to the clip's edge the cover is the last followed matte, enlarged
        /// (`AnonymizeFallback`), so the person may be outside it.
        case lost
        /// No face was detected: the cover sits where the face was last seen on the person (or at the head end).
        case noFace
        /// A face was detected with low confidence.
        case lowConfidence
        /// Skin could not be told apart: the whole person is covered.
        case wholePerson

        public var text: String {
            switch self {
            case .lost: "Person not followed: the cover stays where they were last seen, enlarged"
            case .noFace: "No face detected: the cover is placed by estimate"
            case .lowConfidence: "Face detected with low confidence"
            case .wholePerson: "Skin not told apart: the whole person is covered"
            }
        }

        /// The person may be visible on these frames: listed first and never cut from the list.
        public var isCritical: Bool { self == .lost }
    }

    /// Index of the person in the run (0 = first).
    public var person: Int
    public var reason: Reason
    /// Source seconds of the first and last frame.
    public var from: Double
    public var to: Double
    public init(person: Int, reason: Reason, from: Double, to: Double) {
        self.person = person; self.reason = reason; self.from = from; self.to = to
    }
}

public enum AnonymizeReport {
    /// Flagged frames as ranges: frames with the same reason that follow each other (at most `gap` seconds apart, with half
    /// a gap of slack) are one entry. In time order.
    public static func ranges(person: Int, flags: [(pts: Double, reason: AnonymizeCheck.Reason)], gap: Double) -> [AnonymizeCheck] {
        var out: [AnonymizeCheck] = []
        for f in flags.sorted(by: { $0.pts < $1.pts }) {
            if let i = out.lastIndex(where: { $0.reason == f.reason }), f.pts - out[i].to <= gap * 1.5 + 1e-6 {
                out[i].to = f.pts
            } else {
                out.append(AnonymizeCheck(person: person, reason: f.reason, from: f.pts, to: f.pts))
            }
        }
        return out.sorted { $0.from < $1.from }
    }
}

/// Narrows a person's matte to the face or to the skin, frame by frame in tracking order. It errs toward covering more:
/// a frame without a usable detection keeps the last known place (Face) or tone (Skin), or the whole person, and is
/// flagged for the check list.
public struct AnonymizeRefiner: Sendable {
    public let part: AnonymizeTarget
    /// Faces below this confidence are still used, and flagged.
    public static let minFaceConfidence = 0.5
    /// A face belongs to the person when the person's matte fills at least this much of the face box's middle.
    static let minFaceCover = 0.3

    /// The last face box relative to the person's extent (fractions of it).
    private var lastFace: AnonymizeBox?
    private var tone: SkinTone?

    public init(part: AnonymizeTarget) { self.part = part }

    /// Continues from mattes stored before (Track from a frame in the middle of a clip, or a correction click): where the
    /// face was on `person` is read from the stored face matte `narrowed` of the same frame, so a first frame without a
    /// detected face is placed there and not at the head end. Skin learns its tone from the next detected face.
    public mutating func seed(person: SubjectMatte, narrowed: SubjectMatte) {
        guard part == .face, let body = Self.extent(person), let e = Self.extent(narrowed) else { return }
        // The stored ellipse is wider than the face box it was made from (`ellipse`); undone here, so guesses do not grow
        // with every Track.
        let w = e.width / (2 * 0.95 * 0.94), h = e.height / (2 * 1.05 * 0.94)
        let box = AnonymizeBox(x: e.center.x - w / 2, y: e.center.y + 0.08 * h - h / 2, width: w, height: h)
        lastFace = AnonymizeBox(x: (box.x - body.x) / body.width, y: (box.y - body.y) / body.height,
                                width: box.width / body.width, height: box.height / body.height)
    }

    /// The face place remembered so far (relative to the person's extent), nil before a face was seen or seeded.
    var rememberedFace: AnonymizeBox? { lastFace }

    public mutating func refine(person: SubjectMatte, faces: [AnonymizeFace], guide: MagicGuide?) -> (matte: SubjectMatte, flag: AnonymizeCheck.Reason?) {
        switch part {
        case .person: return (person, nil)
        case .face: return face(person, faces)
        case .skin: return skin(person, faces, guide)
        }
    }

    // MARK: Face

    private mutating func face(_ person: SubjectMatte, _ faces: [AnonymizeFace]) -> (matte: SubjectMatte, flag: AnonymizeCheck.Reason?) {
        guard let body = Self.extent(person) else { return (person, .wholePerson) }
        if let f = Self.face(of: person, faces) {
            lastFace = AnonymizeBox(x: (f.box.x - body.x) / body.width, y: (f.box.y - body.y) / body.height,
                                    width: f.box.width / body.width, height: f.box.height / body.height)
            return (Self.ellipse(f.box, person.width, person.height), f.confidence < Self.minFaceConfidence ? .lowConfidence : nil)
        }
        let guess: AnonymizeBox
        if let r = lastFace {
            guess = AnonymizeBox(x: body.x + r.x * body.width, y: body.y + r.y * body.height,
                                 width: r.width * body.width, height: r.height * body.height)
        } else {
            // Never seen: the head end of the person (generous for a close-up, where the person is as wide as tall).
            let bw = body.width * Double(person.width), bh = body.height * Double(person.height)
            let h = min(bh, max(bh / 5, bw * 0.9))
            guess = AnonymizeBox(x: body.x, y: body.y, width: body.width, height: h / Double(person.height))
        }
        return (Self.ellipse(guess, person.width, person.height), .noFace)
    }

    /// The face on this person: the one whose middle the matte fills most.
    static func face(of person: SubjectMatte, _ faces: [AnonymizeFace]) -> AnonymizeFace? {
        var best: (AnonymizeFace, Double)?
        for f in faces {
            guard let r = f.box.inner(0.5).texels(person.width, person.height) else { continue }
            var s = 0.0
            for y in r.y { for x in r.x { s += Double(person[x, y]) } }
            let cover = s / Double(r.x.count * r.y.count)
            if cover >= minFaceCover, cover > (best?.1 ?? 0) { best = (f, cover) }
        }
        return best?.0
    }

    /// Extent of the matte (values from one half) in frame fractions.
    static func extent(_ m: SubjectMatte) -> AnonymizeBox? {
        var x0 = m.width, x1 = -1, y0 = m.height, y1 = -1
        for y in 0..<m.height {
            for x in 0..<m.width where m.values[y * m.width + x] >= 0.5 {
                x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
            }
        }
        guard x1 >= 0 else { return nil }
        let w = Double(m.width), h = Double(m.height)
        return AnonymizeBox(x: Double(x0) / w, y: Double(y0) / h, width: Double(x1 - x0 + 1) / w, height: Double(y1 - y0 + 1) / h)
    }

    /// A soft ellipse around `box`: the whole box is covered, with room for hair, ears and chin (a detector's face box ends
    /// at the brow and the chin).
    static func ellipse(_ box: AnonymizeBox, _ w: Int, _ h: Int) -> SubjectMatte {
        let cx = box.center.x * Double(w), cy = (box.center.y - box.height * 0.08) * Double(h)
        let rx = max(box.width * Double(w) * 0.95, 1.5), ry = max(box.height * Double(h) * 1.05, 1.5)
        var v = [Float](repeating: 0, count: w * h)
        let y0 = max(Int(cy - ry) - 1, 0), y1 = min(Int(cy + ry) + 2, h)
        let x0 = max(Int(cx - rx) - 1, 0), x1 = min(Int(cx + rx) + 2, w)
        guard y0 < y1, x0 < x1 else { return SubjectMatte(width: w, height: h, values: v) }
        for y in y0..<y1 {
            for x in x0..<x1 {
                let dx = (Double(x) + 0.5 - cx) / rx, dy = (Double(y) + 0.5 - cy) / ry
                let d = (dx * dx + dy * dy).squareRoot()
                v[y * w + x] = Float(min(max((1 - d) / 0.12, 0), 1))
            }
        }
        return SubjectMatte(width: w, height: h, values: v)
    }

    // MARK: Skin

    /// A skin tone as chroma (Cb, Cr around 0) and how far from it still counts.
    struct SkinTone: Sendable, Hashable {
        var cb: Double, cr: Double, radius: Double
        /// A wide middle of human skin chroma, used until a face was seen.
        static let generic = SkinTone(cb: -0.10, cr: 0.10, radius: 0.09)
        func matches(_ c: (cb: Double, cr: Double)) -> Bool {
            let a = c.cb - cb, b = c.cr - cr
            return a * a + b * b <= radius * radius
        }
    }

    static func chroma(_ g: MagicGuide, _ x: Int, _ y: Int) -> (cb: Double, cr: Double) {
        let i = (y * g.width + x) * 3
        let r = Double(g.rgb[i]), gr = Double(g.rgb[i + 1]), b = Double(g.rgb[i + 2])
        return (-0.169 * r - 0.331 * gr + 0.5 * b, 0.5 * r - 0.419 * gr - 0.081 * b)
    }

    /// The tone of the face: the middle of its box, where the person's matte is.
    static func tone(of face: AnonymizeBox, person: SubjectMatte, guide g: MagicGuide) -> SkinTone? {
        guard let r = face.inner(0.5).texels(g.width, g.height) else { return nil }
        var n = 0.0, sb = 0.0, sr = 0.0, sbb = 0.0, srr = 0.0
        for y in r.y {
            for x in r.x {
                guard person.sample(u: (Double(x) + 0.5) / Double(g.width), v: (Double(y) + 0.5) / Double(g.height)) >= 0.5 else { continue }
                let c = chroma(g, x, y)
                n += 1; sb += c.cb; sr += c.cr; sbb += c.cb * c.cb; srr += c.cr * c.cr
            }
        }
        guard n >= 4 else { return nil }
        let mb = sb / n, mr = sr / n
        let spread = (max(sbb / n - mb * mb, 0) + max(srr / n - mr * mr, 0)).squareRoot()
        return SkinTone(cb: mb, cr: mr, radius: min(max(2.5 * spread, 0.05), 0.12))
    }

    private mutating func skin(_ person: SubjectMatte, _ faces: [AnonymizeFace], _ guide: MagicGuide?) -> (matte: SubjectMatte, flag: AnonymizeCheck.Reason?) {
        guard let g = guide else { return (person, .wholePerson) }
        let w = person.width, h = person.height
        let face = Self.face(of: person, faces)
        var flag: AnonymizeCheck.Reason? = .noFace
        if let f = face, let t = Self.tone(of: f.box, person: person, guide: g) {
            tone = t
            flag = f.confidence < Self.minFaceConfidence ? .lowConfidence : nil
        }
        let t = tone ?? .generic
        var on = [Bool](repeating: false, count: w * h)
        var any = false
        for y in 0..<h {
            let gy = min(Int((Double(y) + 0.5) / Double(h) * Double(g.height)), g.height - 1)
            for x in 0..<w where person.values[y * w + x] >= 0.5 {
                let gx = min(Int((Double(x) + 0.5) / Double(w) * Double(g.width)), g.width - 1)
                if t.matches(Self.chroma(g, gx, gy)) { on[y * w + x] = true; any = true }
            }
        }
        // The face itself counts as skin whatever its color (eyes, beard, glasses, make-up).
        if let f = face, let r = f.box.texels(w, h) {
            for y in r.y { for x in r.x where person.values[y * w + x] >= 0.5 { on[y * w + x] = true; any = true } }
        }
        guard any else { return (person, .wholePerson) }
        // Close holes inside skin (tattoos, jewelry, shadows), then one texel of room; never outside the person.
        let r = max(2, max(w, h) / 24)
        let closed = Self.grow(Self.grow(Self.grow(on, w, h, r, to: true), w, h, r, to: false), w, h, 1, to: true)
        var v = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) where closed[i] { v[i] = person.values[i] }
        let out = SubjectMatte(width: w, height: h, values: v)
        return out.isBlank ? (person, .wholePerson) : (out, flag)
    }

    /// Grows the `to` texels by `r` (a square): `to` true = dilate, false = erode. Outside the grid counts as not `to`.
    static func grow(_ m: [Bool], _ w: Int, _ h: Int, _ r: Int, to: Bool) -> [Bool] {
        var a = m
        for y in 0..<h {
            let row = y * w
            var last = Int.min / 2
            for x in 0..<w { if m[row + x] == to { last = x }; if x - last <= r { a[row + x] = to } }
            last = Int.max / 2
            for x in stride(from: w - 1, through: 0, by: -1) { if m[row + x] == to { last = x }; if last - x <= r { a[row + x] = to } }
        }
        var b = a
        for x in 0..<w {
            var last = Int.min / 2
            for y in 0..<h { if a[y * w + x] == to { last = y }; if y - last <= r { b[y * w + x] = to } }
            last = Int.max / 2
            for y in stride(from: h - 1, through: 0, by: -1) { if a[y * w + x] == to { last = y }; if last - y <= r { b[y * w + x] = to } }
        }
        return b
    }
}

extension MagicSelection {
    /// Matte cache key of the narrowed matte of a Face / Skin mask (derived from `cacheKey`, which holds the followed
    /// person). nil for a whole person or an ordinary pick. A build that does not know `part` reads `cacheKey` and so
    /// covers the whole person.
    public func partKey(media: UUID) -> String? {
        guard let part, part != .person else { return nil }
        return cacheKey(media: media) + "-" + part.rawValue
    }

    /// The key of the matte the mask draws.
    public func matteKey(media: UUID) -> String { partKey(media: media) ?? cacheKey(media: media) }

    /// Every matte key the mask needs (the followed person first): all are kept while the mask exists.
    public func matteKeys(media: UUID) -> [String] { [cacheKey(media: media)] + (partKey(media: media).map { [$0] } ?? []) }

    /// Made by Anonymize: a frame without a matte is covered by estimate (`AnonymizeFallback`), never left open.
    public var mustCover: Bool { part != nil }
}

/// What a mask that must cover (Anonymize) draws on a frame without a tracked matte: the person was lost, the frame was
/// revealed by a trim or a slip after the run, or the matte file is gone. When in doubt the cover is larger, never missing.
public enum AnonymizeFallback {
    /// How far the nearest tracked matte is grown, as a share of the frame width, when it is `gap` seconds away. Three
    /// steps (not a ramp), so the grown matte of one tracked frame is made once per step and reused.
    public static func growth(gap: Double) -> Double { gap < 0.5 ? growths[0] : (gap < 1.5 ? growths[1] : growths[2]) }

    /// The three steps of `growth`.
    public static let growths = [0.06, 0.10, 0.16]

    /// No tracked matte at all (or the picture is warped after tracking): the whole frame.
    public static let wholeFrame = SubjectMatte(width: 8, height: 8, values: [Float](repeating: 1, count: 64))
}

extension Clip {
    /// Writes what an Anonymize run made: one Magic mask per picked person (it limits the cover only, the picture is not
    /// cut) and one Mosaic or Blur that takes those masks as its input. `subjectWidth`: px of the clip's frame the widest
    /// covered subject spans (sets the block size / blur amount). Returns the new masks' ids; nothing is added for no picks.
    @discardableResult
    public mutating func addAnonymize(_ picks: [MagicSelection], target: AnonymizeTarget, cover: AnonymizeCover,
                                      subjectWidth: Double, frameWidth: Int, frameHeight: Int) -> [ClipMask.ID] {
        guard !picks.isEmpty else { return [] }
        let short = Double(min(frameWidth, frameHeight))
        var n = masks.filter { $0.name.hasPrefix(target.maskName + " ") }.count
        var ids: [ClipMask.ID] = []
        var added: [ClipMask] = []
        for p in picks {
            n += 1
            var m = ClipMask.makeMagic(name: "\(target.maskName) \(n)", points: p.points)
            var sel = p
            sel.part = target   // marks the mask as one that must cover, a whole person too
            m.magic = sel
            m.usedByOpacity = false
            // A person's or skin's edge gets a little room (hair, fingers); the face ellipse already has it. The soft edge
            // of a blur is the mask's Feather; Mosaic blocks end hard unless the user raises it.
            if target != .face { m.expansion = AnimatedProperty((short / 180).rounded()) }
            if cover == .blur { m.feather = AnimatedProperty((short / 90).rounded()) }
            ids.append(m.id)
            added.append(m)
        }
        masks += added
        var effect: ClipEffect
        switch cover {
        case .mosaic:
            let block = ClipEffect.anonymizeBlockSize(subjectWidth: subjectWidth, frameWidth: frameWidth, frameHeight: frameHeight)
            effect = ClipEffect.mosaic(blockSize: block, width: frameWidth, height: frameHeight)
        case .blur:
            effect = ClipEffect(kind: ClipEffect.gaussianBlurKind, parameters: ClipEffect.defaultParameters(for: ClipEffect.gaussianBlurKind))
            effect.parameters[ClipEffect.blurrinessKey] = AnimatedProperty(max((subjectWidth / 4).rounded(), (short / 20).rounded()))
            effect.parameters[ClipEffect.repeatEdgePixelsKey] = AnimatedProperty(1)
        }
        effect.maskInput = ids
        // In front of every other picture effect (behind the Color effects, which stay first): the mattes are tracked on
        // the source frame, so the cover has to act on the picture before any effect that moves pixels (Horizontal Flip,
        // Mirror, Lens Distortion); those then move the covered picture. Transform, Auto Reframe and the Standard
        // Stabilizer are stages that act after every pixel effect anyway. See AnonymizeOrder.swift.
        effects.insert(effect, at: coverInsertionIndex)
        pinCovers()
        return ids
    }
}
