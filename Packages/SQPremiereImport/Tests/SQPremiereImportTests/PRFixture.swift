import Foundation

/// Builds small synthetic Premiere project XML with the same object graph as real files (flat objects, ObjectRef/ObjectURef).
/// Never a real project: shapes copied from docs/PRPROJ-IMPORT.md section 1.
final class PRFixture {
    static let second: Int64 = 254_016_000_000
    static let staticTime = "-91445760000000000"
    private var objects: [String] = []
    private var next = 100

    enum Source { case media(String), sequence(String), graphic, matte(prefsHex: String?) }

    private func newID() -> String { next += 1; return String(next) }
    private func newUID() -> String { next += 1; return String(format: "00000000-0000-0000-0000-%012d", next) }

    var xml: String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n<PremiereData Version=\"3\">\n" + objects.joined(separator: "\n") + "\n</PremiereData>\n"
    }
    var data: Data { Data(xml.utf8) }

    /// `par` ("160,121") and `colorProfile` go into a referenced VideoStream (OriginalPAR / OriginalColorSpace JSON).
    /// `actual`: a different ActualMediaFilePath (FilePath stays `path`); `relative`: a RelativePath element.
    func media(path: String, title: String, par: String? = nil, colorProfile: String? = nil,
               actual: String? = nil, relative: String? = nil) -> String {
        let uid = newUID()
        var streamXML = ""
        if par != nil || colorProfile != nil {
            let sid = newID()
            let parXML = par.map { "<OriginalPAR>\($0)</OriginalPAR>" } ?? ""
            let csXML = colorProfile.map { "<OriginalColorSpace>{&quot;baseColorProfile&quot;:{&quot;colorProfileName&quot;:&quot;\($0)&quot;}}</OriginalColorSpace>" } ?? ""
            objects.append("<VideoStream ObjectID=\"\(sid)\" Version=\"5\">\(parXML)\(csXML)</VideoStream>")
            streamXML = "<VideoStream ObjectRef=\"\(sid)\"/>"
        }
        objects.append("<Media ObjectUID=\"\(uid)\" Version=\"30\"><ActualMediaFilePath>\(actual ?? path)</ActualMediaFilePath><FilePath>\(path)</FilePath>\(relative.map { "<RelativePath>\($0)</RelativePath>" } ?? "")<Title>\(title)</Title>\(streamXML)</Media>")
        return uid
    }

    /// A parameter object; `value` is the static value, `keys` the raw `Keyframes` string.
    func param(_ pid: Int?, _ value: String, keys: String? = nil, kind: String = "VideoComponentParam", name: String = "P") -> String {
        let id = newID()
        let pidXML = pid.map { "<ParameterID>\($0)</ParameterID>" } ?? ""
        let keysXML = keys.map { "<Keyframes>\($0)</Keyframes>" } ?? ""
        objects.append("<\(kind) ObjectID=\"\(id)\" Version=\"10\">\(pidXML)<Name>\(name)</Name><StartKeyframe>\(Self.staticTime),\(value),0,0,0,0,0,0</StartKeyframe>\(keysXML)</\(kind)>")
        return id
    }

    func blobParam(_ pid: Int, base64: String, hash: String = "") -> String {
        let id = newID()
        objects.append("<ArbVideoComponentParam ObjectID=\"\(id)\" Version=\"3\"><ParameterID>\(pid)</ParameterID><Name>Source Text</Name><StartKeyframeValue Encoding=\"base64\" BinaryHash=\"\(hash)\">\(base64)</StartKeyframeValue></ArbVideoComponentParam>")
        return id
    }

    func component(_ matchName: String, _ params: [String]) -> String {
        let id = newID()
        let ps = params.enumerated().map { "<Param Index=\"\($0.offset)\" ObjectRef=\"\($0.element)\"/>" }.joined()
        objects.append("<VideoFilterComponent ObjectID=\"\(id)\" Version=\"9\"><Component Version=\"7\"><Params Version=\"1\">\(ps)</Params><DisplayName>\(matchName)</DisplayName></Component><MatchName>\(matchName)</MatchName></VideoFilterComponent>")
        return id
    }

    func audioComponent(displayName: String, matchName: String, _ params: [String]) -> String {
        let id = newID()
        let ps = params.enumerated().map { "<Param Index=\"\($0.offset)\" ObjectRef=\"\($0.element)\"/>" }.joined()
        objects.append("<AudioFilterComponent ObjectID=\"\(id)\" Version=\"9\"><AudioComponent><Component><Params>\(ps)</Params><DisplayName>\(displayName)</DisplayName></Component></AudioComponent><FilterMatchName>\(matchName)</FilterMatchName></AudioFilterComponent>")
        return id
    }

    func item(start: Int64?, end: Int64, inPoint: Int64, outPoint: Int64, speed: Double? = nil, source: Source,
              components: [String] = [], audio: Bool = false, adjustment: Bool = false, name: String = "clip", gain: Double? = nil,
              markers: [String] = []) -> String {
        let chain = newID()
        let comps = components.enumerated().map { "<Component Index=\"\($0.offset)\" ObjectRef=\"\($0.element)\"/>" }.joined()
        let kind = audio ? "Audio" : "Video"
        objects.append("<\(kind)ComponentChain ObjectID=\"\(chain)\"><ComponentChain><Components>\(comps)</Components></ComponentChain></\(kind)ComponentChain>")
        let src = newID()
        switch source {
        case .media(let uid):
            objects.append("<\(kind)MediaSource ObjectID=\"\(src)\"><MediaSource><Media ObjectURef=\"\(uid)\"/></MediaSource></\(kind)MediaSource>")
        case .graphic:
            let uid = newUID()
            objects.append("<Media ObjectUID=\"\(uid)\"><Infinite>true</Infinite><ActualMediaFilePath>1196574294</ActualMediaFilePath><Title>Graphic</Title></Media>")
            objects.append("<\(kind)MediaSource ObjectID=\"\(src)\"><MediaSource><Media ObjectURef=\"\(uid)\"/></MediaSource></\(kind)MediaSource>")
        case .matte(let hex):
            let uid = newUID()
            let prefs = hex.map { h -> String in
                let bytes = stride(from: 0, to: h.count, by: 2).map { UInt8(h.dropFirst($0).prefix(2), radix: 16)! }
                return "<ImporterPrefs Encoding=\"base64\" BinaryHash=\"h\(uid.suffix(4))\">\(Data(bytes).base64EncodedString())</ImporterPrefs>"
            } ?? ""
            objects.append("<Media ObjectUID=\"\(uid)\">\(prefs)<Infinite>true</Infinite><ActualMediaFilePath>1129270354</ActualMediaFilePath><Title>Farbfl\u{E4}che</Title></Media>")
            objects.append("<\(kind)MediaSource ObjectID=\"\(src)\"><MediaSource><Media ObjectURef=\"\(uid)\"/></MediaSource></\(kind)MediaSource>")
        case .sequence(let uid):
            objects.append("<\(kind)SequenceSource ObjectID=\"\(src)\"><SequenceSource><Sequence ObjectURef=\"\(uid)\"/></SequenceSource></\(kind)SequenceSource>")
        }
        let clip = newID()
        let speedXML = speed.map { "<PlaybackSpeed>\($0)</PlaybackSpeed>" } ?? ""
        let adj = adjustment ? "<AdjustmentLayer>true</AdjustmentLayer>" : ""
        let clipMarkers = markerOwner(markers)
        objects.append("<\(kind)Clip ObjectID=\"\(clip)\"><Clip>\(clipMarkers)<Source ObjectRef=\"\(src)\"/><InPoint>\(inPoint)</InPoint><OutPoint>\(outPoint)</OutPoint>\(speedXML)</Clip>\(adj)\(gain.map { "<Gain>\($0)</Gain>" } ?? "")</\(kind)Clip>")
        let sub = newID()
        objects.append("<SubClip ObjectID=\"\(sub)\"><Clip ObjectRef=\"\(clip)\"/><Name>\(name)</Name></SubClip>")
        let item = newID()
        let startXML = start.map { "<Start>\($0)</Start>" } ?? ""
        objects.append("<\(kind)ClipTrackItem ObjectID=\"\(item)\"><ClipTrackItem><ComponentOwner><Components ObjectRef=\"\(chain)\"/></ComponentOwner><TrackItem><Node/>\(startXML)<End>\(end)</End></TrackItem><SubClip ObjectRef=\"\(sub)\"/></ClipTrackItem></\(kind)ClipTrackItem>")
        return item
    }

    func transition(start: Int64, end: Int64, matchName: String = "AE.ADBE Cross Dissolve New") -> String {
        let id = newID()
        objects.append("<VideoTransitionTrackItem ObjectID=\"\(id)\"><TransitionItem><TrackItem><Start>\(start)</Start><End>\(end)</End></TrackItem></TransitionItem><MatchName>\(matchName)</MatchName></VideoTransitionTrackItem>")
        return id
    }

    func track(_ items: [String], transitions: [String] = [], audio: Bool = false, muted: Bool = false) -> String {
        let uid = newUID()
        let kind = audio ? "Audio" : "Video"
        let its = items.enumerated().map { "<TrackItem Index=\"\($0.offset)\" ObjectRef=\"\($0.element)\"/>" }.joined()
        let trs = transitions.enumerated().map { "<TrackItem Index=\"\($0.offset)\" ObjectRef=\"\($0.element)\"/>" }.joined()
        objects.append("<\(kind)ClipTrack ObjectUID=\"\(uid)\"><ClipTrack><Track><ID>1</ID>\(muted ? "<IsMuted>true</IsMuted>" : "")</Track><ClipItems><TrackItems>\(its)</TrackItems></ClipItems><TransitionItems><TrackItems>\(trs)</TrackItems></TransitionItems></ClipTrack></\(kind)ClipTrack>")
        return uid
    }

    @discardableResult
    func sequence(_ name: String, ticksPerFrame: Int64 = 8_467_200_000, width: Int = 1080, height: Int = 1920,
                  video: [String], audio: [String] = [], uid: String? = nil, markers: [String] = []) -> String {
        let uid = uid ?? newUID()
        let markerXML = markerOwner(markers)
        let vg = newID(), ag = newID()
        let vt = video.enumerated().map { "<Track Index=\"\($0.offset)\" ObjectURef=\"\($0.element)\"/>" }.joined()
        let at = audio.enumerated().map { "<Track Index=\"\($0.offset)\" ObjectURef=\"\($0.element)\"/>" }.joined()
        objects.append("<VideoTrackGroup ObjectID=\"\(vg)\"><TrackGroup><Tracks>\(vt)</Tracks><FrameRate>\(ticksPerFrame)</FrameRate></TrackGroup><FrameRect>0,0,\(width),\(height)</FrameRect></VideoTrackGroup>")
        objects.append("<AudioTrackGroup ObjectID=\"\(ag)\"><TrackGroup><Tracks>\(at)</Tracks><FrameRate>5292000</FrameRate></TrackGroup></AudioTrackGroup>")
        objects.append("<Sequence ObjectUID=\"\(uid)\"><Name>\(name)</Name>\(markerXML)<TrackGroups><TrackGroup Index=\"0\"><First>a</First><Second ObjectRef=\"\(vg)\"/></TrackGroup><TrackGroup Index=\"1\"><First>b</First><Second ObjectRef=\"\(ag)\"/></TrackGroup></TrackGroups></Sequence>")
        return uid
    }

    /// `<MarkerOwner>` pointing at a Markers object with one Marker object per DVAMarker JSON (as on sequences and on the
    /// `Clip` node of a VideoClip/AudioClip); "" for none.
    private func markerOwner(_ markers: [String]) -> String {
        guard !markers.isEmpty else { return "" }
        let refs = markers.enumerated().map { i, json -> String in
            let id = newID()
            objects.append("<Marker ObjectID=\"\(id)\"><DVAMarker>\(json)</DVAMarker></Marker>")
            return "<Marker Index=\"\(i)\"><First>g\(i)</First><Second ObjectRef=\"\(id)\"/></Marker>"
        }.joined()
        let mid = newID()
        objects.append("<Markers ObjectID=\"\(mid)\"><Markers>\(refs)</Markers></Markers>")
        return "<MarkerOwner><Markers ObjectRef=\"\(mid)\"/></MarkerOwner>"
    }

    /// A clip marker as Premiere writes one whose only change is its time: the keys of all 251 clip markers in the maintainer's
    /// projects (mMarkerID, mStartTime ticks as a JSON number, mType "Comment"; no name, color, comment or duration).
    static func plainMarker(_ ticks: Int64) -> String {
        "{&quot;DVAMarker&quot;:{&quot;mMarkerID&quot;:&quot;m\(ticks)&quot;,&quot;mStartTime&quot;:{&quot;ticks&quot;:\(ticks)},&quot;mType&quot;:&quot;Comment&quot;}}"
    }

    /// A UID for a sequence declared later (nesting refers forward).
    func reserveUID() -> String { newUID() }
}

