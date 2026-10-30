import Foundation
import SQCore

/// The app side of the API: the live project and ONE place that commits (EditorSession in the app).
public protocol EditAPIHost: Sendable {
    func project() async -> Project?
    func activeSequence() async -> Timeline.ID?
    /// On the host's own actor: `request.admit(...)` first, then (dry run) the result `perform` would produce on a copy,
    /// or (commit) applies the operations as ONE undo step named `request.name` via `EditTransaction.apply` inside the
    /// session's commit. Throws and changes nothing when anything fails. Returns the project before and after.
    func run(_ request: HostCommit) async throws -> (before: Project, after: Project)
    /// Undoes the top step only when `accept(its undo name)` holds, checked and undone in one step on the host's actor.
    func undo(ifTopStep accept: @Sendable (String) -> Bool) async -> Bool
}

public struct EditAPIConfig: Sendable {
    public var token: String
    public var port: UInt16
    public var maxBodyBytes: Int
    public var maxOperations: Int

    public init(token: String, port: UInt16, maxBodyBytes: Int = 1 << 20, maxOperations: Int = 1000) {
        self.token = token; self.port = port; self.maxBodyBytes = maxBodyBytes; self.maxOperations = maxOperations
    }

    /// 32 random bytes, hex. A new one every launch.
    public static func makeToken() -> String {
        var g = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &g)) }.joined()
    }
}

public struct CommitRequest: Codable, Sendable {
    /// The sequence the agent read (`activeSequence` of `/v1/state`). Required: the commit is refused (409) when it is
    /// no longer the active sequence, so a sequence switch in between never redirects the edit.
    public var sequence: UUID
    /// Undo name after "Agent: "; nil = "Agent Edit".
    public var name: String?
    public var dryRun: Bool?
    public var operations: [EditOperation]

    private enum CodingKeys: String, CodingKey { case sequence, name, dryRun, operations }

    public init(sequence: UUID, name: String? = nil, dryRun: Bool? = nil, operations: [EditOperation]) {
        self.sequence = sequence; self.name = name; self.dryRun = dryRun; self.operations = operations
    }

    /// Strict: a misspelled `dryRun` must not turn a preview into a commit.
    public init(from decoder: Decoder) throws {
        try StrictKeys.check(decoder, allowed: ["sequence", "name", "dryRun", "operations"], what: "commit request")
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sequence = try c.decode(UUID.self, forKey: .sequence)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        dryRun = try c.decodeIfPresent(Bool.self, forKey: .dryRun)
        operations = try c.decode([EditOperation].self, forKey: .operations)
    }
}

public struct CommitResponse: Codable, Sendable, Equatable {
    public var applied: Bool
    public var sequence: UUID
    public var undoName: String
    public var diff: EditDiff
}

/// Routes and guards requests. Pure apart from the host calls, so every security rule is unit-tested.
///
/// - `GET  /v1/state`   project read model (`ProjectState`)
/// - `POST /v1/commit`  `CommitRequest` -> `CommitResponse`; `dryRun` returns the diff without changing anything
/// - `POST /v1/undo`    undoes the last step only if it is an "Agent: ..." step (`{"expectedName"?: "Agent: X"}`)
public struct EditAPIRouter: Sendable {
    public let config: EditAPIConfig
    public let host: any EditAPIHost

    public init(config: EditAPIConfig, host: any EditAPIHost) { self.config = config; self.host = host }

    public func handle(_ r: HTTPRequest) async -> HTTPResponse {
        if let refused = guardRequest(r) { return refused }
        switch (r.method, r.path) {
        case ("GET", "/v1/state"):
            guard let p = await host.project() else { return .error(503, "no project open") }
            var s = ProjectState(p)
            if let a = await host.activeSequence() { s.activeSequence = a }
            return .json(200, s)
        case ("POST", "/v1/commit"): return await commit(r.body)
        case ("POST", "/v1/undo"): return await undo(r.body)
        case (_, "/v1/state"), (_, "/v1/commit"), (_, "/v1/undo"): return .error(405, "method not allowed")
        default: return .error(404, "unknown endpoint")
        }
    }

