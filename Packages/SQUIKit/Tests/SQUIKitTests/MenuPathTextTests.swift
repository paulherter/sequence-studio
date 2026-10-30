import Foundation
import Testing
@testable import SQUIKit

/// Every "Menu > Item" pointer in a user-facing string must name an item that exists (AUDIT A1/D21).
@Suite struct MenuPathTextTests {
    private final class Node { var children: [String: Node] = [:] }

    private static func norm(_ s: String) -> String {
        s.replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "").trimmingCharacters(in: .whitespaces)
    }

    private static func add(_ items: [MenuSpec.Item], to node: Node) {
        for item in items {
            switch item {
            case .command(let c): node.children[norm(c.title)] = Node()
            case .separator: break
            case .submenu(let t, let sub):
                let n = node.children[norm(t)] ?? Node()
                node.children[norm(t)] = n
                add(sub, to: n)
            }
        }
    }

    /// Items the app builds itself (MenuBuilder and the AppController extensions), by path.
    /// shortcut: hand-kept list, add a path here when the app adds a menu item that a text points to.
    private static let appItems = [
        "File > Open Recent", "File > Close Project", "File > Autosave Versions", "File > Reconnect Media",
        "File > Media Management", "File > Import Checklist", "File > Import Premiere Project", "File > Import Project", "File > Collect Files",
        "Help > Send Feedback", "Help > Reveal Logs and Reports", "Help > Keyboard Shortcuts",
        "Window > History", "Window > Start Window", "Window > Tools", "Window > Style Kit",
        "Sequence > New Graphics Clip", "Sequence > New Shape", "Sequence > Change Format",
    ]

    private static func tree() -> Node {
        let root = Node()
        for m in EditorMenus.all {
            let n = root.children[m.title] ?? Node()
            root.children[m.title] = n
            add(m.items, to: n)
        }
        for p in EditorMenus.windowPanels {
            root.children["Window"]?.children[norm(EditorCommand.localizedPanelTitle(p))] = Node()
        }
        for path in appItems {
            var node = root
            for seg in path.components(separatedBy: " > ") {
                let n = node.children[seg] ?? Node()
                node.children[seg] = n
                node = n
            }
        }
        return root
    }

    /// True when the text after the menu title starts with a known path ("Audio Options > Accept All ... removes them").
    private static func resolves(_ rest: String, in node: Node) -> Bool {
        let segs = rest.components(separatedBy: " > ")
        var cur = node
        for (i, raw) in segs.enumerated() {
            let seg = norm(raw)
            guard let hit = cur.children.keys.filter({ seg.hasPrefix($0) }).max(by: { $0.count < $1.count }) else { return false }
            if i == segs.count - 1 || cur.children[hit]!.children.isEmpty { return true }
            cur = cur.children[hit]!
        }
        return true
    }

    @Test func detectsWrongPaths() {
        let root = Self.tree()
        #expect(!Self.resolves("Accept All Proposed Cuts removes them", in: root.children["Sequence"]!))
        #expect(Self.resolves("Audio Options > Accept All Proposed Cuts removes them", in: root.children["Clip"]!))
        #expect(!Self.resolves("Relink Media", in: root.children["File"]!))
        #expect(Self.resolves("Reconnect Media…", in: root.children["File"]!))
    }

    @Test func everyMenuPathInSourceTextExists() throws {
        let root = Self.tree()
        // .../Packages/SQUIKit/Tests/SQUIKitTests/<file> -> repo root
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        let fm = FileManager.default
        var dirs = [url.appendingPathComponent("App/Sources")]
        let pkgs = try fm.contentsOfDirectory(at: url.appendingPathComponent("Packages"), includingPropertiesForKeys: nil)
        dirs += pkgs.map { $0.appendingPathComponent("Sources") }
        let menuTitles = Set(root.children.keys.filter { !$0.isEmpty } + ["Help"])
        var bad: [String] = []
        var seen = 0
        for dir in dirs {
            guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { continue }
            for case let f as URL in en where f.pathExtension == "swift" {
                guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
                for (ln, line) in text.components(separatedBy: "\n").enumerated() {
                    if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                    var rest = Substring(line)
                    while let q = rest.firstIndex(of: "\"") {
                        let after = rest[rest.index(after: q)...]
                        guard let end = after.firstIndex(of: "\"") else { break }
                        let lit = String(after[..<end])
                        rest = after[after.index(after: end)...]
                        for title in menuTitles {
                            guard let r = lit.range(of: title + " > ") else { continue }
                            // whole word start ("Edit" inside "Audit" does not count)
                            if r.lowerBound != lit.startIndex, lit[lit.index(before: r.lowerBound)].isLetter { continue }
                            seen += 1
                            if !Self.resolves(String(lit[r.upperBound...]), in: root.children[title] ?? Node()) {
                                bad.append("\(f.lastPathComponent):\(ln + 1): \(lit)")
                            }
                        }
                    }
                }
            }
        }
        #expect(seen > 5)
        #expect(bad.isEmpty, "Menu paths that do not exist: \(bad)")
    }
}
