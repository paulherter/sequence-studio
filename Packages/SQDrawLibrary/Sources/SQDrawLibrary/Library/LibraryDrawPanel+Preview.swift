import Foundation
import SQCore
import SQUIKit
import SQDrawKit
import SQLibrary

/// The preview bar and the dividers of the Library panel (the AppKit `LibraryPreviewBar` and its resize strip):
/// viewer (video picture or a larger photo), scrub bar with times, skip back, play/pause, skip forward, mute and volume,
/// a drag handle on the bar's top edge (viewer height, stored under the AppKit key) and one on the sidebar's edge
/// (sidebar width). Playback is `LibraryPreviewPlayer` on the model, never the timeline engine.
extension LibraryDrawPanel {
    /// What a press on the bar or a divider is dragging.
    enum BarDrag: Equatable {
        case viewer(startHeight: Double, startY: CGFloat)
        case sidebar(startWidth: Double, startX: CGFloat)
        case scrub, volume
        case fileOut(start: CGPoint)
    }

    /// Same key as the AppKit `LibraryPreviewBar.heightKey`: both panels share the stored height.
    public static let viewerHeightKey = "sq.library.previewHeight"
    public static let sidebarWidthKey = "sq.library.sidebarWidth"
    /// Top strip of the bar that grabs the divider drag, and the grab zone either side of the sidebar edge.
    static let handleZone = CGFloat(DrawTheme.Spacing.sm)
    static let sidebarGrab: CGFloat = 3
    static let transportRow: CGFloat = 26
    static let videoViewerHeight: CGFloat = 150
    static let imageViewerHeight: CGFloat = 190
    static let skipSeconds: Double = 5
    static let timeWidth: CGFloat = 38
    static let volumeWidth: CGFloat = 72
    static let buttonSize: CGFloat = 24

    // MARK: Geometry

    /// The sidebar width in points: stored (or default), within the limits for this panel width.
    var sidebarW: CGFloat { CGFloat(LibraryPreviewMath.sidebarWidth(stored: storedSidebarWidth, panelWidth: Double(size.width))) }

    /// What the bar shows; nil = no bar (nothing previewed, the Presets section, a search without hits).
    var previewMode: LibraryPreviewMath.Mode? {
        guard !model.isShowingPresets, !isNoHits, model.previewItem != nil else { return nil }
        return model.preview.mode
    }

    var hasTransport: Bool { previewMode == .audio || previewMode == .video }
    var canPlay: Bool { hasTransport && model.preview.errorMessage == nil }

    var storedViewerHeight: Double? {
        defaults.object(forKey: Self.viewerHeightKey) == nil ? nil : defaults.double(forKey: Self.viewerHeightKey)
    }

    func clampedViewerHeight(_ h: Double? = nil) -> CGFloat {
        let fallback = previewMode == .video ? Self.videoViewerHeight : Self.imageViewerHeight
        return CGFloat(LibraryPreviewMath.viewerHeight(stored: h ?? storedViewerHeight, fallback: Double(fallback), panelHeight: Double(size.height)))
    }

    var viewerHeight: CGFloat { previewMode == .video || previewMode == .image ? clampedViewerHeight() : 0 }
    var messageHeight: CGFloat { model.preview.errorMessage != nil || previewMode == .image ? 18 : 0 }
    var transportHeight: CGFloat { hasTransport ? 2 * Self.transportRow + CGFloat(DrawTheme.Spacing.xs) : 0 }

    /// The bar's height (the AppKit `heightConstraint`); 0 = hidden.
    var previewBarHeight: CGFloat {
        guard previewMode != nil else { return 0 }
        let v = viewerHeight, xs = CGFloat(DrawTheme.Spacing.xs), sm = CGFloat(DrawTheme.Spacing.sm)
        let top = v > 0 ? sm + v : xs
        return top + messageHeight + transportHeight + (v == 0 && !hasTransport ? 0 : xs)
    }

    var previewBarRect: CGRect {
        let h = previewBarHeight
        return CGRect(x: contentX, y: max(size.height - h, 0), width: max(size.width - contentX, 0), height: h)
    }

    var viewerRect: CGRect? {
        let v = viewerHeight
        guard v > 0 else { return nil }
        let b = previewBarRect, sm = CGFloat(DrawTheme.Spacing.sm)
        return CGRect(x: b.minX + sm, y: b.minY + sm, width: max(b.width - 2 * sm, 0), height: v)
    }

