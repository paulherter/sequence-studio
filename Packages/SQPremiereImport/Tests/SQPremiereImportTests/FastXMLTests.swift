import Testing
import Foundation
@testable import SQPremiereImport

/// The byte-level reader must build exactly the tree the `XMLParser` builder built.
@Suite struct FastXMLTests {
    static func same(_ a: PRNode, _ b: PRNode, path: String = "") -> String? {
        let here = path + "/" + a.name
        if a.name != b.name { return "\(here): name \(a.name) vs \(b.name)" }
        if a.attributes != b.attributes { return "\(here): attributes \(a.attributes) vs \(b.attributes)" }
        if a.text != b.text { return "\(here): text ref \(b.text.debugDescription) fast \(a.text.debugDescription)" }
        if a.children.count != b.children.count { return "\(here): \(a.children.count) vs \(b.children.count) children" }
        for (x, y) in zip(a.children, b.children) { if let d = same(x, y, path: here) { return d } }
        return nil
    }

    static func compare(_ xml: String) throws {
        let data = Data(xml.utf8)
        #expect(PRFastXML.parse(data) != nil, "fast reader fell back")
        let fast = try PRObjectTable(xml: data)
        #if os(Windows)
        return   // swift-corelibs XMLParser (libxml2) reports some content differently from Apple's (comment text); the reference is Apple's
        #endif
        let ref = try PRObjectTable(xml: data, foundation: true)
        #expect(same(fast.root, ref.root) == nil, "\(same(fast.root, ref.root) ?? "")")
        #expect(fast.binaries == ref.binaries)
    }

    @Test func matchesXMLParserOnTrickyContent() throws {
        try Self.compare("""
        <?xml version="1.0" encoding="UTF-8" ?>\r
        <!-- header comment -->
        <PremiereData Version="3">
          <A ObjectID="1" Tab="a\tb" NL="x
        y" Ent="&lt;&amp;&gt;&quot;&apos;&#65;&#x42;&#10;"><Name>  first  </Name><Ref ObjectRef="2"/></A>
          <B ObjectID='2'>text &amp; more<!-- c -->tail<?pi x?><![CDATA[dropped]]>  <C/> end </B>
          <D>\u{00A0}nbsp\u{00A0}</D><E> \u{2028}line sep</E><F>Größe ✓ 日本</F>
          <G BinaryHash="h1">QUJD</G><G BinaryHash="h1"></G><G BinaryHash="h2">  </G>
          <H>line1\r\nline2\rline3</H><I>{"a":"b","c":[1,2]}</I><J a = "1"  b="2" /><K></K>
        </PremiereData>
        """)
    }

    @Test func malformedInputThrowsLikeBefore() {
        for bad in ["<PremiereData><A></B></PremiereData>", "<PremiereData>", "<PremiereData a=1/>",
                    "<PremiereData>&bogus;</PremiereData>", "<A/><B/>", "", "text<PremiereData/>"] {
            #expect(PRFastXML.parse(Data(bad.utf8)) == nil, "\(bad)")
            #expect(throws: (any Error).self) { try PRObjectTable(xml: Data(bad.utf8)) }
        }
        #expect(throws: PRImportError.notPremiereProject) { try PRObjectTable(xml: Data("<Other/>".utf8)) }
    }

    @Test func nonUTF8DeclarationFallsBack() throws {
        let xml = "<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?><PremiereData><N>x</N></PremiereData>"
        #expect(PRFastXML.parse(Data(xml.utf8)) == nil)
        #expect(try PRObjectTable(xml: Data(xml.utf8)).root.text("N") == "x")
    }

    /// Every real project under `SQ_PRPROJ_DIR` (e.g. ~/Documents/Videos): same tree as XMLParser.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SQ_PRPROJ_DIR"] != nil)) func matchesOnRealProjects() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SQ_PRPROJ_DIR"]!)
        let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "prproj" && !$0.path.contains("Auto-Save") } ?? []
        #expect(!files.isEmpty)
        for f in files {
            let xml = try PRGzip.inflate(Data(contentsOf: f))
            #expect(PRFastXML.parse(xml) != nil, "\(f.lastPathComponent) fell back")
            let fast = try PRObjectTable(xml: xml), ref = try PRObjectTable(xml: xml, foundation: true)
            let d = Self.same(fast.root, ref.root)
            #expect(d == nil, "\(f.lastPathComponent): \(d ?? "")")
            #expect(fast.binaries == ref.binaries, "\(f.lastPathComponent) binaries")
        }
    }
}
