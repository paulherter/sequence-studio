import Foundation

// Date Stamp: camcorder-style date/time burned into the picture. The effect only holds the look values; the text is drawn by the
// one text renderer (SQText): `Timeline.videoLayers` adds a second layer next to the clip with a `GeneratorRef.dateStamp`
// payload (the already formatted text, corner, pixel size, color), and the playback and export layer builders turn that into a
// text layer (`DateStampText` in SQText). No second text system, no compositor change: the cost is one extra text layer whose
// raster changes at most once per second. Kind and keys are stored strings: never rename.

extension ClipEffect {
    public static let dateStampKind = "dateStamp"
    public static let stampFormatKey = "stampFormat"
    public static let stampYearKey = "stampYear", stampMonthKey = "stampMonth", stampDayKey = "stampDay"
    public static let stampHourKey = "stampHour", stampMinuteKey = "stampMinute"
    public static let stampPositionKey = "stampPosition", stampSizeKey = "stampSize"
    public static let stampColorKey = "stampColor", stampBlinkKey = "stampBlink"
}

extension GeneratorRef {
    /// The Date Stamp layer: payload is a JSON `DateStampSpec`.
    public static let dateStamp = "dateStamp"
    public static func dateStamp(_ spec: DateStampSpec) -> GeneratorRef {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return GeneratorRef(kind: dateStamp, payload: (try? e.encode(spec)) ?? Data())
    }
}

/// What the text layer of a Date Stamp shows and where. Pixel values are in canvas pixels of the sequence it is drawn in.
public struct DateStampSpec: Sendable, Hashable, Codable {
    public var text: String
    public var corner: DateStamp.Corner
    public var fontSize: Double
    public var red: Double, green: Double, blue: Double
    public var canvasWidth: Int, canvasHeight: Int
    public init(text: String, corner: DateStamp.Corner, fontSize: Double, red: Double, green: Double, blue: Double,
                canvasWidth: Int, canvasHeight: Int) {
        self.text = text; self.corner = corner; self.fontSize = fontSize
        self.red = red; self.green = green; self.blue = blue
        self.canvasWidth = canvasWidth; self.canvasHeight = canvasHeight
    }
    public static func decode(_ ref: GeneratorRef) -> DateStampSpec? {
        ref.kind == GeneratorRef.dateStamp ? try? JSONDecoder().decode(DateStampSpec.self, from: ref.payload) : nil
    }
}

public enum DateStamp {
    public enum Corner: Int, Sendable, Hashable, Codable, CaseIterable { case bottomRight, bottomLeft, topRight, topLeft }

    public static let formatTitles = ["JUL 14 1998", "14.07.1998", "07/14/1998", "10:32 PM", "22:32:05", "JUL 14 1998  10:32 PM",
                                      "14.07.1998  22:32:05"]
    public static let positionTitles = ["Bottom Right", "Bottom Left", "Top Right", "Top Left"]
    /// Margin from the canvas edge, as a share of the canvas height (the title-safe look of a camcorder).
    public static let marginShare = 0.06
    static let months = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]

    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return c
    }()

    /// The stamped moment: the start (clip-local 0) plus whole `elapsedSeconds`. A date the calendar cannot build (31 Feb)
    /// rolls over, as a camcorder clock would.
    public static func moment(year: Int, month: Int, day: Int, hour: Int, minute: Int, elapsedSeconds: Int) -> Date {
        let comps = DateComponents(year: year, month: 1, day: 1, hour: 0, minute: 0, second: 0)
        let base = calendar.date(from: comps) ?? Date(timeIntervalSince1970: 0)
        let start = calendar.date(byAdding: DateComponents(month: month - 1, day: day - 1, hour: hour, minute: minute), to: base) ?? base
        return start.addingTimeInterval(Double(elapsedSeconds))
    }

    /// The text of format index `format` (see `formatTitles`). Fixed English month names and 24 h / 12 h forms, never locale
    /// dependent, so a project renders the same on every Mac.
    public static func text(format: Int, at date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let y = c.year ?? 0, mo = c.month ?? 1, d = c.day ?? 1, h = c.hour ?? 0, mi = c.minute ?? 0, s = c.second ?? 0
        func p2(_ v: Int) -> String { v < 10 ? "0\(v)" : "\(v)" }
        let h12 = h % 12 == 0 ? 12 : h % 12, ampm = h < 12 ? "AM" : "PM"
        let dateEN = "\(months[(mo - 1) % 12]) \(d) \(y)"
        let dateDE = "\(p2(d)).\(p2(mo)).\(y)"
        let time12 = "\(h12):\(p2(mi)) \(ampm)", time24 = "\(p2(h)):\(p2(mi)):\(p2(s))"
        switch format {
        case 1: return dateDE
        case 2: return "\(p2(mo))/\(p2(d))/\(y)"
        case 3: return time12
        case 4: return time24
        case 5: return dateEN + "  " + time12
        case 6: return dateDE + "  " + time24
        default: return dateEN
        }
    }

    /// Blink: on for the first half of every second.
    public static func blinkVisible(localSeconds: Double) -> Bool { localSeconds - localSeconds.rounded(.down) < 0.5 }
}

