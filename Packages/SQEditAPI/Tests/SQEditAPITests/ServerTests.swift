import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import SQCore
@testable import SQEditAPI

private final class Box: @unchecked Sendable {
    let lock = NSLock(); var states: [EditAPIServer.State] = []
    func add(_ s: EditAPIServer.State) { lock.lock(); states.append(s); lock.unlock() }
    var ready: Bool { lock.lock(); defer { lock.unlock() }; return states.contains { if case .ready = $0 { true } else { false } } }
}

@Suite(.serialized) struct ServerTests {
    @Test func servesOverLoopbackWithToken() async throws {
        let port = UInt16.random(in: 41000...48000)
        let token = EditAPIConfig.makeToken()
        #expect(token.count == 64)
        let box = Box()
        let server = EditAPIServer(router: EditAPIRouter(config: EditAPIConfig(token: token, port: port), host: FakeHost(Fixture())),
                                   onState: { box.add($0) })
        server.start()
        defer { server.stop() }
        for _ in 0..<SQTiming.polls(100) where !box.ready { try await Task.sleep(for: .milliseconds(20)) }
        #expect(box.ready)

        var r = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/state")!)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: r)
        #expect((resp as? HTTPURLResponse)?.statusCode == 200)
        #expect(try JSONDecoder().decode(ProjectState.self, from: data).sequences.count == 1)

        r.setValue("Bearer nope", forHTTPHeaderField: "Authorization")
        let (_, bad) = try await URLSession.shared.data(for: r)
        #expect((bad as? HTTPURLResponse)?.statusCode == 401)
    }

    @Test func discoveryFileIsPrivate() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sqapi-\(UUID().uuidString)/edit-api.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let d = EditAPIDiscovery(port: 1234, token: "t", pid: 1)
        try d.write(to: url)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
        #expect(try JSONDecoder().decode(EditAPIDiscovery.self, from: Data(contentsOf: url)) == d)
        EditAPIDiscovery.remove(at: url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
