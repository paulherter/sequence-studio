import Foundation
import SQCore
import SQText

/// One edit made in the Style tab of the Captions panel (FB-M point 6, W8.3).
public enum CaptionStyleField: Sendable, Hashable {
    /// Built-in caption style the captions start from ("default", "outline", "pill", …).
    case look(String)
    /// Built-in caption animation id.
    case animation(String)
    case font(String)
    case size(Double)
    case textColor(RGBAColor)
    /// Outline color; nil turns the outline off.
    case outline(RGBAColor?)
    /// Pill (box behind the words) color; nil turns the pill off.
    case pill(RGBAColor?)
    /// Pill size in em (horizontal padding / font size; the vertical padding follows at the pill's aspect). Turns the pill on.
    case pillSize(Double)
    /// Pill corner radius in points; nil = fully round ends. Turns the pill on.
    case pillCorners(Double?)
    case allCaps(Bool)
    // The rest of the Text panel's sections (shared TextInspectorModel).
    case weight(FontWeight)
    case italic(Bool)
    case alignment(TextAlignment)
    case tracking(Double)
    case lineSpacing(Double)
    /// Outline width in points; the outline must be on.
    case strokeWidth(Double)
    case strokePosition(StrokePosition)
    /// Pill padding in em (horizontal, vertical). Turns the pill on.
    case pillPadding(horizontalEm: Double, verticalEm: Double)
    /// Shadow; nil turns it off.
    case shadow(TextShadow?)
}

/// What the Style tab edits: every caption (the project's kit caption style) or the selected captions (a look of their own).
public enum CaptionStyleScope: String, Sendable, Hashable { case all, selected }

/// What the Style tab shows for a scope.
public struct CaptionStyleState: Sendable, Hashable {
    /// The style as drawn (tokens resolved).
    public var style: TextStyle
    /// The built-in look it starts from; nil for a saved or own look.
    public var baseID: String?
    /// The caption animation id; nil when it is not a built-in animation.
    public var animationID: String?
    public var hasOutline: Bool { style.stroke.map { $0.color.alpha > 0 && $0.width > 0 } ?? false }
    public var hasPill: Bool { style.background.map { $0.color.alpha > 0 } ?? false }
    /// Pill size in em (what the Size slider shows).
    public var pillSize: Double = CaptionPill.horizontalEm
    /// Pill corner radius in points; nil = fully round.
    public var pillCorners: Double?
}

/// The pure rules behind the Style tab.
public enum CaptionStyleEdit {
    /// Style ids of the built-in looks (no saved looks, no kit styles).
    public static var builtInStyleIDs: [String] {
        CaptionPresetLibrary.builtIn.styleIDs.filter { !$0.hasPrefix("look-") && $0 != StyleKit.captionStyleRef }
    }

    public static var builtInAnimationIDs: [String] {
        CaptionPresetLibrary.builtIn.animationIDs.filter { !$0.hasPrefix("look-") && $0 != StyleKit.captionAnimationRef }
    }

    public static func effect(_ c: RGBAColor) -> EffectColor { EffectColor(red: c.red, green: c.green, blue: c.blue, alpha: c.alpha) }

    /// Vertical / horizontal padding of the pill: one Size control keeps the built-in proportion.
    static let pillAspect = CaptionPill.verticalEm / CaptionPill.horizontalEm
    /// Upper end of the Size slider (em).
    static let maxPillSize = 1.2
    /// A corner radius at least this large draws fully round ends (the renderer clamps to half the pill height).
    static let roundCorners = 10_000.0

    /// The pill (size, corners) as the Style tab shows it for a drawn style.
    static func pillMetrics(of style: TextStyle) -> (size: Double, corners: Double?) {
        guard let bg = style.background, style.size > 0 else { return (CaptionPill.horizontalEm, nil) }
        return (bg.padding.horizontal / style.size, bg.cornerRadius >= roundCorners ? nil : bg.cornerRadius)
    }

