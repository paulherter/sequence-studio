import Foundation
import SQCore
import SQLibrary
import SQUIKit

/// One row of the quick-apply palette (Option+Space).
public struct QuickApplyItem: Sendable, Hashable, Identifiable {
    public enum Action: Sendable, Hashable {
        case effect(String)
        case transition(TransitionKind)
        case preset(UUID, PresetKind)
        case builtInPreset(String)
        case command(EditorCommand)
        /// "Save Effect Stack as Preset…": the selected clip's Motion/Opacity/effects go to the Library through the existing preset sheet.
        case saveStackAsPreset
        /// An ordered list of other palette rows applied in one step (one undo step).
        case macro(String)
    }
    public var id: String
    public var title: String
    public var category: String
    public var action: Action
    public init(id: String, title: String, category: String, action: Action) {
        self.id = id; self.title = title; self.category = category; self.action = action
    }
}

/// A macro: palette row ids applied in order as one undo step. Only rows that already exist (commands, effects, presets).
public struct QuickApplyMacro: Sendable, Hashable, Codable {
    public var id: String
    public var name: String
    public var steps: [String]
    public init(id: String, name: String, steps: [String]) { self.id = id; self.name = name; self.steps = steps }

    /// Starters. shortcut: built-in only, no user-defined macros; add a "save recents as macro" sheet when asked for.
    public static let builtIn: [QuickApplyMacro] = [
        QuickApplyMacro(id: "cleanVoice", name: "Clean Voice", steps: ["command.\(EditorCommand.voiceChain.id)", "command.\(EditorCommand.matchLoudness.id)"]),
    ]
}

/// Everything the palette can apply, built from the same lists the rest of the app shows: the Effects panel catalog
/// (video and audio effects, transitions), its built-in presets, the Library presets and every supported menu command.
/// Nothing is listed here by hand, so a new effect in the panel is searchable at once. The panel lists live in
/// SQDrawLibrary (`QuickApplyCatalog.items(presets:)` there); this builder takes them as plain (id, title) pairs.
public enum QuickApplyCatalog {
    @MainActor public static func items(effects: [(id: String, title: String)], builtInPresets: [(id: String, title: String)],
                             presets: [PresetItem]) -> [QuickApplyItem] {
        var out: [QuickApplyItem] = []
        var titles = Set<String>()
        func add(_ item: QuickApplyItem) {
            guard titles.insert(item.title.lowercased()).inserted || item.category == "Preset" || item.category == "Transition Preset" else { return }
            out.append(item)
        }
        for e in effects {
            if let k = EffectDragPayload.transitionKind(forID: e.id) {
                add(QuickApplyItem(id: "transition.\(k.rawValue)", title: e.title,
                                   category: k.trackKind == .video ? "Video Transition" : "Audio Transition", action: .transition(k)))
            } else {
                add(QuickApplyItem(id: "effect.\(e.id)", title: e.title,
                                   category: ClipEffect.isAudioKind(e.id) ? "Audio Effect" : "Effect", action: .effect(e.id)))
            }
        }
        for e in builtInPresets {
            let id = String(e.id.dropFirst(EditorSession.builtInPresetPrefix.count))
            add(QuickApplyItem(id: e.id, title: e.title, category: "Preset", action: .builtInPreset(id)))
        }
        for p in presets {
            add(QuickApplyItem(id: "preset.\(p.id.uuidString)", title: p.name, category: p.kind == .transition ? "Transition Preset" : "Preset", action: .preset(p.id, p.kind)))
        }
        for c in EditorMenus.all.flatMap(\.commands) where c != .quickApply && CommandSupport.isSupported(c) {
            add(QuickApplyItem(id: "command.\(c.id)", title: c.title, category: "Command", action: .command(c)))
        }
        for m in QuickApplyMacro.builtIn where m.steps.allSatisfy({ s in out.contains { $0.id == s } }) {
            add(QuickApplyItem(id: "macro.\(m.id)", title: m.name, category: "Macro", action: .macro(m.id)))
        }
        add(QuickApplyItem(id: "macro.saveStackAsPreset", title: "Save Effect Stack as Preset\u{2026}", category: "Command", action: .saveStackAsPreset))
        return out
    }
}

