import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// A small element tree for the XML interchange readers (FCP7 XML, FCPXML).
struct IXNode {
    var name: String
    var attributes: [String: String] = [:]
    var text = ""
    var children: [IXNode] = []

    func child(_ n: String) -> IXNode? { children.first { $0.name == n } }
    func children(_ n: String) -> [IXNode] { children.filter { $0.name == n } }
    func text(_ n: String) -> String? { child(n)?.text }
    func int(_ n: String) -> Int64? { text(n).flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) } }
    func descendants(_ n: String) -> [IXNode] {
        children.flatMap { ($0.name == n ? [$0] : []) + $0.descendants(n) }
    }

    static func parse(_ data: Data) throws -> IXNode {
        let b = Builder()
        let p = XMLParser(data: data)
        p.delegate = b
        p.shouldResolveExternalEntities = false
        guard p.parse(), let root = b.root else {
            throw InterchangeError.malformed(p.parserError.map { $0.localizedDescription } ?? "no root element")
        }
        return root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var stack: [IXNode] = []
        var root: IXNode?
        func parser(_ parser: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            stack.append(IXNode(name: e, attributes: attributes))
        }
        func parser(_ parser: XMLParser, foundCharacters s: String) {
            if !stack.isEmpty { stack[stack.count - 1].text += s }
        }
        func parser(_ parser: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
            guard var n = stack.popLast() else { return }
            n.text = n.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if stack.isEmpty { root = n } else { stack[stack.count - 1].children.append(n) }
        }
    }
}

enum InterchangePath {
    /// A POSIX or Windows path from a `file://` URL string (percent-decoded; `localhost` host dropped; `/C:/x` -> `C:\x`).
    static func path(fromURL s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.lowercased().hasPrefix("file:") else { return t }
        t = String(t.dropFirst(5))
        if t.hasPrefix("//") && !t.hasPrefix("///") {
            t = String(t.dropFirst(2))
            if let i = t.firstIndex(of: "/") { t = String(t[i...]) }
        } else if t.hasPrefix("//") {
            t = String(t.dropFirst(2))
        }
        t = t.removingPercentEncoding ?? t
        let chars = Array(t)
        if chars.count > 2, chars[0] == "/", chars[2] == ":" { return String(t.dropFirst()).replacingOccurrences(of: "/", with: "\\") }
        return t
    }
}