    /// Turns the kit pill on without changing the look: the pill takes the look's own box color when it has one.
    private static func ensurePill(_ spec: inout CaptionStyleSpec, _ k: inout StyleKit, base: TextStyle) {
        spec.usesPill = true
        spec.hidesBackground = nil
        if k.pill == nil {
            k.pill = StylePill(color: .literal(effect(base.background?.color ?? CaptionPill.color)),
                               horizontalEm: CaptionPill.horizontalEm, verticalEm: CaptionPill.verticalEm)
        }
    }

    /// The style as the Style tab's inspector shows it: invisible layers (clear outline, clear box or shadow) count as off,
    /// kit token bindings and the second paragraph are not part of a caption look.
    public static func displayStyle(_ style: TextStyle) -> TextStyle {
        var s = style
        if let st = s.stroke, st.color.alpha <= 0 || st.width <= 0 { s.stroke = nil }
        if let bg = s.background, bg.color.alpha <= 0 { s.background = nil }
        if let sh = s.shadow, sh.color.alpha <= 0 { s.shadow = nil }
        s.secondLine = nil; s.tokens = nil
        return s
    }

    /// The caption fields that turn `old` into `new` (both as `displayStyle` shows them): what an edit in the shared Text
    /// inspector means for a caption look. Layers that come on carry all their values, so the result does not depend on
    /// what the look had hidden. The order is the order to apply them (a layer on before its details).
    public static func fields(from old: TextStyle, to new: TextStyle) -> [CaptionStyleField] {
        var f: [CaptionStyleField] = []
        if new.fontName != old.fontName { f.append(.font(new.fontName)) }
        if new.size != old.size { f.append(.size(new.size)) }
        if new.color != old.color { f.append(.textColor(new.color)) }
        if new.weight != old.weight { f.append(.weight(new.weight)) }
        if new.italic != old.italic { f.append(.italic(new.italic)) }
        if new.allCaps != old.allCaps { f.append(.allCaps(new.allCaps)) }
        if new.alignment != old.alignment { f.append(.alignment(new.alignment)) }
        if new.tracking != old.tracking { f.append(.tracking(new.tracking)) }
        if new.lineSpacing != old.lineSpacing { f.append(.lineSpacing(new.lineSpacing)) }
        switch (old.stroke, new.stroke) {
        case (_, nil): if old.stroke != nil { f.append(.outline(nil)) }
        case (let o?, let n?):
            if n.color != o.color { f.append(.outline(n.color)) }
            if n.width != o.width { f.append(.strokeWidth(n.width)) }
            if n.position != o.position { f.append(.strokePosition(n.position)) }
        case (nil, let n?):
            f += [.outline(n.color), .strokeWidth(n.width), .strokePosition(n.position)]
        }
        switch (old.background, new.background) {
        case (_, nil): if old.background != nil { f.append(.pill(nil)) }
        case (let o?, let n?):
            if n.color != o.color { f.append(.pill(n.color)) }
            if n.padding != o.padding { f.append(.pillPadding(horizontalEm: n.padding.horizontal / new.size, verticalEm: n.padding.vertical / new.size)) }
            if n.cornerRadius != o.cornerRadius { f.append(.pillCorners(n.cornerRadius >= roundCorners ? nil : n.cornerRadius)) }
        case (nil, let n?):
            f += [.pill(n.color), .pillPadding(horizontalEm: n.padding.horizontal / new.size, verticalEm: n.padding.vertical / new.size),
                  .pillCorners(n.cornerRadius >= roundCorners ? nil : n.cornerRadius)]
        }
        if new.shadow != old.shadow { f.append(.shadow(new.shadow)) }
        return f
    }

    public static func apply(_ fields: [CaptionStyleField], to kit: StyleKit) -> StyleKit {
        fields.reduce(kit) { apply($1, to: $0) }
    }

    public static func apply(_ fields: [CaptionStyleField], to style: TextStyle, library: CaptionPresetLibrary) -> TextStyle {
        fields.reduce(style) { apply($1, to: $0, library: library) }
    }

    private static func tweak(_ spec: inout CaptionStyleSpec, _ body: (inout CaptionStyleTweaks) -> Void) {
        var t = spec.tweaks ?? CaptionStyleTweaks()
        body(&t)
        spec.tweaks = t.isEmpty ? nil : t
    }

