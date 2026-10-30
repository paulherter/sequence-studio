import Foundation
import Testing
import SQCore
@testable import SQEditAPI

/// Host backed by a plain History, standing in for EditorSession.
actor FakeHost: EditAPIHost {
    var history: History<Project>
    var active: Timeline.ID
    var busy = false
    /// Stands in for EditorSession's extra perform steps (style tokens, pending scale): renames the project.
    static func extraStep(_ p: inout Project) { p.name = "after extra steps" }
    init(_ f: Fixture) { history = History(f.project); active = f.seq }

    func project() async -> Project? { history.current }
    func activeSequence() async -> Timeline.ID? { active }
    func run(_ r: HostCommit) async throws -> (before: Project, after: Project) {
        try r.admit(active: active, busy: busy)
        let before = history.current
        let edit: (inout Project) throws -> Void = { try EditTransaction.apply(r.operations, to: &$0, sequence: r.sequence); Self.extraStep(&$0) }
        if r.dryRun { var p = before; try edit(&p); return (before, p) }
        try history.commit(r.name, edit)
        return (before, history.current)
    }
    func undo(ifTopStep accept: @Sendable (String) -> Bool) async -> Bool {
        guard !busy, let n = history.undoName, accept(n) else { return false }
        return history.undo()
    }
    func userEdit() { history.commit("Move") { $0.timelines[0].markers.append(Marker(time: .s(3))) } }
    func set(busy: Bool) { self.busy = busy }
    func set(active: Timeline.ID) { self.active = active }
    var depth: Int { history.undoDepth }
}

@Suite struct HTTPParserTests {
    @Test func parsesRequestWithBody() {
        let raw = "POST /v1/commit HTTP/1.1\r\nHost: 127.0.0.1:9\r\nContent-Length: 2\r\nAuthorization: Bearer t\r\n\r\n{}"
        guard case .complete(let r, let n) = HTTPParser.parse(Data(raw.utf8), maxBody: 100) else { Issue.record("no parse"); return }
        #expect(r.method == "POST" && r.path == "/v1/commit" && r.body == Data("{}".utf8))
        #expect(r.headers["host"] == "127.0.0.1:9" && r.headers["authorization"] == "Bearer t")
        #expect(n == raw.utf8.count)
    }

    @Test func incompleteUntilBodyArrives() {
        let raw = "POST /v1/commit HTTP/1.1\r\nContent-Length: 10\r\n\r\n{}"
        guard case .incomplete = HTTPParser.parse(Data(raw.utf8), maxBody: 100) else { Issue.record("expected incomplete"); return }
    }

    @Test func rejectsOversizeBodyAndHeaders() {
        let raw = "POST /x HTTP/1.1\r\nContent-Length: 1000\r\n\r\n"
        guard case .invalid(413) = HTTPParser.parse(Data(raw.utf8), maxBody: 100) else { Issue.record("expected 413"); return }
        let huge = Data(("GET /x HTTP/1.1\r\nX: " + String(repeating: "a", count: 20_000)).utf8)
        guard case .invalid(431) = HTTPParser.parse(huge, maxBody: 100) else { Issue.record("expected 431"); return }
        guard case .invalid(400) = HTTPParser.parse(Data("garbage\r\n\r\n".utf8), maxBody: 100) else { Issue.record("expected 400"); return }
        let chunked = "POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"
        guard case .invalid(411) = HTTPParser.parse(Data(chunked.utf8), maxBody: 100) else { Issue.record("expected 411"); return }
    }
}

@Suite struct RouterTests {
    let config = EditAPIConfig(token: "secret-token", port: 4321)

    func req(_ method: String, _ path: String, body: String = "", host: String = "127.0.0.1:4321",
             token: String? = "secret-token", origin: String? = nil) -> HTTPRequest {
        var h = ["host": host]
        if let token { h["authorization"] = "Bearer \(token)" }
        if let origin { h["origin"] = origin }
        return HTTPRequest(method: method, path: path, headers: h, body: Data(body.utf8))
    }