/// Fuzzy subsequence ranking. Recents win ties (and get a small bonus); with an empty query the recents come first.
public enum QuickApplyRanking {
    static let recentBonus = 6

    /// nil = not a subsequence. Higher is better.
    public static func score(query: String, title: String) -> Int? {
        let q = Array(query.lowercased().filter { !$0.isWhitespace })
        let t = Array(title.lowercased())
        guard !q.isEmpty else { return 0 }
        var score = 0, ti = 0, last = -1
        for qc in q {
            guard let hit = t[ti...].firstIndex(of: qc) else { return nil }
            let wordStart = hit == 0 || !t[hit - 1].isLetter && !t[hit - 1].isNumber
            if hit == 0 { score += 15 }
            if wordStart { score += 10 }
            if hit == last + 1 { score += 5 } else if last >= 0 { score -= hit - last - 1 }
            last = hit
            ti = hit + 1
        }
        return score
    }

    public static func rank(_ items: [QuickApplyItem], query: String, recents: [String], limit: Int) -> [QuickApplyItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let recentIndex = Dictionary(recents.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        if q.isEmpty {
            let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let head = recents.compactMap { byID[$0] }
            let rest = items.filter { recentIndex[$0.id] == nil }
            return Array((head + rest).prefix(limit))
        }
        var scored: [(item: QuickApplyItem, score: Int, order: Int)] = []
        for (i, item) in items.enumerated() {
            guard let s = score(query: q, title: item.title) else { continue }
            scored.append((item, s + (recentIndex[item.id] == nil ? 0 : recentBonus), i))
        }
        scored.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            let ra = recentIndex[$0.item.id] ?? Int.max, rb = recentIndex[$1.item.id] ?? Int.max
            if ra != rb { return ra < rb }
            if $0.item.title.count != $1.item.title.count { return $0.item.title.count < $1.item.title.count }
            return $0.order < $1.order
        }
        return scored.prefix(limit).map(\.item)
    }
}

/// What Return does with the chosen row, given the current selection.
public enum QuickApplyTarget {
    public enum Resolution: Equatable, Sendable {
        case effect(kind: String, clips: Set<Clip.ID>)
        case transition(TransitionKind)
        case preset(UUID, PresetKind)
        case builtInPreset(String)
        case command(EditorCommand)
        case saveStackAsPreset
        case macro(QuickApplyMacro)
        case refused(String)
    }

    /// The clip edges a transition goes to when the user picked "start", "end" or both for the selected clips.
    public static func edges(for clips: Set<Clip.ID>, end: TransitionEnd) -> EdgeSelection {
        let sides: [ClipEdge] = switch end {
        case .start: [.head]
        case .end: [.tail]
        case .both: [.head, .tail]
        }
        return EdgeSelection(edges: clips.sorted { $0.uuidString < $1.uuidString }.flatMap { c in sides.map { EdgeRef(clip: c, edge: $0) } })
    }

    /// `audioTargets`: the selected audio clips plus the linked audio of selected video clips (for audio effects).
    public static func resolve(_ item: QuickApplyItem, selectedVideoClips: Set<Clip.ID>,
                               audioTargets: Set<Clip.ID> = []) -> Resolution {
        switch item.action {
        case .effect(let kind) where ClipEffect.isAudioKind(kind):
            audioTargets.isEmpty ? .refused("Select an audio clip to apply \(item.title).") : .effect(kind: kind, clips: audioTargets)
        case .effect(let kind):
            selectedVideoClips.isEmpty ? .refused("Select a video clip to apply \(item.title).") : .effect(kind: kind, clips: selectedVideoClips)
        case .transition(let k): .transition(k)
        case .preset(let id, let kind): .preset(id, kind)
        case .builtInPreset(let id): .builtInPreset(id)
        case .command(let c): .command(c)
        case .macro(let id):
            QuickApplyMacro.builtIn.first { $0.id == id }.map { .macro($0) } ?? .refused("This macro no longer exists.")
        case .saveStackAsPreset:
            selectedVideoClips.count == 1 ? .saveStackAsPreset : .refused("Select one video clip to save its effects as a preset.")
        }
    }
}

/// Where a transition goes on the selected clips.
public enum TransitionEnd: Sendable, Equatable { case start, end, both }

