import Foundation
import SQCore

/// One keyframe as Premiere stores it: `time,value,interp,flag,inSlope,inInfluence,outSlope,outInfluence[,spatial...]`.
/// `ticks` is absolute source time of the clip (not clip-local).
public struct PRKey: Sendable, Equatable {
    public var ticks: Int64
    public var value: String
    /// 0 linear, 4 hold, 5...8 bezier variants (docs/PRPROJ-IMPORT.md section 1).
    public var interpolation: Int
    public var inSlope: Double, inInfluence: Double, outSlope: Double, outInfluence: Double
}

/// A component parameter: static value plus keys. `blob` is the base64 `StartKeyframeValue` of arbitrary-data params (text).
public struct PRParamValue: Sendable, Equatable {
    public var id: Int?
    public var name: String
    public var staticValue: String?
    public var keys: [PRKey]
    public var blob: String?

    public init(id: Int? = nil, name: String = "", staticValue: String?, keys: [PRKey], blob: String? = nil) {
        self.id = id; self.name = name; self.staticValue = staticValue; self.keys = keys; self.blob = blob
    }

    public static func parse(start: String?, keys: String?) -> PRParamValue {
        // Second comma-separated field, without splitting the whole string.
        var s = start.flatMap { str -> String? in
            let u = str.utf8
            guard let a = u.firstIndex(of: UInt8(ascii: ",")) else { return nil }
            let from = u.index(after: a)
            return String(str[from..<(u[from...].firstIndex(of: UInt8(ascii: ",")) ?? u.endIndex)])
        }
        // Point params of Premiere-authored .mogrt files store x and y as separate fields ("ticks,x,y,0,0,0,0,0,0,5,4,...", 15
        // fields) where project files use "x:y". Join them so every reader sees one form; scalars have 8 fields.
        if let st = start, let x = s, !x.contains(":"), st.utf8.count(where: { $0 == UInt8(ascii: ",") }) >= 14 {
            let f = st.split(separator: ",", maxSplits: 3, omittingEmptySubsequences: false)
            if f.count >= 3 { s = "\(f[1]):\(f[2])" }
        }
        var out = [PRKey]()
        for k in (keys ?? "").split(separator: ";") {
            var f = k.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 2, let t = Int64(f[0]) else { continue }
            // A point key of a .mogrt: "ticks,x,y,interpolation,..." (one field more than a scalar key).
            if f.count >= 15, !f[1].contains(":") { f[1] = "\(f[1]):\(f[2])"; f.remove(at: 2) }
            func d(_ i: Int) -> Double { i < f.count ? Double(f[i]) ?? 0 : 0 }
            out.append(PRKey(ticks: t, value: f[1], interpolation: f.count > 2 ? Int(f[2]) ?? 0 : 0,
                             inSlope: d(4), inInfluence: d(5), outSlope: d(6), outInfluence: d(7)))
        }
        return PRParamValue(staticValue: s, keys: out.sorted { $0.ticks < $1.ticks })
    }

    public var isAnimated: Bool { !keys.isEmpty }

    public static func double(_ s: String?) -> Double? {
        guard var s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.hasSuffix(".") { s.removeLast() }
        return Double(s)
    }
    public static func point(_ s: String?) -> Vec2? {
        guard let parts = s?.split(separator: ":"), parts.count == 2,
              let x = double(String(parts[0])), let y = double(String(parts[1])) else { return nil }
        return Vec2(x, y)
    }
    public static func bool(_ s: String?) -> Bool? {
        switch s { case "true": true; case "false": false; default: nil }
    }
    /// Packed 64-bit color, 16 bit per channel ARGB with the 8-bit value in the high byte
    /// (18374686479671623680 = 0xFF00_0000_0000_0000 = opaque black).
    public static func color(_ s: String?) -> EffectColor? {
        guard let s, let v = UInt64(s) else { return nil }
        func ch(_ shift: UInt64) -> Double { Double((v >> (shift + 8)) & 0xFF) / 255 }
        return EffectColor(red: ch(32), green: ch(16), blue: ch(0), alpha: ch(48))
    }
}

public struct PRComponent: Sendable {
    /// `MatchName` of a video filter (`AE.ADBE Motion`), `FilterMatchName` of an audio filter.
    public var matchName: String
    public var displayName: String
    public var params: [PRParamValue]
    public var isAudio: Bool

