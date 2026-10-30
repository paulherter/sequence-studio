import Foundation
import Testing
import SQCore
@testable import SQText

@Suite(.serialized) struct StyleKitTextTests {
    static let red = EffectColor(red: 1, green: 0, blue: 0)
    static let blue = EffectColor(red: 0, green: 0, blue: 1)

    static func brand() -> StyleKit {
        var k = StyleKit()
        k.fonts["brand"] = "Avenir-Black"
        k.colors["text"] = .white
        k.colors["accent"] = red
        k.pill = StylePill(color: .token("accent"))
        k.caption = CaptionStyleSpec(baseStyle: "pill", font: .token("brand"), size: 70, textColor: .token("text"), usesPill: true)
        return k
    }

    static func caption(_ ref: String) -> CaptionItem {
        CaptionItem(lines: ["hi"], range: TimeRange(start: .zero, duration: Time(1, 1)), styleRef: ref)
    }

    // MARK: Caption style follows the tokens

    @Test func kitCaptionStyleResolvesTokens() {
        let lib = CaptionPresetLibrary.base.applying(Self.brand())
        let s = lib.style(for: StyleKit.captionStyleRef)
        #expect(s.fontName == "Avenir-Black")
        #expect(s.size == 70)
        #expect(s.color == .white)
        #expect(s.background?.color == RGBAColor(red: 1, green: 0, blue: 0))
        #expect(s.background?.cornerRadius == 10_000)
        #expect(lib.animation(for: StyleKit.captionAnimationRef) == .captionPop)
    }

    @Test func changingATokenChangesEveryKitCaption() {
        var kit = Self.brand()
        let items = [Self.caption(StyleKit.captionStyleRef), Self.caption(StyleKit.captionStyleRef)]
        let before = CaptionPresetLibrary.base.applying(kit)
        #expect(items.allSatisfy { before.style(for: $0.styleRef).background?.color == RGBAColor(red: 1, green: 0, blue: 0) })
        kit.colors["accent"] = Self.blue
        kit.fonts["brand"] = "Futura-Bold"
        let after = CaptionPresetLibrary.base.applying(kit)
        for item in items {
            #expect(after.style(for: item.styleRef).background?.color == RGBAColor(red: 0, green: 0, blue: 1))
            #expect(after.style(for: item.styleRef).fontName == "Futura-Bold")
        }
        // Captions in another style are not touched.
        #expect(after.style(for: "outline") == CaptionPresetLibrary.base.style(for: "outline"))
    }

    @Test func noKitAddsNothing() {
        let lib = CaptionPresetLibrary.base.applying(nil)
        #expect(!lib.hasStyle(StyleKit.captionStyleRef))
        #expect(lib.styles == CaptionPresetLibrary.base.styles)
    }

    @Test func registryFollowsTheProjectKit() {
        defer { CaptionLookRegistry.shared.setStyleKit(nil) }
        #expect(CaptionLookRegistry.shared.setStyleKit(Self.brand()))
        #expect(!CaptionLookRegistry.shared.setStyleKit(Self.brand()))     // unchanged
        #expect(CaptionPresetLibrary.builtIn.style(for: StyleKit.captionStyleRef).fontName == "Avenir-Black")
        var k = Self.brand()
        k.fonts["brand"] = "Futura-Bold"
        CaptionLookRegistry.shared.setStyleKit(k)
        #expect(CaptionPresetLibrary.builtIn.style(for: StyleKit.captionStyleRef).fontName == "Futura-Bold")
        CaptionLookRegistry.shared.setStyleKit(nil)
        #expect(!CaptionPresetLibrary.builtIn.hasStyle(StyleKit.captionStyleRef))
    }

    @Test func explicitKitLibrariesDoNotClash() {
        defer { CaptionLookRegistry.shared.setStyleKit(nil) }
        var other = Self.brand()
        other.fonts["brand"] = "Futura-Bold"
        CaptionLookRegistry.shared.setStyleKit(other)              // the "focused" project
        let a = CaptionLookRegistry.shared.library(for: Self.brand())
        let b = CaptionLookRegistry.shared.library(for: other)
        #expect(a.style(for: StyleKit.captionStyleRef).fontName == "Avenir-Black")
        #expect(b.style(for: StyleKit.captionStyleRef).fontName == "Futura-Bold")
        #expect(!CaptionLookRegistry.shared.library(for: nil).hasStyle(StyleKit.captionStyleRef))
        let v = CaptionLookRegistry.shared.version
        CaptionLookRegistry.shared.register(.default, id: "ver-test")
        defer { CaptionLookRegistry.shared.unregister(id: "ver-test") }
        #expect(CaptionLookRegistry.shared.version == v + 1)
        #expect(CaptionLookRegistry.shared.library(for: nil).hasStyle(CaptionLook.styleID(for: "ver-test")))
    }

