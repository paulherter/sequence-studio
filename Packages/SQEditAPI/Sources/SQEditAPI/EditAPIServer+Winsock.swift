#if os(Windows)
import Foundation
import WinSDK

/// Windows twin of the Network.framework server: loopback-only HTTP over blocking winsock sockets, one thread per
/// connection, one request per connection, same limits as the Mac server (8 connections, 15 s deadline, body cap).
/// shortcut: blocking threads instead of IOCP; fine for a local tool API, upgrade if it ever serves many clients.
public final class EditAPIServer: @unchecked Sendable {
    public enum State: Sendable, Equatable { case starting, ready(UInt16), failed(String), stopped }

    public let router: EditAPIRouter
    public static let timeout: TimeInterval = 15
    private let onState: @Sendable (State) -> Void
    private let lock = NSLock()
    private var listenSocket: SOCKET = INVALID_SOCKET
    private var limiter = ConnectionLimiter(max: 8)
    private var running = false

    public init(router: EditAPIRouter, onState: @escaping @Sendable (State) -> Void = { _ in }) {
        self.router = router; self.onState = onState
    }

    public func start() {
        lock.lock(); defer { lock.unlock() }
        guard !running else { return }
        onState(.starting)
        var data = WSADATA()
        guard WSAStartup(0x0202, &data) == 0 else { onState(.failed("WSAStartup")); return }
        let s = socket(AF_INET, SOCK_STREAM, Int32(IPPROTO_TCP.rawValue))
        guard s != INVALID_SOCKET else { onState(.failed("socket \(WSAGetLastError())")); return }
        var addr = sockaddr_in()
        addr.sin_family = ADDRESS_FAMILY(AF_INET)
        addr.sin_port = router.config.port.bigEndian
        addr.sin_addr.S_un.S_addr = UInt32(0x7F00_0001).bigEndian   // 127.0.0.1 only
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, Int32(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(s, 16) == 0 else {
            let e = WSAGetLastError(); closesocket(s); onState(.failed("bind/listen \(e)")); return
        }
        listenSocket = s
        running = true
        onState(.ready(router.config.port))
        Thread.detachNewThread { [self] in acceptLoop(s) }
    }

    public func stop() {
        lock.lock()
        let s = listenSocket
        let was = running
        listenSocket = INVALID_SOCKET; running = false
        lock.unlock()
        if s != INVALID_SOCKET { closesocket(s) }   // unblocks accept()
        if was { onState(.stopped) }
    }

    private func acceptLoop(_ s: SOCKET) {
        while true {
            var peer = sockaddr_in()
            var len = Int32(MemoryLayout<sockaddr_in>.size)
            let c = withUnsafeMutablePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(s, $0, &len) }
            }
            if c == INVALID_SOCKET { return }   // listener closed
            let loop = peer.sin_addr.S_un.S_addr == UInt32(0x7F00_0001).bigEndian
            lock.lock(); let ok = loop && limiter.acquire(); lock.unlock()
            guard ok else { closesocket(c); continue }
            Thread.detachNewThread { [self] in
                serve(c)
                closesocket(c)
                lock.lock(); limiter.release(); lock.unlock()
            }
        }
    }

    private func serve(_ c: SOCKET) {
        var ms = DWORD(Self.timeout * 1000)
        _ = setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &ms, Int32(MemoryLayout<DWORD>.size))
        var buf = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            switch HTTPParser.parse(buf, maxBody: router.config.maxBodyBytes) {
            case .invalid(let status): send(.error(status, "bad request"), on: c); return
            case .complete(let req, _):
                let router = self.router
                let box = ResponseBox()
                let sem = DispatchSemaphore(value: 0)
                let task = Task { box.value = await router.handle(req); sem.signal() }
                if sem.wait(timeout: .now() + Self.timeout) == .timedOut { task.cancel(); return }
                if let r = box.value { send(r, on: c) }
                return
            case .incomplete:
                let n = chunk.withUnsafeMutableBytes { recv(c, $0.baseAddress?.assumingMemoryBound(to: CChar.self), Int32($0.count), 0) }
                if n <= 0 { return }
                buf.append(contentsOf: chunk[0..<Int(n)])
            }
        }
    }

    private final class ResponseBox: @unchecked Sendable { var value: HTTPResponse? }

    private func send(_ r: HTTPResponse, on c: SOCKET) {
        let data = r.serialized()
        var off = 0
        data.withUnsafeBytes { raw in
            while off < raw.count {
                let n = WinSDK.send(c, raw.baseAddress!.assumingMemoryBound(to: CChar.self) + off, Int32(raw.count - off), 0)
                if n <= 0 { return }
                off += Int(n)
            }
        }
        shutdown(c, SD_SEND)
    }
}
#endif