    /// All captions: edits the kit caption style (`kit.caption`, or `start` when the kit has none). A field bound to a
    /// token edits that token in place, so the brand (and every text bound to it) follows; an unbound field gets a literal.
    public static func apply(_ f: CaptionStyleField, to kit: StyleKit,
                      start: CaptionStyleSpec = CaptionStyleSpec(baseStyle: "default")) -> StyleKit {
        var k = kit
        var spec = k.caption ?? start
        let base = CaptionPresetLibrary.builtIn.style(for: spec.baseStyle)
        switch f {
        case .look(let id):
            // A new look starts clean from that look; the font binding (the brand) and the animation stay.
            // The pill look draws the kit pill, so its Size and Corners edit what is on screen (FB-Y).
            spec = CaptionStyleSpec(baseStyle: id, animation: spec.animation, font: spec.font, usesPill: id == CaptionPill.styleID)
            if id == CaptionPill.styleID && k.pill == nil {
                k.pill = StylePill(color: .literal(effect(CaptionPill.color)),
                                   horizontalEm: CaptionPill.horizontalEm, verticalEm: CaptionPill.verticalEm)
            }
        case .animation(let id):
            spec.animation = id
        case .font(let name):
            if let n = spec.font?.tokenName { k.fonts[n] = name } else { spec.font = .literal(name) }
        case .size(let v):
            spec.size = v.isFinite ? min(CaptionStyleSpec.maxSize, max(1, v)) : nil
        case .textColor(let c):
            if let n = spec.textColor?.tokenName { k.colors[n] = effect(c) } else { spec.textColor = .literal(effect(c)) }
        case .outline(let c?):
            if let n = spec.strokeColor?.tokenName { k.colors[n] = effect(c) } else { spec.strokeColor = .literal(effect(c)) }
        case .outline(nil):
            // The spec cannot remove the base look's outline: a clear one draws nothing.
            spec.strokeColor = base.stroke == nil ? nil : .literal(EffectColor(red: 0, green: 0, blue: 0, alpha: 0))
        case .pill(let c?):
            spec.usesPill = true
            spec.hidesBackground = nil
            if let p = k.pill {
                if let n = p.color.tokenName { k.colors[n] = effect(c) } else { k.pill?.color = .literal(effect(c)) }
            } else {
                k.pill = StylePill(color: .literal(effect(c)), horizontalEm: CaptionPill.horizontalEm, verticalEm: CaptionPill.verticalEm)
            }
        case .pill(nil):
            spec.usesPill = false
            // A look with a box of its own (pill, bold box, YouTube) keeps its type and drops only the box (FB-Y).
            spec.hidesBackground = base.background != nil ? true : nil
        case .pillSize(let v):
            ensurePill(&spec, &k, base: base)
            let em = v.isFinite ? min(maxPillSize, max(0, v)) : CaptionPill.horizontalEm
            k.pill?.horizontalEm = em
            k.pill?.verticalEm = em * pillAspect
        case .pillCorners(let r):
            ensurePill(&spec, &k, base: base)
            k.pill?.cornerRadius = r.map { $0.isFinite ? min(StylePill.maxCornerRadius, max(0, $0)) : 0 }
        case .allCaps(let b):
            spec.allCaps = b
        case .weight(let w): tweak(&spec) { $0.weight = w.rawValue }
        case .italic(let b): tweak(&spec) { $0.italic = b }
        case .alignment(let a): tweak(&spec) { $0.alignment = a.rawValue }
        case .tracking(let v): tweak(&spec) { $0.tracking = v.isFinite ? v : 0 }
        case .lineSpacing(let v): tweak(&spec) { $0.lineSpacing = v.isFinite ? v : 0 }
        case .strokeWidth(let v): tweak(&spec) { $0.strokeWidth = v.isFinite ? max(0, v) : 0 }
        case .strokePosition(let p): tweak(&spec) { $0.strokePosition = p.rawValue }
        case .pillPadding(let h, let v):
            ensurePill(&spec, &k, base: base)
            k.pill?.horizontalEm = h.isFinite ? min(maxPillSize, max(0, h)) : CaptionPill.horizontalEm
            k.pill?.verticalEm = v.isFinite ? min(maxPillSize, max(0, v)) : CaptionPill.verticalEm
        case .shadow(let sh?):
            tweak(&spec) {
                $0.shadow = .init(color: effect(sh.color), offsetX: sh.offsetX, offsetY: sh.offsetY, blur: sh.blur, restingAngle: sh.restingAngle)
                $0.hidesShadow = nil
            }
        case .shadow(nil):
            tweak(&spec) { $0.shadow = nil; $0.hidesShadow = base.shadow != nil ? true : nil }
        }
        k.caption = spec
        return k
    }