    var messageRect: CGRect {
        let b = previewBarRect, sm = CGFloat(DrawTheme.Spacing.sm)
        return CGRect(x: b.minX + sm, y: viewerRect?.maxY ?? b.minY + CGFloat(DrawTheme.Spacing.xs), width: max(b.width - 2 * sm, 0), height: 18)
    }

    var scrubRowRect: CGRect {
        let b = previewBarRect, sm = CGFloat(DrawTheme.Spacing.sm)
        return CGRect(x: b.minX + sm, y: b.maxY - CGFloat(DrawTheme.Spacing.xs) - 2 * Self.transportRow, width: max(b.width - 2 * sm, 0), height: Self.transportRow)
    }

    var controlRowRect: CGRect { scrubRowRect.offsetBy(dx: 0, dy: Self.transportRow) }

    var elapsedRect: CGRect { CGRect(x: scrubRowRect.minX, y: scrubRowRect.minY, width: Self.timeWidth, height: Self.transportRow) }
    var totalRect: CGRect { CGRect(x: scrubRowRect.maxX - Self.timeWidth, y: scrubRowRect.minY, width: Self.timeWidth, height: Self.transportRow) }
    var scrubTrackRect: CGRect {
        let sm = CGFloat(DrawTheme.Spacing.sm), r = scrubRowRect
        return CGRect(x: elapsedRect.maxX + sm, y: r.minY, width: max(totalRect.minX - elapsedRect.maxX - 2 * sm, 0), height: r.height)
    }

    private func button(_ i: Int) -> CGRect {
        let r = controlRowRect
        return CGRect(x: r.minX + CGFloat(i) * (Self.buttonSize + CGFloat(DrawTheme.Spacing.xs)), y: r.midY - Self.buttonSize / 2,
                      width: Self.buttonSize, height: Self.buttonSize)
    }
    var backButtonRect: CGRect { button(0) }
    var playButtonRect: CGRect { button(1) }
    var forwardButtonRect: CGRect { button(2) }
    var volumeRect: CGRect {
        let r = controlRowRect
        return CGRect(x: r.maxX - Self.volumeWidth, y: r.minY, width: Self.volumeWidth, height: r.height)
    }
    var muteButtonRect: CGRect {
        let r = controlRowRect
        return CGRect(x: volumeRect.minX - CGFloat(DrawTheme.Spacing.xs) - Self.buttonSize, y: r.midY - Self.buttonSize / 2,
                      width: Self.buttonSize, height: Self.buttonSize)
    }

    var sidebarDividerRect: CGRect {
        guard showsSidebar else { return .zero }
        return CGRect(x: sidebarW - Self.sidebarGrab, y: Self.searchRowHeight, width: 2 * Self.sidebarGrab, height: max(size.height - Self.searchRowHeight, 0))
    }

    // MARK: Play / pause

    /// Space while the Library has focus: pauses or plays the previewed item. False when nothing playable is previewed
    /// (the app then plays the sequence).
    public func handlePlayPause() -> Bool {
        guard !model.isShowingPresets, let item = model.previewItem,
              let mode = LibraryPreviewMath.mode(for: item.entry.kind), mode != .image else { return false }
        model.preview.togglePlayPause()
        return true
    }

    /// The panel left the screen (another dock tab, a closed window) or the sequence started: the preview pauses.
    public func pausePreview() { model.preview.pause() }

    func setMuted(_ on: Bool) {
        if model.preview.mode == .video { model.preview.videoMuted = on } else { model.preview.audioMuted = on }
    }

    // MARK: Cursor, help

    /// The cursor over a divider; nil elsewhere.
    public func cursor(at p: CGPoint) -> DrawCursor? {
        if barDrag != nil {
            if case .sidebar = barDrag { return .resizeLeftRight }
            if case .viewer = barDrag { return .resizeUpDown }
        }
        if showsSidebar, sidebarDividerRect.contains(p) { return .resizeLeftRight }
        let b = previewBarRect
        if b.height > 0, viewerRect != nil, CGRect(x: b.minX, y: b.minY, width: b.width, height: Self.handleZone).contains(p) { return .resizeUpDown }
        return nil
    }

