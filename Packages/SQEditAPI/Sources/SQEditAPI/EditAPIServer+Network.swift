import Foundation
#if canImport(Network)
import Network

/// Loopback-only HTTP listener for `EditAPIRouter`. Binds 127.0.0.1 (never a public interface), refuses non-loopback
/// peers, one request per connection, bounded size and a 15 s deadline per connection. All state lives on `queue`.
public final class EditAPIServer: @unchecked Sendable {
    public enum State: Sendable, Equatable { case starting, ready(UInt16), failed(String), stopped }

    public let router: EditAPIRouter
    private let queue = DispatchQueue(label: "sq.editapi")
    private var listener: NWListener?
    private let onState: @Sendable (State) -> Void

    public init(router: EditAPIRouter, onState: @escaping @Sendable (State) -> Void = { _ in }) {
        self.router = router; self.onState = onState
    }

    public func start() {
        queue.async { [self] in
            guard listener == nil else { return }
            let params = NWParameters.tcp
            params.acceptLocalOnly = true
            params.allowLocalEndpointReuse = true
            guard let port = NWEndpoint.Port(rawValue: router.config.port) else { onState(.failed("bad port")); return }
            params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
            do {
                let l = try NWListener(using: params)
                l.stateUpdateHandler = { [weak self] s in
                    guard let self else { return }
                    switch s {
                    case .ready: self.onState(.ready(self.router.config.port))
                    case .failed(let e): self.onState(.failed(String(describing: e))); self.stop()
                    case .cancelled: self.onState(.stopped)
                    default: break
                    }
                }
                l.newConnectionHandler = { [weak self] c in self?.accept(c) }
                listener = l
                onState(.starting)
                l.start(queue: queue)
            } catch {
                onState(.failed(String(describing: error)))
            }
        }
    }

    public func stop() {
        queue.async { [self] in listener?.cancel(); listener = nil }
    }

    /// Open connections; more than `maxConnections` at once are refused (closed at once).
    private var limiter = ConnectionLimiter(max: 8)
    public static let timeout: TimeInterval = 15

    /// One connection: its request task, so the deadline can cancel a commit that has not started yet.
    private final class Conn: @unchecked Sendable {   // touched on `queue` only
        let c: NWConnection
        var task: Task<Void, Never>?
        var released = false
        init(_ c: NWConnection) { self.c = c }
    }

    private func accept(_ c: NWConnection) {
        guard Self.isLoopback(c.endpoint), limiter.acquire() else { c.cancel(); return }
        let conn = Conn(c)
        c.stateUpdateHandler = { [weak self] s in
            switch s {
            case .cancelled, .failed: self?.release(conn)
            default: break
            }
        }
        c.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.timeout) { [weak self] in
            conn.task?.cancel()        // a commit still waiting for the main actor is dropped, not applied late
            c.cancel()
            self?.release(conn)
        }
        receive(conn, buffer: Data())
    }

    private func release(_ conn: Conn) {
        guard !conn.released else { return }
        conn.released = true
        conn.task?.cancel()
        limiter.release()
    }

    private func receive(_ conn: Conn, buffer: Data) {
        let c = conn.c
        c.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, error in
            guard let self else { c.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            switch HTTPParser.parse(buf, maxBody: self.router.config.maxBodyBytes) {
            case .invalid(let status): self.send(.error(status, "bad request"), on: c)
            case .complete(let req, _):
                guard !conn.released else { return }
                let router = self.router
                conn.task = Task {
                    let resp = await router.handle(req)
                    self.queue.async { if !conn.released { self.send(resp, on: c) } }
                }
            case .incomplete:
                if done || error != nil { c.cancel() } else { self.receive(conn, buffer: buf) }
            }
        }
    }

    static func isLoopback(_ e: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = e else { return false }
        switch host {
        case .ipv4(let a): return a.isLoopback
        case .ipv6(let a): return a.isLoopback || a == IPv6Address("::ffff:127.0.0.1")
        case .name(let n, _): return n == "localhost" || n == "127.0.0.1"
        @unknown default: return false
        }
    }


    private func send(_ r: HTTPResponse, on c: NWConnection) {
        c.send(content: r.serialized(), contentContext: .finalMessage, isComplete: true,
               completion: .contentProcessed { _ in c.cancel() })
    }
}
#endif