    /// Selected captions: edits the style they are drawn with. A manual choice ends that field's token binding.
    public static func apply(_ f: CaptionStyleField, to style: TextStyle, library: CaptionPresetLibrary) -> TextStyle {
        var s = style
        switch f {
        case .look(let id):
            s = library.style(for: id)
        case .animation:
            break
        case .font(let name):
            s.fontName = name; s.unbind(\.font)
        case .size(let v):
            guard v.isFinite else { break }
            s.size = min(CaptionStyleSpec.maxSize, max(1, v))
        case .textColor(let c):
            s.color = c; s.unbind(\.color)
        case .outline(let c?):
            let width = s.stroke.map(\.width).flatMap { $0 > 0 ? $0 : nil } ?? max(2, (s.size * 0.1).rounded())
            s.stroke = TextStroke(color: c, width: width, position: s.stroke?.position ?? .outside)
            s.unbind(\.strokeColor)
        case .outline(nil):
            s.stroke = nil; s.unbind(\.strokeColor)
        case .pill(let c?):
            s.background = TextBackground(color: c,
                                          padding: s.background?.padding ?? BoxPadding(horizontal: (s.size * CaptionPill.horizontalEm).rounded(),
                                                                                       vertical: (s.size * CaptionPill.verticalEm).rounded()),
                                          cornerRadius: s.background?.cornerRadius ?? 10_000)
            s.unbind(\.backgroundColor)
        case .pill(nil):
            s.background = nil; s.unbind(\.backgroundColor)
        case .pillSize(let v):
            var bg = s.background ?? CaptionPill.background(for: s)
            let em = v.isFinite ? min(maxPillSize, max(0, v)) : CaptionPill.horizontalEm
            bg.padding = BoxPadding(horizontal: (s.size * em).rounded(), vertical: (s.size * em * pillAspect).rounded())
            s.background = bg
        case .pillCorners(let r):
            var bg = s.background ?? CaptionPill.background(for: s)
            bg.cornerRadius = r.map { $0.isFinite ? max(0, $0) : 0 } ?? roundCorners
            s.background = bg
        case .allCaps(let b):
            s.allCaps = b
        case .weight(let w): s.weight = w
        case .italic(let b): s.italic = b
        case .alignment(let a): s.alignment = a
        case .tracking(let v): s.tracking = v.isFinite ? v : 0
        case .lineSpacing(let v): s.lineSpacing = v.isFinite ? v : 0
        case .strokeWidth(let v): s.stroke?.width = v.isFinite ? max(0, v) : 0
        case .strokePosition(let p): s.stroke?.position = p
        case .pillPadding(let h, let v):
            var bg = s.background ?? CaptionPill.background(for: s)
            func pad(_ em: Double, _ fallback: Double) -> Double { ((em.isFinite ? min(maxPillSize, max(0, em)) : fallback) * s.size).rounded() }
            bg.padding = BoxPadding(horizontal: pad(h, CaptionPill.horizontalEm), vertical: pad(v, CaptionPill.verticalEm))
            s.background = bg
        case .shadow(let sh): s.shadow = sh
        }
        return s
    }

    /// True when the track is drawn in a style the kit caption spec cannot hold (an applied Look, a saved or own look):
    /// an "all captions" edit then changes that style in place and keeps every other field, instead of starting over
    /// from the default base.
    static func showsOwnLook(_ track: CaptionTrack) -> Bool {
        let ref = track.styleRef
        return !ref.isEmpty && ref != StyleKit.captionStyleRef && !builtInStyleIDs.contains(ref)
    }