    func previewHelp(at p: CGPoint) -> String? {
        guard previewBarHeight > 0, previewBarRect.contains(p) else { return nil }
        if hasTransport {
            if backButtonRect.contains(p) { return "Back 5 s" }
            if playButtonRect.contains(p) { return model.preview.isPlaying ? "Pause" : "Play" }
            if forwardButtonRect.contains(p) { return "Forward 5 s" }
            if muteButtonRect.contains(p) { return model.preview.isMuted ? "Unmute" : "Mute" }
            if volumeRect.contains(p) { return "Volume" }
            if scrubTrackRect.contains(p) { return "Position" }
        }
        return nil
    }

    // MARK: Events

    /// A press on a divider or the bar; true when it took the press.
    func mouseDownPreview(at p: CGPoint, modifiers m: InputModifiers) -> Bool {
        if showsSidebar, sidebarDividerRect.contains(p), !m.contains(.secondary) {
            endSearchEditing()
            barDrag = .sidebar(startWidth: Double(sidebarW), startX: p.x)
            return true
        }
        let b = previewBarRect
        guard b.height > 0, b.contains(p) else { return false }
        endSearchEditing()
        if m.contains(.secondary) { return true }
        if p.y <= b.minY + Self.handleZone, let v = viewerRect {
            barDrag = .viewer(startHeight: Double(v.height), startY: p.y)
            return true
        }
        guard hasTransport else {
            if viewerRect?.contains(p) == true { barDrag = .fileOut(start: p) }
            return true
        }
        let preview = model.preview
        if canPlay {
            if backButtonRect.contains(p) { preview.skip(by: -Self.skipSeconds); return true }
            if playButtonRect.contains(p) { preview.togglePlayPause(); return true }
            if forwardButtonRect.contains(p) { preview.skip(by: Self.skipSeconds); return true }
            if scrubTrackRect.insetBy(dx: -4, dy: 0).contains(p), preview.duration > 0 {
                barDrag = .scrub
                setScrub(x: p.x)
                return true
            }
        }
        if muteButtonRect.contains(p) { setMuted(!preview.isMuted); return true }
        if volumeRect.insetBy(dx: -4, dy: 0).contains(p) {
            barDrag = .volume
            setVolume(x: p.x)
            return true
        }
        if viewerRect?.contains(p) == true { barDrag = .fileOut(start: p) }
        return true
    }

    func setScrub(x: CGFloat) {
        let r = scrubTrackRect
        model.preview.scrub(toFraction: Double((x - r.minX) / max(r.width, 1)))
    }

    func setVolume(x: CGFloat) {
        let r = volumeRect
        let f = min(max(Double((x - r.minX - 5) / max(r.width - 10, 1)), 0), 1)
        model.preview.volume = Float(f)
        if model.preview.isMuted, f > 0 { setMuted(false) }
    }

    func dragPreview(to p: CGPoint) {
        switch barDrag {
        case .viewer(let startHeight, let startY)?:
            // Up (smaller y) = taller viewer.
            let h = LibraryPreviewMath.resizedHeight(start: startHeight, dragDeltaY: Double(p.y - startY))
            defaults.set(Double(clampedViewerHeight(h)), forKey: Self.viewerHeightKey)
        case .sidebar(let startWidth, let startX)?:
            storedSidebarWidth = LibraryPreviewMath.sidebarWidth(stored: startWidth + Double(p.x - startX), panelWidth: Double(size.width))
        case .scrub?: setScrub(x: p.x)
        case .volume?: setVolume(x: p.x)
        case .fileOut(let start)?:
            guard !isDragging, hypot(p.x - start.x, p.y - start.y) >= Self.dragSlop else {
                if isDragging, let d = dragPayload { onDrag?(d, .moved, p) }
                return
            }
            guard let url = model.previewItem?.url else { barDrag = nil; return }
            dragPayload = .files([url])
            isDragging = true
            onDrag?(.files([url]), .moved, p)
        case nil: break
        }
    }

    func endPreviewDrag(at p: CGPoint) {
        switch barDrag {
        case .sidebar?:
            if let w = storedSidebarWidth { defaults.set(w, forKey: Self.sidebarWidthKey) }
            scroll = min(scroll, maxScroll)
        case .viewer?: scroll = min(scroll, maxScroll)
        case .fileOut?:
            guard isDragging, let d = dragPayload else { return }
            if CGRect(origin: .zero, size: size).contains(p) { onDrag?(d, .canceled, p) } else { onDrag?(d, .ended, p) }
        default: break
        }
    }

    // MARK: Drawing