    func json(_ r: HTTPResponse) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any] ?? [:]
    }

    @Test func securityChecks() async {
        let router = EditAPIRouter(config: config, host: FakeHost(Fixture()))
        #expect(await router.handle(req("GET", "/v1/state", token: nil)).status == 401)
        #expect(await router.handle(req("GET", "/v1/state", token: "wrong")).status == 401)
        #expect(await router.handle(req("GET", "/v1/state", host: "evil.example:4321")).status == 403)   // DNS rebinding
        #expect(await router.handle(req("GET", "/v1/state", host: "127.0.0.1:9999")).status == 403)
        #expect(await router.handle(req("GET", "/v1/state", origin: "https://evil.example")).status == 403)
        #expect(await router.handle(req("GET", "/v1/state", host: "localhost:4321", origin: "http://localhost:4321")).status == 200)
        #expect(await router.handle(req("GET", "/nope")).status == 404)
        #expect(await router.handle(req("DELETE", "/v1/state")).status == 405)
    }

    @Test func stateReturnsSequences() async throws {
        let f = Fixture()
        let r = await EditAPIRouter(config: config, host: FakeHost(f)).handle(req("GET", "/v1/state"))
        #expect(r.status == 200)
        let s = try JSONDecoder().decode(ProjectState.self, from: r.body)
        #expect(s.sequences.first?.tracks.first?.clips.map(\.id) == [f.a, f.b])
    }

    func commitBody(_ f: Fixture, _ ops: String, name: String = "Tighten", dryRun: Bool = false, sequence: UUID? = nil) -> String {
        #"{"name":"\#(name)","dryRun":\#(dryRun),"sequence":"\#(sequence ?? f.seq)","operations":[\#(ops)]}"#
    }

    @Test func dryRunReturnsDiffRunsExtraStepsAndChangesNothing() async throws {
        let f = Fixture(); let host = FakeHost(f)
        let body = commitBody(f, #"{"op":"rippleDelete","clips":["\#(f.b)"]}"#, dryRun: true)
        let r = await EditAPIRouter(config: config, host: host).handle(req("POST", "/v1/commit", body: body))
        #expect(r.status == 200)
        let res = try JSONDecoder().decode(CommitResponse.self, from: r.body)
        #expect(res.applied == false && res.diff.removed.map(\.id) == [f.b])
        #expect(await host.depth == 0)
        let dry = try await host.run(HostCommit(name: "x", sequence: f.seq, operations: [.addMarker(at: .s(1), name: "")], dryRun: true))
        #expect(dry.after.name == "after extra steps")     // the host's perform steps ran on the copy
    }

    @Test func unknownKeysAreRefusedInsteadOfIgnored() async throws {
        let f = Fixture(); let host = FakeHost(f)
        let router = EditAPIRouter(config: config, host: host)
        let op = #"{"op":"rippleDelete","clips":["\#(f.b)"]}"#
        // A misspelled dryRun must not commit.
        let typo = #"{"dryrun":true,"sequence":"\#(f.seq)","operations":[\#(op)]}"#
        let r1 = await router.handle(req("POST", "/v1/commit", body: typo))
        #expect(r1.status == 400)
        #expect(String(decoding: r1.body, as: UTF8.self).contains("dryrun"))
        // An extra key inside an operation is refused too.
        let badOp = #"{"op":"razor","at":{"value":1,"timescale":1},"clip":"\#(f.b)"}"#
        #expect(await router.handle(req("POST", "/v1/commit", body: commitBody(f, badOp))).status == 400)
        #expect(await host.depth == 0)
    }

    @Test func commitIsOneUndoStepAndAgentUndoOnlyUndoesAgentSteps() async throws {
        let f = Fixture(); let host = FakeHost(f)
        let router = EditAPIRouter(config: config, host: host)
        let ops = #"{"op":"razor","at":{"value":1,"timescale":1}},{"op":"rippleDelete","clips":["\#(f.b)"]}"#
        let r = await router.handle(req("POST", "/v1/commit", body: commitBody(f, ops)))
        let res = try JSONDecoder().decode(CommitResponse.self, from: r.body)
        #expect(r.status == 200 && res.applied && res.undoName == "Agent: Tighten")
        #expect(await host.depth == 1)
        #expect(await router.handle(req("POST", "/v1/undo", body: #"{"expectedName":"Agent: Other"}"#)).status == 409)
        #expect(await router.handle(req("POST", "/v1/undo", body: #"{"expectedName":"Agent: Tighten"}"#)).status == 200)
        await host.userEdit()                                                  // the user's own step on top
        #expect(await router.handle(req("POST", "/v1/undo")).status == 409)
        #expect(await host.depth == 1)
    }

    @Test func failingBatchRollsBackWith422() async {
        let f = Fixture(); let host = FakeHost(f)
        let ops = #"{"op":"rippleDelete","clips":["\#(f.b)"]},{"op":"lift","clips":["\#(UUID())"]}"#
        let r = await EditAPIRouter(config: config, host: host).handle(req("POST", "/v1/commit", body: commitBody(f, ops)))
        #expect(r.status == 422)
        #expect(json(r)["operationIndex"] as? Int == 1)
        #expect(await host.depth == 0)
        #expect(await host.project() == f.project)
    }

    @Test func busyGestureAndChangedSequenceAreRefused() async {
        let f = Fixture(); let host = FakeHost(f)
        let router = EditAPIRouter(config: config, host: host)
        let op = #"{"op":"addMarker","at":{"value":1,"timescale":1}}"#
        await host.set(busy: true)
        #expect(await router.handle(req("POST", "/v1/commit", body: commitBody(f, op))).status == 409)
        await host.set(busy: false)
        #expect(await router.handle(req("POST", "/v1/commit", body: commitBody(f, op, sequence: UUID()))).status == 409)
        await host.set(active: UUID())                          // user switched sequence after the agent read state
        #expect(await router.handle(req("POST", "/v1/commit", body: commitBody(f, op))).status == 409)
        #expect(await host.depth == 0)
        let noSeq = #"{"operations":[\#(op)]}"#
        #expect(await router.handle(req("POST", "/v1/commit", body: noSeq)).status == 400)
    }

    @Test func cancelledRequestIsNotApplied() async {
        let f = Fixture(); let host = FakeHost(f)
        let router = EditAPIRouter(config: config, host: host)
        let r = req("POST", "/v1/commit", body: commitBody(f, #"{"op":"addMarker","at":{"value":1,"timescale":1}}"#))
        let t = Task { () -> HTTPResponse in
            try? await Task.sleep(for: .seconds(5))   // returns early once canceled, like the connection deadline
            return await router.handle(r)
        }
        t.cancel()
        #expect(await t.value.status == 503)
        #expect(await host.depth == 0)
    }

    @Test func hugeTimesAreRejectedWithoutCrashing() async {
        let f = Fixture(); let host = FakeHost(f)
        let router = EditAPIRouter(config: config, host: host)
        let huge = #"{"op":"trim","clip":"\#(f.a)","edge":"tail","by":{"value":9223372036854775807,"timescale":9223372036854775807}}"#
        #expect(await router.handle(req("POST", "/v1/commit", body: commitBody(f, huge))).status == 400)
        #expect(await router.handle(req("POST", "/v1/commit", body: commitBody(f, huge, dryRun: true))).status == 400)
        let big = #"{"op":"razor","at":{"value":-9223372036854775808,"timescale":1}}"#
        #expect(await router.handle(req("POST", "/v1/commit", body: commitBody(f, big))).status == 400)
        #expect(await host.depth == 0)
    }

    @Test func limitsAndBadInput() async {
        let f = Fixture()
        let small = EditAPIConfig(token: "secret-token", port: 4321, maxOperations: 1)
        let router = EditAPIRouter(config: small, host: FakeHost(f))
        let two = commitBody(f, #"{"op":"addMarker","at":{"value":1,"timescale":1}},{"op":"addMarker","at":{"value":2,"timescale":1}}"#)
        #expect(await router.handle(req("POST", "/v1/commit", body: two)).status == 413)
        #expect(await router.handle(req("POST", "/v1/commit", body: "{nope")).status == 400)
        #expect(await router.handle(req("POST", "/v1/commit", body: commitBody(f, ""))).status == 400)
    }
}

