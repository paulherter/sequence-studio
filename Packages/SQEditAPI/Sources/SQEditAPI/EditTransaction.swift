import Foundation
import SQCore

/// Why a batch was refused. Nothing was applied.
public struct TransactionError: Error, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// SQCore refused an edit.
        case edit(EditError)
        /// A media operation names an item the project does not have.
        case mediaNotFound
        /// A pixel aspect operation names media without a probed picture (audio, unprobed).
        case noPicture
        /// An operation carries a time outside `TimeLimits`.
        case invalidTime
        /// A timeline gesture is in progress; try again.
        case busy
        /// The sequence the agent read is no longer the active one.
        case sequenceChanged
        /// The request timed out or its connection went away before the commit.
        case cancelled
    }

    public var kind: Kind
    /// The first operation that failed; nil when the failure is not tied to one (e.g. the nesting check at the end).
    public var operationIndex: Int?
    public var operation: String?

    public init(_ kind: Kind, operationIndex: Int? = nil, operation: String? = nil) {
        self.kind = kind; self.operationIndex = operationIndex; self.operation = operation
    }

    public var underlying: EditError? { if case .edit(let e) = kind { e } else { nil } }

    public var message: String {
        let at = operationIndex.map { "operation \($0)" + (operation.map { " (\($0))" } ?? "") + ": " } ?? ""
        let what = switch kind {
        case .edit(let e): String(describing: e)
        case .mediaNotFound: "media not found"
        case .noPicture: "the media has no probed picture, its pixel aspect cannot be set"
        case .invalidTime: TimeLimits.message
        case .busy: "a timeline edit is in progress, try again"
        case .sequenceChanged: "the active sequence changed since it was read"
        case .cancelled: "request canceled"
        }
        return at + what
    }
}

/// An agent commit: a batch of operations applied all-or-nothing to one sequence. All times are validated first; then
/// the batch runs on a copy through `Project.edit` (nesting-cycle check, transition pruning) like every timeline edit; a
/// failure throws and leaves the project untouched. Wrap the call in one `History.commit` / `EditorSession.perform` for
/// ONE undo step.
public enum EditTransaction {
    public static func validate(_ ops: [EditOperation]) throws {
        for (i, op) in ops.enumerated() where !op.times.allSatisfy(TimeLimits.isValid) {
            throw TransactionError(.invalidTime, operationIndex: i, operation: op.name)
        }
    }

    public static func apply(_ ops: [EditOperation], to project: inout Project, sequence: Timeline.ID) throws {
        try validate(ops)
        guard project.timeline(sequence) != nil else { throw TransactionError(.edit(.timelineNotFound)) }
        // Media settings first, on a copy: they do not touch the timeline, and a refusal leaves the project untouched.
        var work = project
        for (i, op) in ops.enumerated() {
            guard case let .setPixelAspect(media, aspect) = op else { continue }
            guard let item = work.media(media) else { throw TransactionError(.mediaNotFound, operationIndex: i, operation: op.name) }
            guard item.info?.video != nil else { throw TransactionError(.noPicture, operationIndex: i, operation: op.name) }
            work.setPixelAspect(aspect, for: media)
        }
        var index: Int?
        do {
            try work.edit(sequence) { t in
                for (i, op) in ops.enumerated() {
                    index = i
                    try apply(op, to: &t)
                }
                index = nil                    // errors after the loop (nesting check) belong to no single operation
                t.normalizeAudioKeyMarks()     // as EditorSession.performTimeline does after every edit
            }
        } catch let e as EditError {
            throw TransactionError(.edit(e), operationIndex: index, operation: index.map { ops[$0].name })
        }
        project = work
    }

    /// `apply` on a copy, off the caller's actor (PALMIER-ISSUES #107): a read-only dry run must not hold the main actor,
    /// which playback's render loop shares (200 razors over 600 lanes take about 340 ms). Only value types cross.
    public static func applyOffActor(_ ops: [EditOperation], to project: Project, sequence: Timeline.ID) async throws -> Project {
        let result = try await Task.detached(priority: .userInitiated) { () throws -> Project in
            var p = project
            try apply(ops, to: &p, sequence: sequence)
            return p
        }.value
        if Task.isCancelled { throw TransactionError(.cancelled) }
        return result
    }

    /// The would-be result and its diff; `project` is not changed.
    public static func preview(_ ops: [EditOperation], on project: Project, sequence: Timeline.ID) throws -> (Project, EditDiff) {
        var p = project
        try apply(ops, to: &p, sequence: sequence)
        return (p, EditDiff(before: project.timeline(sequence)!, after: p.timeline(sequence)!))
    }

    static func apply(_ op: EditOperation, to t: inout Timeline) throws {
        func unlocked() -> [Track.ID] { t.tracks.filter { !$0.isLocked }.map(\.id) }
        switch op {
        case let .razor(at, tracks): _ = try t.addEdit(at: at, tracks: tracks)
        case .rippleDelete(let ids): _ = try t.rippleDelete(ids)
        case .lift(let ids): try t.lift(ids)
        case let .extract(r, tracks): _ = try t.extract(r, tracks: tracks ?? unlocked())
        case let .liftRange(r, tracks): try t.lift(r, tracks: tracks ?? unlocked())
        case let .trim(id, e, by): _ = try t.trim(id, edge: e, by: by)
        case let .rippleTrim(id, e, by): _ = try t.rippleTrim(id, edge: e, by: by)
        case let .move(id, to, track): try t.move(id, to: to, track: track)
        case let .slip(id, by): _ = try t.slip(id, by: by)
        case let .slide(id, by): _ = try t.slide(id, by: by)
        case let .roll(id, by): _ = try t.roll(id, by: by)
        case .toggleEnabled(let ids): _ = try t.toggleEnabled(Set(ids))
        case let .addMarker(at, name): _ = t.addMarker(at: at, name: name)
        case .setPixelAspect: break      // a media setting: applied by `apply(_:to:sequence:)` before the timeline edits
        }
    }
}

/// One request to the host: what to apply, where, and whether only to preview it.
public struct HostCommit: Sendable {
    public var name: String
    public var sequence: Timeline.ID
    public var operations: [EditOperation]
    public var dryRun: Bool

    public init(name: String, sequence: Timeline.ID, operations: [EditOperation], dryRun: Bool) {
        self.name = name; self.sequence = sequence; self.operations = operations; self.dryRun = dryRun
    }

    /// The checks every host runs on its own actor right before applying: not canceled (timed-out connection), no
    /// gesture in progress, and the sequence the agent read is still the active one.
    public func admit(active: Timeline.ID?, busy: Bool) throws {
        if Task.isCancelled { throw TransactionError(.cancelled) }
        if busy { throw TransactionError(.busy) }
        if active != sequence { throw TransactionError(.sequenceChanged) }
    }
}