/// Minimal FlatBuffer writer for the text blob tests: tables laid out front to back with patched offsets.
struct FlatBlob {
    private(set) var bytes: [UInt8] = []
    private var patches: [(at: Int, target: () -> Int)] = []

    mutating func align4() { while bytes.count % 4 != 0 { bytes.append(0) } }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { bytes.append(contentsOf: $0) } }
    mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { bytes.append(contentsOf: $0) } }
    mutating func f32(_ v: Float) { u32(v.bitPattern) }

    /// Writes a table whose fields are all 4 bytes wide; returns the table position and each field's absolute position.
    mutating func table(fieldCount: Int, present: [Int]) -> (table: Int, fields: [Int: Int]) {
        align4()
        let vt = bytes.count
        let vtSize = 4 + 2 * fieldCount
        u16(UInt16(vtSize)); u16(UInt16(4 + 4 * present.count))
        var offs = [Int: Int]()
        for i in 0..<fieldCount {
            if let k = present.firstIndex(of: i) { offs[i] = 4 + 4 * k; u16(UInt16(4 + 4 * k)) } else { u16(0) }
        }
        align4()
        let t = bytes.count
        u32(UInt32(t - vt))                 // soffset: vtable = table - soffset
        for _ in present { u32(0) }
        return (t, offs.mapValues { t + $0 })
    }

    /// A color table as Premiere writes it: fields 0, 1, 2 are one byte each, packed next to each other (offsets 4, 5, 6),
    /// followed by an unrelated byte, so a 4-byte read of a channel picks up its neighbors.
    mutating func packedColourTable(_ rgb: (UInt8, UInt8, UInt8)) -> Int {
        align4()
        let vt = bytes.count
        u16(10); u16(8); u16(4); u16(5); u16(6)
        align4()
        let t = bytes.count
        u32(UInt32(t - vt))
        bytes.append(contentsOf: [rgb.0, rgb.1, rgb.2, 0x0a])
        return t
    }

    mutating func setU32(_ at: Int, _ v: UInt32) {
        withUnsafeBytes(of: v.littleEndian) { for (i, b) in $0.enumerated() { bytes[at + i] = b } }
    }
    mutating func setF32(_ at: Int, _ v: Float) { setU32(at, v.bitPattern) }
    /// Points the uoffset at `at` to `target` (absolute).
    mutating func link(_ at: Int, to target: Int) { setU32(at, UInt32(target - at)) }

    mutating func string(_ s: String) -> Int {
        align4()
        let p = bytes.count
        let u = Array(s.utf8)
        u32(UInt32(u.count)); bytes.append(contentsOf: u); bytes.append(0)
        return p
    }
    /// A vector of uoffsets; returns (vector position, element slot positions).
    mutating func vector(count: Int) -> (vector: Int, slots: [Int]) {
        align4()
        let p = bytes.count
        u32(UInt32(count))
        let slots = (0..<count).map { p + 4 + 4 * $0 }
        for _ in 0..<count { u32(0) }
        return (p, slots)
    }

    /// The Premiere text blob for one run of `text` in `font` at `size` with `tracking`.
    /// `shadow`: Essential Graphics shadow (main table fields 10 color, 11 on, 12 opacity %, 15 size, 16 blur,
    /// 20 angle, 34 distance). `background`: main table fields 17 (color table; r g b are packed one-byte fields, as Premiere
    /// writes them), 18 (on, omitted when off), 19 (opacity %), 13 (size), 14 (corner radius).
    static func premiereText(_ text: String, font: String, size: Float, tracking: Float,
                             shadow: (rgb: (UInt8, UInt8, UInt8), on: Bool, opacity: Float, distance: Float, angle: Float,
                                      size: Float, blur: Float)? = nil,
                             background: (rgb: (UInt8, UInt8, UInt8), on: Bool, opacity: Float, size: Float, radius: Float)? = nil) -> Data {
        var b = FlatBlob()
        b.u32(0)                                       // root uoffset, patched
        let root = b.table(fieldCount: 1, present: [0])
        b.link(0, to: root.table)
        let present = [0, 1] + (shadow == nil ? [] : [10, 11, 12, 15, 16, 20, 34]) + (background == nil ? [] : [13, 14, 17, 19] + (background!.on ? [18] : []))
        let main = b.table(fieldCount: present.max()! + 1, present: present.sorted())
        if let bg = background {
            if bg.on { b.bytes[main.fields[18]!] = 1 }
            b.setF32(main.fields[19]!, bg.opacity); b.setF32(main.fields[13]!, bg.size); b.setF32(main.fields[14]!, bg.radius)
            let colour = b.packedColourTable(bg.rgb)
            b.link(main.fields[17]!, to: colour)
        }
        b.link(root.fields[0]!, to: main.table)
        if let sh = shadow {
            b.bytes[main.fields[11]!] = sh.on ? 1 : 0
            b.setF32(main.fields[12]!, sh.opacity); b.setF32(main.fields[15]!, sh.size)
            b.setF32(main.fields[16]!, sh.blur); b.setF32(main.fields[20]!, sh.angle); b.setF32(main.fields[34]!, sh.distance)
            let colour = b.table(fieldCount: 3, present: [0, 1, 2])
            b.link(main.fields[10]!, to: colour.table)
            b.bytes[colour.fields[0]!] = sh.rgb.0; b.bytes[colour.fields[1]!] = sh.rgb.1; b.bytes[colour.fields[2]!] = sh.rgb.2
        }
        let runs = b.vector(count: 1)
        b.link(main.fields[0]!, to: runs.vector)
        let run = b.table(fieldCount: 2, present: [0, 1])
        b.link(runs.slots[0], to: run.table)
        let style = b.table(fieldCount: 9, present: [1, 8])
        b.link(run.fields[1]!, to: style.table)
        b.setF32(style.fields[1]!, size); b.setF32(style.fields[8]!, tracking)
        let s = b.string(text)
        b.link(run.fields[0]!, to: s)
        let fonts = b.vector(count: 1)
        b.link(main.fields[1]!, to: fonts.vector)
        let f = b.string(font)
        b.link(fonts.slots[0], to: f)
        return b.wrapped()
    }

    /// A blob with several runs (text, font index into `fonts`, size): style table field 0 = font index (omitted for 0),
    /// 1 = size, as in TCL C8L's 'Bis zu\r3.200' (line 1 Regular 136, line 2 Bold 195).
    static func premiereRuns(_ runs: [(text: String, font: Int, size: Float)], fonts: [String]) -> Data {
        var b = FlatBlob()
        b.u32(0)
        let root = b.table(fieldCount: 1, present: [0])
        b.link(0, to: root.table)
        let main = b.table(fieldCount: 2, present: [0, 1])
        b.link(root.fields[0]!, to: main.table)
        let vec = b.vector(count: runs.count)
        b.link(main.fields[0]!, to: vec.vector)
        for (i, r) in runs.enumerated() {
            let run = b.table(fieldCount: 2, present: [0, 1])
            b.link(vec.slots[i], to: run.table)
            let style = b.table(fieldCount: 2, present: r.font == 0 ? [1] : [0, 1])
            b.link(run.fields[1]!, to: style.table)
            if r.font != 0 { b.bytes[style.fields[0]!] = UInt8(r.font) }
            b.setF32(style.fields[1]!, r.size)
            let s = b.string(r.text)
            b.link(run.fields[0]!, to: s)
        }
        let fv = b.vector(count: fonts.count)
        b.link(main.fields[1]!, to: fv.vector)
        for (i, f) in fonts.enumerated() { let s = b.string(f); b.link(fv.slots[i], to: s) }
        return b.wrapped()
    }

    private func wrapped() -> Data {
        let b = self
        var out = Data()
        var size = UInt32(b.bytes.count + 4).littleEndian
        withUnsafeBytes(of: &size) { out.append(contentsOf: $0) }
        out.append(contentsOf: [0, 0, 0, 0, 0x44, 0x33, 0x22, 0x11])
        out.append(contentsOf: b.bytes)
        return out
    }
}