    /// Host must name the loopback listener (DNS rebinding), a browser Origin must be loopback too, and the bearer
    /// token must match (constant-time compare).
    func guardRequest(_ r: HTTPRequest) -> HTTPResponse? {
        let port = String(config.port)
        let loopback = ["127.0.0.1:\(port)", "localhost:\(port)"]
        guard let host = r.headers["host"]?.lowercased(), loopback.contains(host) else { return .error(403, "bad host") }
        if let origin = r.headers["origin"]?.lowercased(), !loopback.map({ "http://" + $0 }).contains(origin) {
            return .error(403, "cross-origin requests are refused")
        }
        guard let auth = r.headers["authorization"], auth.hasPrefix("Bearer "),
              Self.constantTimeEqual(String(auth.dropFirst(7)), config.token) else { return .error(401, "missing or wrong token") }
        guard r.body.count <= config.maxBodyBytes else { return .error(413, "body too large") }
        return nil
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var d: UInt8 = 0
        for i in x.indices { d |= x[i] ^ y[i] }
        return d == 0
    }

    private func commit(_ body: Data) async -> HTTPResponse {
        let req: CommitRequest
        do { req = try JSONDecoder().decode(CommitRequest.self, from: body) } catch {
            return .error(400, "invalid request: \(Self.describe(error))")
        }
        guard !req.operations.isEmpty else { return .error(400, "operations is empty") }
        guard req.operations.count <= config.maxOperations else { return .error(413, "more than \(config.maxOperations) operations") }
        let seq = req.sequence
        let label = (req.name?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : String($0.prefix(80)) }
        let undoName = "Agent: " + (label ?? "Edit")
        let dry = req.dryRun == true
        do {
            try EditTransaction.validate(req.operations)        // before any Time arithmetic, dry run included
            if Task.isCancelled { throw TransactionError(.cancelled) }
            let (before, after) = try await host.run(HostCommit(name: undoName, sequence: seq, operations: req.operations, dryRun: dry))
            guard let b = before.timeline(seq), let a = after.timeline(seq) else { return .error(409, "sequence vanished") }
            var diff = EditDiff(before: b, after: a)
            diff.noteMedia(before: before, after: after)
            return .json(200, CommitResponse(applied: !dry && !diff.isEmpty, sequence: seq, undoName: undoName, diff: diff))
        } catch let e as TransactionError {
            return .error(Self.status(e), e.message, operationIndex: e.operationIndex)
        } catch {
            return .error(422, String(describing: error))
        }
    }

    static func status(_ e: TransactionError) -> Int {
        switch e.kind {
        case .edit(.timelineNotFound) where e.operationIndex == nil: 404
        case .edit, .mediaNotFound, .noPicture: 422
        case .invalidTime: 400
        case .busy, .sequenceChanged: 409
        case .cancelled: 503
        }
    }

    struct UndoRequest: Decodable { var expectedName: String? }

    /// Undo for agents: only an "Agent: ..." step (and, if given, exactly `expectedName`), so an agent never undoes
    /// the user's own edit.
    private func undo(_ body: Data) async -> HTTPResponse {
        let parsed = body.isEmpty ? UndoRequest() : try? JSONDecoder().decode(UndoRequest.self, from: body)
        guard let parsed else { return .error(400, "invalid request") }
        let expected = parsed.expectedName
        let ok = await host.undo { name in name.hasPrefix("Agent: ") && (expected == nil || name == expected) }
        return ok ? .json(200, ["undone": true]) : .error(409, "the last step is not this agent's edit")
    }

    private static func describe(_ e: Error) -> String {
        guard let d = e as? DecodingError else { return String(describing: e) }
        switch d {
        case .dataCorrupted(let c), .keyNotFound(_, let c), .typeMismatch(_, let c), .valueNotFound(_, let c):
            let path = c.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
            return (path.isEmpty ? "" : path + ": ") + c.debugDescription
        @unknown default: return String(describing: d)
        }
    }
}
