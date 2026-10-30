import Foundation

public struct HTTPRequest: Sendable, Equatable {
    public var method: String
    /// Path without the query string.
    public var path: String
    /// Header names lowercased.
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, headers: [String: String], body: Data) {
        self.method = method; self.path = path; self.headers = headers; self.body = body
    }
}

public struct HTTPResponse: Sendable, Equatable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data) { self.status = status; self.body = body }

    public static func json(_ status: Int, _ value: some Encodable) -> HTTPResponse {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        return HTTPResponse(status: status, body: (try? e.encode(value)) ?? Data("{}".utf8))
    }

    public static func error(_ status: Int, _ message: String, operationIndex: Int? = nil) -> HTTPResponse {
        json(status, ErrorBody(error: message, operationIndex: operationIndex))
    }

    struct ErrorBody: Encodable { var error: String; var operationIndex: Int? }

    static func reason(_ s: Int) -> String {
        switch s {
        case 200: "OK"; case 400: "Bad Request"; case 401: "Unauthorized"; case 403: "Forbidden"; case 404: "Not Found"
        case 405: "Method Not Allowed"; case 409: "Conflict"; case 411: "Length Required"; case 413: "Payload Too Large"
        case 422: "Unprocessable Content"; case 431: "Request Header Fields Too Large"; case 503: "Service Unavailable"
        default: "Error"
        }
    }

    /// HTTP/1.1 wire form; every response closes the connection.
    public func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        head += "Content-Type: application/json; charset=utf-8\r\nContent-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}

/// Minimal HTTP/1.1 request parser: Content-Length bodies only (no chunked), bounded header and body size.
public enum HTTPParser {
    public static let maxHeaderBytes = 16 * 1024

    public enum Result: Equatable {
        case incomplete
        /// The request and the number of bytes it used.
        case complete(HTTPRequest, Int)
        /// Respond with this status and close.
        case invalid(Int)
    }

    public static func parse(_ data: Data, maxBody: Int) -> Result {
        let sep = Data("\r\n\r\n".utf8)
        guard let end = data.range(of: sep) else {
            return data.count > maxHeaderBytes ? .invalid(431) : .incomplete
        }
        let headLength = end.lowerBound - data.startIndex
        guard headLength <= maxHeaderBytes else { return .invalid(431) }
        guard let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else { return .invalid(400) }
        var lines = head.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1."), parts[1].hasPrefix("/") else { return .invalid(400) }
        var headers: [String: String] = [:]
        for l in lines {
            guard let colon = l.firstIndex(of: ":") else { return .invalid(400) }
            let name = l[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = l[l.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return .invalid(400) }
            if headers[name] != nil, name == "host" || name == "content-length" { return .invalid(400) }   // smuggling
            headers[name] = value
        }
        if headers["transfer-encoding"] != nil { return .invalid(411) }
        var length = 0
        if let cl = headers["content-length"] {
            guard let n = Int(cl), n >= 0 else { return .invalid(400) }
            length = n
        }
        guard length <= maxBody else { return .invalid(413) }
        let bodyStart = end.upperBound
        guard data.endIndex - bodyStart >= length else { return .incomplete }
        let body = Data(data[bodyStart..<(bodyStart + length)])
        let target = String(parts[1])
        let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
        return .complete(HTTPRequest(method: String(parts[0]), path: path, headers: headers, body: body),
                         bodyStart + length - data.startIndex)
    }
}