    func drawPreviewBar(_ c: inout Canvas) {
        let b = previewBarRect
        guard b.height > 0, let mode = previewMode, let item = model.previewItem else { return }
        let t = theme, player = model.preview
        c.fill(b, t.panel)
        c.fill(CGRect(x: b.minX, y: b.minY, width: b.width, height: 1), t.separator)
        if let v = viewerRect {
            drawViewer(&c, v, mode: mode, item: item)
        }
        let err = player.errorMessage
        if err != nil || mode == .image {
            c.draw(err ?? item.entry.name, in: messageRect, fontSize: CGFloat(DrawTheme.TypeSize.body), err != nil ? t.label2 : t.label3)
        }
        guard hasTransport else { return }
        let enabled = canPlay
        let ink = enabled ? t.label2 : t.label3
        let mono = CGFloat(DrawTheme.TypeSize.body)
        c.draw(LibraryPreviewMath.timeText(player.seconds), in: elapsedRect, fontSize: mono, t.label3, align: .right)
        c.draw(LibraryPreviewMath.timeText(player.duration), in: totalRect, fontSize: mono, t.label3, align: .left, inset: 2)
        let tr = scrubTrackRect
        let track = CGRect(x: tr.minX, y: tr.midY - 1, width: tr.width, height: 2)
        c.fill(roundedRect: track, radius: 1, t.fill)
        if player.duration > 0 {
            let kx = track.minX + CGFloat(player.fraction) * track.width
            c.fill(roundedRect: CGRect(x: track.minX, y: track.minY, width: max(kx - track.minX, 0), height: 2), radius: 1, t.accent)
            c.fill(roundedRect: CGRect(x: kx - 5, y: tr.midY - 5, width: 10, height: 10), radius: 5, .white)
        }
        for (rect, icon) in [(backButtonRect, SQIcon.reset), (playButtonRect, player.isPlaying ? .pause : .play), (forwardButtonRect, .rotateCW)] {
            if enabled, hover.map({ rect.contains($0) }) == true { c.fill(roundedRect: rect, radius: CGFloat(DrawTheme.Radius.small), t.fill) }
            c.draw(icon: icon, at: CGPoint(x: rect.midX - 6, y: rect.midY - 6), size: 12, ink)
        }
        let muted = player.isMuted
        let mr = muteButtonRect
        if hover.map({ mr.contains($0) }) == true { c.fill(roundedRect: mr, radius: CGFloat(DrawTheme.Radius.small), t.fill) }
        c.draw(icon: muted || player.volume == 0 ? .volumeOff : .volume, at: CGPoint(x: mr.midX - 6, y: mr.midY - 6), size: 12,
               muted ? t.label3 : t.label2)
        let vr = volumeRect
        let vt = CGRect(x: vr.minX, y: vr.midY - 1, width: vr.width, height: 2)
        c.fill(roundedRect: vt, radius: 1, t.fill)
        let vk = vt.minX + 5 + CGFloat(min(max(player.volume, 0), 1)) * (vt.width - 10)
        c.fill(roundedRect: CGRect(x: vt.minX, y: vt.minY, width: max(vk - vt.minX, 0), height: 2), radius: 1, muted ? t.label3 : t.accent)
        c.fill(roundedRect: CGRect(x: vk - 5, y: vr.midY - 5, width: 10, height: 10), radius: 5, muted ? t.label2 : .white)
    }

    private func drawViewer(_ c: inout Canvas, _ v: CGRect, mode: LibraryPreviewMath.Mode, item: LibraryItem) {
        let t = theme
        c.fill(roundedRect: v, radius: CGFloat(DrawTheme.Radius.control), t.content)
        c.saveGState()
        c.clip(to: v)
        if mode == .video, let live = previewFrame?(), live.size.width > 0, live.size.height > 0 {
            let s = min(v.width / live.size.width, v.height / live.size.height)
            let w = live.size.width * s, h = live.size.height * s
            c.draw(imageSlot: live.slot, in: CGRect(x: v.midX - w / 2, y: v.midY - h / 2, width: w, height: h))
        } else if let poster = picture?(item, v) {
            c.draw(imageSlot: poster.slot, in: v, source: poster.source)
        } else {
            c.draw(icon: LibraryLabels.symbol(for: item.entry.kind), at: CGPoint(x: v.midX - 11, y: v.midY - 11), size: 22, t.label3)
        }
        c.restoreGState()
    }
}