    /// Kit looks the Style tab made for selected captions carry this id prefix; one no caption uses any more is dropped.
    static let ownLookPrefix = "own-"

    static func pruneOwnLooks(_ p: inout Project) { pruneKitLooks(&p, prefix: ownLookPrefix) }

    /// Every style and animation ref a caption track or caption of the project carries. A kit look is in use while
    /// either of its two refs is in here (a caption can take only the animation of a look).
    static func captionRefs(in p: Project) -> Set<String> {
        var refs: Set<String> = []
        for track in p.timelines.lazy.flatMap(\.captionTracks) {
            refs.insert(track.styleRef); refs.insert(track.animationRef)
            for item in track.items { refs.insert(item.styleRef); refs.insert(item.animationRef) }
        }
        return refs
    }

    static func isKitLookUsed(_ id: String, refs: Set<String>) -> Bool {
        let token = StyleKit.lookID(id)
        return refs.contains(CaptionLook.styleID(for: token)) || refs.contains(CaptionLook.animationID(for: token))
    }

    /// Drops the kit looks with this id prefix that no caption carries any more (neither style nor animation).
    static func pruneKitLooks(_ p: inout Project, prefix: String) {
        guard var kit = p.styleKit else { return }
        let refs = captionRefs(in: p)
        for id in kit.looks.keys where id.hasPrefix(prefix) && !isKitLookUsed(id, refs: refs) { kit.looks[id] = nil }
        if kit != p.styleKit { p.styleKit = kit }
    }
}

extension EditorSession {
    /// What the Style tab shows: the first caption track (all) or the first selected caption (selected).
    public func captionStyleState(scope: CaptionStyleScope) -> CaptionStyleState? {
        guard activeTimeline != nil, let track = currentCaptionTrack else { return nil }
        let lib = CaptionLookRegistry.shared.library(for: project)
        let builtIn = Set(CaptionStyleEdit.builtInStyleIDs), anims = Set(CaptionStyleEdit.builtInAnimationIDs)
        let styleRef: String, animationRef: String
        switch scope {
        case .all:
            styleRef = track.styleRef.isEmpty ? (track.items.first?.styleRef ?? "") : track.styleRef
            animationRef = track.animationRef.isEmpty ? (track.items.first?.animationRef ?? "") : track.animationRef
        case .selected:
            guard let c = captionItems.first(where: { captionSelection.contains($0.id) }) else { return nil }
            (styleRef, animationRef) = (c.styleRef, c.animationRef)
        }
        let spec = project.styleKit?.caption
        let base = styleRef == StyleKit.captionStyleRef ? spec?.baseStyle : (builtIn.contains(styleRef) ? styleRef : nil)
        let anim = animationRef == StyleKit.captionAnimationRef ? (spec?.animation ?? CaptionLook.popAnimationID)
                                                                : (anims.contains(animationRef) ? animationRef : nil)
        var state = CaptionStyleState(style: lib.style(for: styleRef.isEmpty ? nil : styleRef), baseID: base, animationID: anim)
        if styleRef == StyleKit.captionStyleRef, spec?.usesPill == true, let p = project.styleKit?.pill {
            (state.pillSize, state.pillCorners) = (p.horizontalEm, p.cornerRadius)   // exact, not from rounded padding
        } else {
            (state.pillSize, state.pillCorners) = CaptionStyleEdit.pillMetrics(of: state.style)
        }
        return state
    }

    /// One Style tab edit as one undo step (`continuesGesture`: merges with the previous edit, e.g. a color well drag).
    /// All captions: the kit caption style changes and every caption of the sequence uses it (own styles are released).
    /// Selected: those captions get a kit look of their own ("Own Style n"), updated in place while only they use it.
    @discardableResult
    public func editCaptionStyle(_ f: CaptionStyleField, scope: CaptionStyleScope, continuesGesture: Bool = false) -> Bool {
        editCaptionStyle([f], scope: scope, continuesGesture: continuesGesture)
    }