@MainActor
public final class QuickApplyModel {
    public nonisolated static let maxRecents = 8
    public static let recentsKey = "sq.palette.recents"
    static let legacyRecentsKey = "sq.quickApply.recents"
    static let lastQueryKey = "sq.quickApply.lastQuery"
    static let resultLimit = 40

    public private(set) var items: [QuickApplyItem]
    public private(set) var recents: [String]
    public private(set) var results: [QuickApplyItem] = []
    public private(set) var selectedIndex = 0
    public var query = "" { didSet { defaults.set(query, forKey: Self.lastQueryKey); refresh() } }
    /// Set while the start/end popup is up for this transition row.
    public private(set) var pendingTransition: QuickApplyItem?
    public private(set) var transitionEnd: TransitionEnd = .both
    public var onChange: (() -> Void)?
    private let defaults: UserDefaults

    public init(items: [QuickApplyItem], defaults: UserDefaults = .standard) {
        self.items = items
        self.defaults = defaults
        if let r = defaults.stringArray(forKey: Self.recentsKey) {
            recents = Array(r.prefix(Self.maxRecents))
        } else if let old = defaults.stringArray(forKey: Self.legacyRecentsKey) {
            recents = Array(old.prefix(Self.maxRecents))
            defaults.set(recents, forKey: Self.recentsKey)
        } else { recents = [] }
        refresh()
    }

    public var selected: QuickApplyItem? { results.indices.contains(selectedIndex) ? results[selectedIndex] : nil }

    /// The "Recent" section: recents are listed first on an empty query, and only then.
    public func isRecentRow(_ item: QuickApplyItem) -> Bool {
        query.trimmingCharacters(in: .whitespaces).isEmpty && recents.contains(item.id)
    }

    public func setItems(_ new: [QuickApplyItem]) { items = new; refresh() }

    public func reset() { query = ""; refresh() }

    /// Opening the palette again: the last search comes back (the panel selects it so typing replaces it, Delete clears it).
    public func reopen() {
        pendingTransition = nil
        transitionEnd = .both
        query = defaults.string(forKey: Self.lastQueryKey) ?? ""
    }

    public enum Outcome: Equatable {
        case none
        /// Apply `item`; `end` is set when the user chose start or end for a transition.
        case apply(QuickApplyItem, end: TransitionEnd?)
        /// Show the start/end popup for this transition first.
        case askEnd(QuickApplyItem)
    }

    /// Return: transitions with selected clips (`canChooseEnd`) ask for start or end first, everything else applies.
    public func confirm(canChooseEnd: Bool) -> Outcome {
        if let item = pendingTransition {
            let end = transitionEnd
            pendingTransition = nil
            guard commit() != nil else { return .none }
            return .apply(item, end: end)
        }
        guard let item = selected else { return .none }
        if canChooseEnd, case .transition = item.action {
            pendingTransition = item
            transitionEnd = .both
            onChange?()
            return .askEnd(item)
        }
        guard let chosen = commit() else { return .none }
        return .apply(chosen, end: nil)
    }

    /// Left (start), Right (end) or Down (both) in the end popup; Return then confirms.
    public func chooseEnd(_ end: TransitionEnd) {
        guard pendingTransition != nil else { return }
        transitionEnd = end
        onChange?()
    }

    public func cancelEndChoice() {
        guard pendingTransition != nil else { return }
        pendingTransition = nil
        onChange?()
    }

    public func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), results.count - 1)
        onChange?()
    }

    public func select(_ index: Int) {
        guard results.indices.contains(index) else { return }
        selectedIndex = index
        onChange?()
    }

    /// Records the highlighted row as used and returns it; the caller applies it.
    public func commit() -> QuickApplyItem? {
        guard let item = selected else { return nil }
        recents = Self.pushRecent(item.id, into: recents)
        defaults.set(recents, forKey: Self.recentsKey)
        return item
    }

    public nonisolated static func pushRecent(_ id: String, into list: [String]) -> [String] {
        Array(([id] + list.filter { $0 != id }).prefix(maxRecents))
    }

    private func refresh() {
        results = QuickApplyRanking.rank(items, query: query, recents: recents, limit: Self.resultLimit)
        selectedIndex = 0
        onChange?()
    }
}