    public func param(_ id: Int) -> PRParamValue? { params.first { $0.id == id } }
    /// Audio filter params have no ParameterID: by position.
    public func param(at index: Int) -> PRParamValue? { index < params.count ? params[index] : nil }
}

public struct PRMedia: Sendable, Hashable {
    public var key: String
    public var title: String
    /// Absolute file path as stored (POSIX or Windows, often from another machine); nil for graphics / generated media
    /// (Premiere stores a number there).
    public var path: String?
    /// Premiere's `RelativePath` (relative to the project file's folder), when stored.
    public var relativePath: String?
    /// Pixel aspect ratio Premiere read from the file (`VideoStream/OriginalPAR`, width / height of one pixel); 1 = square.
    /// nil = the project does not say (no `OriginalPAR`): unknown, not square.
    public var pixelAspect: Double?
    /// Color profile Premiere assigned to the file (`VideoStream/OriginalColorSpace` colorProfileName), e.g.
    /// "BT.709,8-bit,Display-Referred", "Sony S-Log3/S-Gamut3.Cine", "BT.709 RGB Full".
    public var colorProfile: String?
}

public enum PRSource: Sendable {
    case media(PRMedia)
    case sequence(id: String)
    /// Media without a file: Essential Graphics, mattes, adjustment layers.
    case graphic(title: String)
    /// Color matte (Farbfläche): a numberless media whose `ImporterPrefs` hold the 8-bit RGB color.
    case colorMatte(rgb: [UInt8])
    case unknown
}

public struct PRItem: Sendable {
    public var name: String
    /// Timeline range and source range, ticks.
    public var start: Int64, end: Int64, inPoint: Int64, outPoint: Int64
    public var speed: Double
    public var source: PRSource
    public var components: [PRComponent]
    public var isAdjustmentLayer: Bool
    public var isAudio: Bool
    /// Right-click > Audio Gain: linear factor stored as `AudioClip/Gain` (1 = 0 dB). Separate from the Volume level.
    public var clipGain: Double = 1
    /// Clip markers (`VideoClip`/`AudioClip` > `Clip/MarkerOwner`), times in media ticks like `inPoint`. Premiere keeps
    /// them on the master clip and copies them to every instance, so most lie outside the used range.
    public var markers: [PRMarker] = []
    public func components(_ matchName: String) -> [PRComponent] { components.filter { $0.matchName == matchName } }
}

public struct PRTransitionItem: Sendable {
    public var start: Int64, end: Int64
    public var matchName: String
}

public struct PRTrack: Sendable {
    public var items: [PRItem]
    public var transitions: [PRTransitionItem]
    public var isMuted = false
}

/// A sequence or clip marker (`Markers/Marker/Second -> Marker/DVAMarker` JSON). Checked 2026-10-06 on all 251 markers in
/// The maintainer's 16 projects (all clip markers, no sequence markers): each has only mMarkerID, mStartTime {ticks: JSON number} and
/// mType "Comment". mDuration, mName, mComment and mColorIndex are absent when at their default; their names are not
/// confirmed by a real file, so a missing key falls back to the default (0 / "" / green).
public struct PRMarker: Sendable, Equatable {
    public var ticks: Int64
    public var durationTicks: Int64
    public var name: String
    public var comment: String
    /// Premiere's marker color index (0 green, 1 red, 2 purple, 3 orange, 4 yellow, 5 white, 6 blue, 7 cyan).
    public var colorIndex: Int
}

public struct PRSequence: Sendable {
    public var id: String
    public var name: String
    public var width: Int, height: Int
    public var frameDuration: Time
    public var videoTracks: [PRTrack]
    public var audioTracks: [PRTrack]
    public var markers: [PRMarker] = []
}

public struct PRDocument: Sendable {
    public var sequences: [PRSequence]
}

/// .prproj (gzip XML) -> `PRDocument`. Tolerant: unknown nodes are skipped, never thrown on.
public enum PRReader {
    public static func read(url: URL) throws -> PRDocument { try read(data: Data(contentsOf: url)) }

    public static func read(data: Data) throws -> PRDocument {
        let table = try PRObjectTable(xml: PRGzip.inflate(data))
        return PRDocument(sequences: table.all(named: "Sequence").compactMap { sequence($0, table) })
    }