    /// Several fields as one undo step (one edit of the shared Text inspector can change a layer and its details).
    @discardableResult
    public func editCaptionStyle(_ fields: [CaptionStyleField], scope: CaptionStyleScope, continuesGesture: Bool = false) -> Bool {
        guard !fields.isEmpty else { return true }
        if !continuesGesture { gestureCounter += 1 }
        let key = "captionStyle:\(scope.rawValue):\(gestureCounter)"
        guard let tl = activeTimeline, let tlID = activeTimelineID, let track = currentCaptionTrack else { return false }
        switch scope {
        case .all where tl.captionTracks.first?.id != track.id || CaptionStyleEdit.showsOwnLook(track):
            return editTrackLook(fields, track: track, timeline: tlID, key: key)
        case .all:
            var kit = project.styleKit ?? StyleKit()
            if track.styleRef != StyleKit.captionStyleRef || kit.caption == nil {
                // Start from what is on screen, not from a kit style the captions do not use.
                let builtIn = Set(CaptionStyleEdit.builtInStyleIDs), anims = Set(CaptionStyleEdit.builtInAnimationIDs)
                // A custom animation (from a text clip or a saved look) stays: the kit spec carries its registry id.
                let ref = track.animationRef
                let custom = ref != StyleKit.captionAnimationRef && !anims.contains(ref)
                    && CaptionLookRegistry.shared.library(for: project).hasAnimation(ref)
                kit.caption = CaptionStyleSpec(baseStyle: builtIn.contains(track.styleRef) ? track.styleRef : "default",
                                               animation: anims.contains(ref) || custom ? ref : nil)
            }
            kit = CaptionStyleEdit.apply(fields, to: kit)
            // The first track carries the project's kit style; other tracks that still use it follow, tracks with a look of
            // their own (see `editTrackLook`) keep it.
            let trackIDs = tl.captionTracks.filter { $0.id == track.id || $0.styleRef == StyleKit.captionStyleRef || $0.styleRef.isEmpty }.map(\.id)
            let all = Set(tl.captionTracks.filter { trackIDs.contains($0.id) }.flatMap(\.items).map(\.id))
            return commitCaptionStyle(key) { p in
                p.styleKit = kit
                try p.edit(tlID) { t in
                    for id in trackIDs {
                        try t.setCaptionStyle(styleRef: StyleKit.captionStyleRef, animationRef: StyleKit.captionAnimationRef, track: id,
                                              keepsLook: true)
                    }
                    try t.setCaptionItemStyle(all, styleRef: nil)
                }
                CaptionStyleEdit.pruneOwnLooks(&p)
            }
        case .selected:
            let ids = captionSelection
            let items = captionItems.filter { ids.contains($0.id) }
            guard let first = items.first else { return false }
            // The animation is the caption's own `animationRef`, drawn by the same path as the global one.
            var ownAnimation: String?
            for case .animation(let a) in fields { ownAnimation = a }
            if let ownAnimation, fields.allSatisfy({ if case .animation = $0 { true } else { false } }) {
                return commitCaptionStyle(key) { p in
                    try p.edit(tlID) { try $0.setCaptionItemAnimation(ids, animationRef: ownAnimation) }
                }
            }
            let lib = CaptionLookRegistry.shared.library(for: project)
            let look = CaptionLook(style: CaptionStyleEdit.apply(fields, to: lib.style(for: first.styleRef), library: lib),
                                   animation: lib.animation(for: first.animationRef))
            var kit = project.styleKit ?? StyleKit()
            let lookPrefix = CaptionLook.styleID(for: StyleKit.lookID(""))
            var lookID: String?
            // The selection already has a look of its own that nothing else uses: update it in place.
            if Set(items.map(\.styleRef)).count == 1, first.styleRef.hasPrefix(lookPrefix + CaptionStyleEdit.ownLookPrefix) {
                let users = Set(project.timelines.flatMap { $0.captionTracks.flatMap(\.items) }.filter { $0.styleRef == first.styleRef }.map(\.id))
                if users == ids { lookID = String(first.styleRef.dropFirst(lookPrefix.count)) }
            }
            let id: String, name: String
            if let lookID, let existing = kit.looks[lookID] { (id, name) = (lookID, existing.name) } else {
                var n = 1
                while kit.looks["\(CaptionStyleEdit.ownLookPrefix)\(n)"] != nil { n += 1 }
                (id, name) = ("\(CaptionStyleEdit.ownLookPrefix)\(n)", "Own Style \(n)")
            }
            guard (try? kit.addLook(look, id: id, name: name)) != nil else { return false }
            let ref = CaptionLook.styleID(for: StyleKit.lookID(id))
            return commitCaptionStyle(key) { p in
                p.styleKit = kit
                try p.edit(tlID) {
                    try $0.setCaptionItemStyle(ids, styleRef: ref)
                    if let ownAnimation { try $0.setCaptionItemAnimation(ids, animationRef: ownAnimation) }
                }
                CaptionStyleEdit.pruneOwnLooks(&p)
            }
        }
    }