    // MARK: Token-bound text styles

    @Test func textStyleTokensRoundTripAndOldStylesHaveNone() throws {
        var s = TextStyle(fontName: "Helvetica")
        s.tokens = TextStyleTokens(font: "brand", color: "accent")
        let back = try JSONDecoder().decode(TextStyle.self, from: JSONEncoder().encode(s))
        #expect(back == s)
        let plain = try JSONEncoder().encode(TextStyle())
        let obj = try #require(JSONSerialization.jsonObject(with: plain) as? [String: Any])
        #expect(obj["tokens"] == nil)
        #expect(try JSONDecoder().decode(TextStyle.self, from: plain).tokens == nil)
    }

    @Test func resolvedReplacesOnlyTokenBoundFields() {
        var s = TextStyle(fontName: "Helvetica", size: 40, color: .black, stroke: TextStroke(color: .black, width: 4),
                          background: TextBackground(color: .black, padding: BoxPadding(horizontal: 1, vertical: 1), cornerRadius: 2))
        s.tokens = TextStyleTokens(font: "brand", color: "accent", backgroundColor: "missing")
        let r = s.resolved(in: Self.brand())
        #expect(r.fontName == "Avenir-Black")
        #expect(r.color == RGBAColor(red: 1, green: 0, blue: 0))
        #expect(r.stroke == s.stroke)
        #expect(r.background == s.background)       // unknown token: the literal stays
        #expect(r.size == 40 && r.tokens == s.tokens)
        #expect(s.resolved(in: nil) == s)
    }

    @Test func textClipsFollowTheKit() throws {
        var style = TextStyle(fontName: "Helvetica")
        style.tokens = TextStyleTokens(font: "brand")
        let bound = try TextGenerator.makeRef(template: TextTemplate(name: "T", text: "Hi", style: style), animations: nil)
        let literal = try TextGenerator.makeRef(template: TextTemplate(name: "L", text: "Hi", style: TextStyle(fontName: "Menlo")), animations: nil)
        func clip(_ g: GeneratorRef) -> Clip {
            Clip(name: "t", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)), start: .zero, generator: g)
        }
        let tl = Timeline(name: "s", frameDuration: Time(1, 30), tracks: [Track(kind: .video, clips: [clip(bound), clip(literal)])])
        var p = Project(name: "P", timelines: [tl])
        p.styleKit = Self.brand()
        #expect(p.resolveTextTokens() == 1)
        func font(_ i: Int) throws -> String {
            try TextGenerator.decode(try #require(p.timelines[0].tracks[0].clips[i].generator)).0.style.fontName
        }
        #expect(try font(0) == "Avenir-Black")
        #expect(try font(1) == "Menlo")
        p.styleKit?.fonts["brand"] = "Futura-Bold"
        #expect(p.resolveTextTokens() == 1)
        #expect(try font(0) == "Futura-Bold")
        #expect(p.resolveTextTokens() == 0)          // already current
    }

    // MARK: Looks in a kit

    @Test func importedLookFollowsTheImportersBrand() throws {
        var theirs = Self.brand()
        var lookStyle = TextStyle(fontName: "Helvetica", size: 60, color: .white)
        lookStyle.tokens = TextStyleTokens(font: "brand", color: "accent")
        try theirs.addLook(CaptionLook(style: lookStyle, animation: .captionPop), id: "bold", name: "Bold")

        var mine = StyleKit()
        mine.fonts["brand"] = "Futura-Bold"
        mine.colors["accent"] = Self.blue
        let (merged, report) = mine.merging(theirs)
        #expect(report.addedLooks == ["bold"])
        let lib = CaptionPresetLibrary.base.applying(merged)
        let s = lib.style(for: CaptionLook.styleID(for: StyleKit.lookID("bold")))
        #expect(s.fontName == "Futura-Bold")
        #expect(s.color == RGBAColor(red: 0, green: 0, blue: 1))
        #expect(lib.animation(for: CaptionLook.animationID(for: StyleKit.lookID("bold"))) == .captionPop)
        #expect(merged.captionLooks().map(\.id) == ["bold"])
    }

    @Test func kitRoundTripsThroughSqstyleWithLooks() throws {
        var k = Self.brand()
        try k.addLook(.default, id: "default", name: "Default")
        let back = try StyleKitFile.decode(StyleKitFile.encode(k))
        #expect(back == k)
        #expect(back.captionLooks().first?.look == .default)
    }
}