    static func sequence(_ s: PRNode, _ t: PRObjectTable) -> PRSequence? {
        guard let id = s.objectID else { return nil }
        var seq = PRSequence(id: id, name: s.text("Name") ?? "Sequence", width: 1920, height: 1080,
                             frameDuration: Time(1, 30), videoTracks: [], audioTracks: [])
        for g in s.children("TrackGroups/TrackGroup") {
            guard let group = t.deref(g.child("Second")) else { continue }
            let tracks = group.children("TrackGroup/Tracks/Track").compactMap { t.deref($0) }.map { track($0, t) }
            switch group.name {
            case "VideoTrackGroup":
                if let f = group.int("TrackGroup/FrameRate"), f > 0 { seq.frameDuration = PRTicks.frameDuration(ticksPerFrame: f) }
                if let r = group.text("FrameRect")?.split(separator: ",").compactMap({ Int($0) }), r.count == 4 {
                    let w = r[2].subtractingReportingOverflow(r[0]), h = r[3].subtractingReportingOverflow(r[1])
                    if !w.overflow, !h.overflow, (1...65_536).contains(w.partialValue), (1...65_536).contains(h.partialValue) {
                        seq.width = w.partialValue; seq.height = h.partialValue
                    }
                }
                seq.videoTracks = tracks
            case "AudioTrackGroup": seq.audioTracks = tracks
            default: break
            }
        }
        seq.markers = markers(s.child("MarkerOwner/Markers"), t)
        return seq
    }

    static func markers(_ owner: PRNode?, _ t: PRObjectTable) -> [PRMarker] {
        guard let list = t.deref(owner) else { return [] }
        return list.children("Markers/Marker").compactMap { m -> PRMarker? in
            guard let json = t.deref(m.child("Second"))?.text("DVAMarker"), let data = json.data(using: .utf8),
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let d = root["DVAMarker"] as? [String: Any] else { return nil }
            func ticks(_ key: String) -> Int64 {
                guard let o = d[key] as? [String: Any] else { return 0 }
                if let n = o["ticks"] as? NSNumber { return n.int64Value }
                return (o["ticks"] as? String).flatMap { Int64($0) } ?? 0
            }
            return PRMarker(ticks: ticks("mStartTime"), durationTicks: ticks("mDuration"), name: d["mName"] as? String ?? "",
                            comment: d["mComment"] as? String ?? "", colorIndex: (d["mColorIndex"] as? NSNumber)?.intValue ?? 0)
        }.sorted { $0.ticks < $1.ticks }
    }

    static func track(_ n: PRNode, _ t: PRObjectTable) -> PRTrack {
        let items = n.children("ClipTrack/ClipItems/TrackItems/TrackItem").compactMap { t.deref($0) }.compactMap { item($0, t) }
        let transitions = n.children("ClipTrack/TransitionItems/TrackItems/TrackItem").compactMap { t.deref($0) }.compactMap { tr -> PRTransitionItem? in
            guard let ti = tr.descendant("TrackItem"), let end = ti.int("End") else { return nil }
            return PRTransitionItem(start: ti.int("Start") ?? 0, end: end, matchName: tr.descendant("MatchName")?.text ?? "")
        }
        return PRTrack(items: items.sorted { $0.start < $1.start }, transitions: transitions,
                       isMuted: n.text("ClipTrack/Track/IsMuted") == "true")
    }

    /// A file path as Premiere stores it: POSIX ("/Volumes/…"), a Windows drive ("D:\\…", "D:/…") or UNC ("\\\\nas\\…").
    /// Graphics and generated media store a number there instead.
    static func isFilePath(_ p: String) -> Bool {
        if p.hasPrefix("/") || p.hasPrefix("\\\\") { return true }
        let c = Array(p.prefix(3))
        return c.count == 3 && c[0].isLetter && c[0].isASCII && c[1] == ":" && (c[2] == "\\" || c[2] == "/")
    }