extension Clip {
    /// The Date Stamp layer for this clip at timeline time `t` (the last enabled Date Stamp wins), or nil. It sits on the clip's
    /// transform, so it moves and scales with the picture, and follows the clip's opacity.
    func dateStampRequest(at t: Time, canvas: SequenceFormat, transform: ClipTransform, groups: [LayerGroup],
                          track: Track.ID, inTransition: Bool) -> LayerRequest? {
        guard let e = effects.last(where: { $0.kind == ClipEffect.dateStampKind && $0.enabled }) else { return nil }
        let local = t - start
        let secs = Double(local.value) / Double(max(1, local.timescale))
        func v(_ key: String) -> Double { e.scalar(key, atLocal: local) }
        if e.flag(ClipEffect.stampBlinkKey, atLocal: local), !DateStamp.blinkVisible(localSeconds: secs) { return nil }
        let date = DateStamp.moment(year: Int(v(ClipEffect.stampYearKey).rounded()), month: Int(v(ClipEffect.stampMonthKey).rounded()),
                                    day: Int(v(ClipEffect.stampDayKey).rounded()), hour: Int(v(ClipEffect.stampHourKey).rounded()),
                                    minute: Int(v(ClipEffect.stampMinuteKey).rounded()),
                                    elapsedSeconds: max(0, Int(secs.rounded(.down))))
        let col = e.color(ClipEffect.stampColorKey, atLocal: local)
        let spec = DateStampSpec(text: DateStamp.text(format: Int(v(ClipEffect.stampFormatKey).rounded()), at: date),
                                 corner: DateStamp.Corner(rawValue: Int(v(ClipEffect.stampPositionKey).rounded())) ?? .bottomRight,
                                 fontSize: max(4, v(ClipEffect.stampSizeKey) / 100 * Double(canvas.height)),
                                 red: col.red, green: col.green, blue: col.blue,
                                 canvasWidth: canvas.width, canvasHeight: canvas.height)
        // The effect's own id names the layer: stable per effect, never a timeline clip.
        var r = LayerRequest(clip: e.id, media: e.id, track: track, sourceTime: local, transform: transform, groups: groups,
                             generator: .dateStamp(spec), localTime: local)
        r.inTransition = inTransition
        r.clipDuration = duration
        return r
    }
}

extension EffectCatalog {
    static let dateStamp: [EffectSpec] = [
        EffectSpec(kind: ClipEffect.dateStampKind, title: "Date Stamp", params: [
            .choice(ClipEffect.stampFormatKey, "Format", DateStamp.formatTitles, default: 5),
            EffectParamSpec(key: ClipEffect.stampYearKey, title: "Year", unit: "", defaultValue: 1998, range: 1900...2200, step: 1, decimals: 0),
            EffectParamSpec(key: ClipEffect.stampMonthKey, title: "Month", unit: "", defaultValue: 7, range: 1...12, step: 1, decimals: 0),
            EffectParamSpec(key: ClipEffect.stampDayKey, title: "Day", unit: "", defaultValue: 14, range: 1...31, step: 1, decimals: 0),
            EffectParamSpec(key: ClipEffect.stampHourKey, title: "Hour", unit: "", defaultValue: 22, range: 0...23, step: 1, decimals: 0),
            EffectParamSpec(key: ClipEffect.stampMinuteKey, title: "Minute", unit: "", defaultValue: 32, range: 0...59, step: 1, decimals: 0),
            .choice(ClipEffect.stampPositionKey, "Position", DateStamp.positionTitles),
            EffectParamSpec(key: ClipEffect.stampSizeKey, title: "Size", unit: "%", defaultValue: 4.5, range: 1...20, step: 0.5, decimals: 1),
            .color(ClipEffect.stampColorKey, "Color", EffectColor(red: 1, green: 0.55, blue: 0.1)),
            .checkbox(ClipEffect.stampBlinkKey, "Blink"),
        ]),
    ]
}