    /// All Captions on a track other than the first: the track gets a kit look of its own (`own-trk-<id>`), updated in
    /// place; every caption of that track follows it (own styles are released), other tracks are untouched.
    private func editTrackLook(_ fields: [CaptionStyleField], track: CaptionTrack, timeline tlID: Timeline.ID, key: String) -> Bool {
        let lib = CaptionLookRegistry.shared.library(for: project)
        var ownAnimation: String?
        for case .animation(let a) in fields { ownAnimation = a }
        let styleFields = fields.filter { if case .animation = $0 { false } else { true } }
        let animationRef = ownAnimation ?? track.animationRef
        var kit = project.styleKit ?? StyleKit()
        var styleRef = track.styleRef.isEmpty ? (track.items.first?.styleRef ?? "") : track.styleRef
        if !styleFields.isEmpty {
            let look = CaptionLook(style: CaptionStyleEdit.apply(styleFields, to: lib.style(for: styleRef.isEmpty ? nil : styleRef), library: lib),
                                   animation: lib.animation(for: animationRef.isEmpty ? nil : animationRef))
            let id = Self.trackLookID(track.id)
            guard (try? kit.addLook(look, id: id, name: "\(track.name) Look")) != nil else { return false }
            styleRef = CaptionLook.styleID(for: StyleKit.lookID(id))
        }
        let ids = Set(track.items.map(\.id))
        let ref = styleRef
        return commitCaptionStyle(key) { p in
            p.styleKit = kit
            try p.edit(tlID) { t in
                try t.setCaptionStyle(styleRef: ref, animationRef: animationRef.isEmpty ? nil : animationRef, track: track.id,
                                      keepsLook: true)
                try t.setCaptionItemStyle(ids, styleRef: nil)
            }
            CaptionStyleEdit.pruneOwnLooks(&p)
        }
    }

    static func trackLookID(_ track: CaptionTrack.ID) -> String { "\(CaptionStyleEdit.ownLookPrefix)trk-\(track.uuidString.prefix(8))" }

    /// Edits the project's kit (brand tokens, pill, motion) as one undo step; `continuesGesture` merges with the previous edit.
    public func editStyleKit(name: String = "Change Style Kit", continuesGesture: Bool = false, _ body: (inout StyleKit) -> Void) {
        if !continuesGesture { gestureCounter += 1 }
        var kit = project.styleKit ?? StyleKit()
        body(&kit)
        guard kit != project.styleKit else { return }
        perform(name, coalescing: "styleKit:\(gestureCounter)") { $0.styleKit = kit }
    }

    /// Where captions sit on the picture (all captions of the project, kept in its style kit).
    public var captionPosition: CaptionPosition { project.styleKit?.captionPosition ?? .default }

    /// Moves every caption (top/middle/bottom, left/center/right, free offset) as one undo step; `continuesGesture`
    /// merges with the previous change (an offset stepper or typing drag). The default position is stored as nil.
    public func setCaptionPosition(_ p: CaptionPosition, continuesGesture: Bool = false) {
        editStyleKit(name: "Caption Position", continuesGesture: continuesGesture) { $0.captionPosition = p == .default ? nil : p }
    }

    private func commitCaptionStyle(_ key: String, _ body: (inout Project) throws -> Void) -> Bool {
        let before = history.current
        do { try perform("Caption Style", coalescing: key, body) } catch {
            setError(Self.message(for: error)); return false
        }
        return history.current != before
    }
}
