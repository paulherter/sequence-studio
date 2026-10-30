import Foundation
import SQCore

// Cell text, item kinds/icons, drop classification and the saved column layout of the Project panel.
// Pure logic, no AppKit (the view draws).

// MARK: - Cell text

extension ProjectPanelModel {
    /// "29.97 fps" (two decimals, trailing zeros trimmed).
    static func fpsString(_ frameDuration: Time) -> String {
        guard frameDuration.value > 0 else { return "" }
        var f = String(format: "%.2f", Double(frameDuration.timescale) / Double(frameDuration.value))
        while f.hasSuffix("0") { f.removeLast() }
        if f.hasSuffix(".") { f.removeLast() }
        return f + " fps"
    }

    public static func timecode(_ d: Time, frameDuration fd: Time?) -> String {
        guard !d.isNegative else { return "" }
        func two(_ n: Int64) -> String { n < 10 ? "0\(n)" : "\(n)" }
        if let fd, fd.value > 0 {
            let fps = max(1, Int64((Double(fd.timescale) / Double(fd.value)).rounded()))
            let frames = d.frameIndex(frameDuration: fd)
            let s = frames / fps
            return "\(two(s / 3600)):\(two(s / 60 % 60)):\(two(s % 60)):\(two(frames % fps))"
        }
        let s = d.value / d.timescale
        return "\(two(s / 3600)):\(two(s / 60 % 60)):\(two(s % 60))"
    }

    /// Full text behind a short cell (the Format column's whole line), nil when the cell says it all.
    public func cellTooltip(_ column: Column, _ ref: BinItemRef) -> String? {
        guard case .media(let id) = ref, let m = project.media(id) else { return nil }
        let note = Self.variableFrameRateNote(m)
        switch column {
        case .frameRate: return note
        case .format:
            let full = Self.formatString(m)
            let text = full.isEmpty || full == cellText(column, ref) ? nil : full
            guard let note else { return text }
            return [text ?? full, note].filter { !$0.isEmpty }.joined(separator: "\n")
        default: return nil
        }
    }

    /// Text of `column` for a bin item: "" where the column does not apply.
    public func cellText(_ column: Column, _ ref: BinItemRef) -> String {
        switch (column, ref) {
        case (.name, _): return displayName(of: ref)
        case (.label, .bin): return ""
        case (.label, _): return project.label(of: ref).displayName
        case (_, .bin): return ""
        case (_, .media(let id)):
            guard let m = project.media(id) else { return "" }
            switch column {
            case .frameRate:
                guard let v = m.info?.video else { return "" }
                return Self.fpsString(v.nominalFrameDuration) + (v.isVariableFrameRate ? " VFR" : "")
            case .duration: return Self.durationString(m)
            case .resolution: return m.info?.video.map { "\($0.width)×\($0.height)" } ?? ""
            case .codec:
                if let v = m.info?.video { return Self.codecName(v.codec) }
                return m.info?.audio.map { $0.codec.trimmingCharacters(in: .whitespaces) } ?? ""
            case .audio:
                guard let a = m.info?.audio else { return "" }
                var khz = String(format: "%.1f", Double(a.sampleRate) / 1000)
                if khz.hasSuffix(".0") { khz.removeLast(2) }
                return "\(khz) kHz \(a.channels) ch"
            case .inPoint:
                guard let t = project.sourceMarks[id]?.markIn else { return "" }
                return Self.timecode(t, frameDuration: m.info?.video?.nominalFrameDuration)
            case .filePath: return m.path
            case .format: return Self.formatLabel(m)
            case .sourceTimecode:
                guard m.info?.isStill != true else { return "" }
                guard let known = sourceTimecodes[m.id] else { requestSourceTimecode(m); return "" }
                return known?.label(frameDuration: m.info?.video?.nominalFrameDuration) ?? ""
            case .name, .label: return ""
            }
        case (_, .sequence(let id)):
            guard let t = project.timelines.first(where: { $0.id == id }) else { return "" }
            switch column {
            case .frameRate: return Self.fpsString(t.frameDuration)
            case .duration: return Self.timecode(t.duration, frameDuration: t.frameDuration)
            case .format: return Self.aspectLabel(width: t.format.width, height: t.format.height)
            case .resolution: return "\(t.format.width)×\(t.format.height)"
            case .audio:
                var khz = String(format: "%.1f", Double(t.format.audioSampleRate) / 1000)
                if khz.hasSuffix(".0") { khz.removeLast(2) }
                return "\(khz) kHz"
            default: return ""
            }
        }
    }
}

// MARK: - Item kinds and icons

public enum ProjectItemKind: Sendable, Hashable {
    case bin, video, audio, videoAudio, image, sequence, nestedSequence, text, generator
}

/// Icon composition of a Project panel icon (SQIcon case names): `symbol`, plus an optional small `badge` drawn bottom-right.
public struct ProjectItemIcon: Sendable, Hashable {
    public var symbol: String
    public var badge: String?

    public static func icon(for kind: ProjectItemKind, offline: Bool = false) -> ProjectItemIcon {
        if offline { return ProjectItemIcon(symbol: "unknown") }
        switch kind {
        case .bin: return ProjectItemIcon(symbol: "folder")
        case .video: return ProjectItemIcon(symbol: "film")
        case .audio: return ProjectItemIcon(symbol: "waveform")
        case .videoAudio: return ProjectItemIcon(symbol: "film", badge: "volume")
        case .image: return ProjectItemIcon(symbol: "image")
        case .sequence: return ProjectItemIcon(symbol: "sequence")
        case .nestedSequence: return ProjectItemIcon(symbol: "stack")
        case .text: return ProjectItemIcon(symbol: "text")
        case .generator: return ProjectItemIcon(symbol: "generator")
        }
    }
}