    static func item(_ n: PRNode, _ t: PRObjectTable) -> PRItem? {
        guard let end = n.int("ClipTrackItem/TrackItem/End") else { return nil }
        let start = n.int("ClipTrackItem/TrackItem/Start") ?? 0
        let sub = t.deref(n.child("ClipTrackItem/SubClip"))
        let clip = t.deref(sub?.child("Clip"))
        var source = PRSource.unknown
        if let src = t.deref(clip?.child("Clip/Source")) {
            if let seq = src.child("SequenceSource/Sequence")?.reference {
                source = .sequence(id: seq)
            } else if let m = t.deref(src.child("MediaSource/Media")) {
                // First non-empty of ActualMediaFilePath / FilePath (an empty element must not hide the other).
                let path = [m.text("ActualMediaFilePath"), m.text("FilePath")].compactMap { $0 }.first { !$0.isEmpty } ?? ""
                let title = m.text("Title") ?? MediaPathResolver.fileName(of: path)
                var media = PRMedia(key: m.objectID ?? path, title: title, path: path)
                media.relativePath = m.text("RelativePath").flatMap { $0.isEmpty ? nil : $0 }
                let stream = t.deref(m.child("VideoStream"))
                if let par = stream?.text("OriginalPAR")?.split(separator: ",").compactMap({ Double($0) }),
                   par.count == 2, par[0] > 0, par[1] > 0 {
                    media.pixelAspect = par[0] / par[1]
                }
                media.colorProfile = stream?.text("OriginalColorSpace").flatMap(Self.colorProfileName)
                if Self.isFilePath(path) { source = .media(media) }
                else if let rgb = Self.matteColor(m, t) { source = .colorMatte(rgb: rgb) }
                else { source = .graphic(title: title) }
            }
        }
        let comps = t.deref(n.child("ClipTrackItem/ComponentOwner/Components"))?
            .children("ComponentChain/Components/Component").compactMap { t.deref($0) }.compactMap { component($0, t) } ?? []
        let gain = n.name.hasPrefix("Audio") ? (PRParamValue.double(clip?.text("Gain")) ?? 1) : 1
        let adjustment = clip?.text("AdjustmentLayer") == "true" || clip?.text("Clip/AdjustmentLayer") == "true"
        return PRItem(name: sub?.text("Name") ?? "", start: start, end: end,
                      inPoint: clip?.int("Clip/InPoint") ?? 0, outPoint: clip?.int("Clip/OutPoint") ?? 0,
                      speed: PRParamValue.double(clip?.text("Clip/PlaybackSpeed")) ?? 1,
                      source: source, components: comps, isAdjustmentLayer: adjustment, isAudio: n.name.hasPrefix("Audio"),
                      clipGain: gain > 0 ? gain : 1, markers: markers(clip?.child("Clip/MarkerOwner/Markers"), t))
    }

    /// Color mattes store `ImporterPrefs` = R, G, B, 0, 1, 0, 0, 0 (checked on 23 mattes of a real project); graphics have none.
    static func matteColor(_ media: PRNode, _ t: PRObjectTable) -> [UInt8]? {
        guard let prefs = media.child("ImporterPrefs") else { return nil }
        let b64 = prefs.text.isEmpty ? (prefs.attributes["BinaryHash"].flatMap { t.binaries[$0] } ?? "") : prefs.text
        guard let d = Data(base64Encoded: b64, options: .ignoreUnknownCharacters), d.count == 8, d[4] == 1 else { return nil }
        return [d[0], d[1], d[2]]
    }

    /// `{"baseColorProfile":{"colorProfileName":"BT.709 RGB Full"},...}` -> "BT.709 RGB Full".
    static func colorProfileName(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let base = obj["baseColorProfile"] as? [String: Any] else { return nil }
        return base["colorProfileName"] as? String
    }

    static func component(_ c: PRNode, _ t: PRObjectTable) -> PRComponent? {
        let isAudio = c.name == "AudioFilterComponent"
        let base = isAudio ? c.child("AudioComponent/Component") : c.child("Component")
        let match = (isAudio ? c.text("FilterMatchName") : c.text("MatchName")) ?? ""
        let params = (base?.children("Params/Param") ?? []).compactMap { t.deref($0) }.map { p -> PRParamValue in
            var v = PRParamValue.parse(start: p.text("StartKeyframe"), keys: p.text("Keyframes"))
            v.id = p.text("ParameterID").flatMap { Int($0) }
            v.name = p.text("Name") ?? ""
            if let b = p.child("StartKeyframeValue") {
                v.blob = b.text.isEmpty ? b.attributes["BinaryHash"].flatMap { t.binaries[$0] } : b.text
            }
            return v
        }
        return PRComponent(matchName: match, displayName: base?.text("DisplayName") ?? match, params: params, isAudio: isAudio)
    }
}