extension ProjectPanelModel {
    public func itemKind(of ref: BinItemRef) -> ProjectItemKind {
        switch ref {
        case .bin: return .bin
        case .sequence(let id): return project.nestedSequenceIDs.contains(id) ? .nestedSequence : .sequence
        case .media(let id):
            switch project.media(id)?.kind {
            case .audio: return .audio
            case .image: return .image
            case .videoAudio: return .videoAudio
            default: return .video
            }
        }
    }

    public func icon(of ref: BinItemRef) -> ProjectItemIcon {
        var offline = false
        if case .media(let id) = ref { offline = isOffline(id) }
        return .icon(for: itemKind(of: ref), offline: offline)
    }
}

// MARK: - Drops

/// What a drop onto the panel means. Internal item IDs always win over file URLs: dragging a media item out
/// also writes its file URL, and that must never re-import it.
public enum ProjectDrop: Equatable {
    case move([BinItemRef])
    case importFiles([URL])
    case none

    public static func classify(items: [BinItemRef], files: [URL], knownPaths: Set<String>) -> ProjectDrop {
        if !items.isEmpty { return .move(items) }
        let fresh = files.filter { !knownPaths.contains($0.path) }
        return fresh.isEmpty ? .none : .importFiles(fresh)
    }
}

extension ProjectPanelModel {
    public func classifyDrop(items: [BinItemRef], files: [URL]) -> ProjectDrop {
        ProjectDrop.classify(items: items, files: files, knownPaths: Set(project.media.map(\.path)))
    }
}

// MARK: - Saved column layout

/// Visible columns (in order) and widths of the Project panel, saved per user in UserDefaults.
public struct ProjectColumnLayout: Sendable, Equatable, Codable {
    public private(set) var visible: [ProjectPanelModel.Column]
    public private(set) var widths: [String: Double]

    public static let defaults = ProjectColumnLayout(visible: [.name, .format, .duration], widths: [:])
    public static let defaultsKey = "ProjectPanel.columns.v2"

    public init(visible: [ProjectPanelModel.Column], widths: [String: Double] = [:]) {
        var seen = Set<ProjectPanelModel.Column>()
        var v = visible.filter { $0 != .name && seen.insert($0).inserted }
        v.insert(.name, at: 0)
        self.visible = v
        self.widths = widths
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Unknown column names (from a newer version) are dropped instead of failing.
        let raw = try c.decodeIfPresent([String].self, forKey: .visible) ?? []
        self.init(visible: raw.compactMap(ProjectPanelModel.Column.init(rawValue:)),
                  widths: try c.decodeIfPresent([String: Double].self, forKey: .widths) ?? [:])
    }

    public func isVisible(_ c: ProjectPanelModel.Column) -> Bool { visible.contains(c) }

    /// Shows or hides a column (new ones go last). The name column cannot be hidden.
    public mutating func toggle(_ c: ProjectPanelModel.Column) {
        guard c != .name else { return }
        if let i = visible.firstIndex(of: c) { visible.remove(at: i) } else { visible.append(c) }
    }

    public mutating func move(_ c: ProjectPanelModel.Column, toIndex index: Int) {
        guard c != .name, let from = visible.firstIndex(of: c) else { return }
        visible.remove(at: from)
        visible.insert(c, at: min(max(index, 1), visible.count))
    }

    public mutating func setWidth(_ w: CGFloat, for c: ProjectPanelModel.Column) { widths[c.rawValue] = Double(w) }

    /// The width the user dragged a column to, nil while it is still automatic.
    public func userWidth(of c: ProjectPanelModel.Column) -> CGFloat? { widths[c.rawValue].map { CGFloat($0) } }

    public func width(of c: ProjectPanelModel.Column) -> CGFloat { widths[c.rawValue].map { CGFloat($0) } ?? c.defaultWidth }

    public static func load(from defaults: UserDefaults = .standard) -> ProjectColumnLayout {
        guard let data = defaults.data(forKey: defaultsKey),
              let l = try? JSONDecoder().decode(ProjectColumnLayout.self, from: data) else { return .defaults }
        return l
    }

    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

// MARK: - Automatic widths

/// Compact default widths: the name column fits its longest entry (clamped), the other columns wrap their widest text
/// with Theme spacing. Pure arithmetic on measured text widths; the view measures and a user drag overrides it.
public enum ProjectColumnSizing {
    public static let nameRange: ClosedRange<CGFloat> = 110...170
    /// Room for the sort arrow next to a header title.
    public static let headerExtra: CGFloat = 12
    static let maxAuto: CGFloat = 150

    // shortcut: the column widths read the Mac Theme spacing tokens; upgrade when the tokens move to the shared toolkit.
    #if os(macOS)
    /// Everything in the name cell besides the text: disclosure area, indentation of the deepest folder, icon, gaps.
    public static func nameChrome(maxDepth: Int) -> CGFloat {
        21 + CGFloat(max(maxDepth, 0)) * Theme.Spacing.treeIndent + 6 + 20 + Theme.Spacing.iconToLabel + Theme.Spacing.xs   // icon lead 6, box 20
    }

    public static func width(of c: ProjectPanelModel.Column, header: CGFloat, content: CGFloat, maxDepth: Int) -> CGFloat {
        let pad = 2 * Theme.Spacing.xs
        if c == .name {
            let w = max(content + nameChrome(maxDepth: maxDepth), header + pad + headerExtra)
            return min(max(w, nameRange.lowerBound), nameRange.upperBound)
        }
        let w = max(content + pad, header + pad + headerExtra)
        return min(max(w, c.minWidth), c == .filePath ? 360 : maxAuto)
    }
    #endif
}
