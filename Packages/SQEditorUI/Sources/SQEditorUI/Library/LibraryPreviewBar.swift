import AppKit
import AVFoundation
import ImageIO
import SQLibrary

@MainActor
private func trackPreview(_ apply: @escaping @MainActor () -> Void) {
    withObservationTracking(apply) { Task { @MainActor in trackPreview(apply) } }
}

/// Bottom bar of the Library panel: viewer (video poster/playback or a larger photo), then the transport
/// (scrub bar with times; skip back, play/pause, skip forward, mute, volume). Shows the item selected in the grid or list.
/// Plays through `LibraryPreviewPlayer`, never through the timeline engine.
@MainActor
final class LibraryPreviewBar: NSView, NSDraggingSource {
    static let heightKey = "sq.library.previewHeight"
    /// Top strip of the bar that grabs the divider drag.
    static let handleZone: CGFloat = Theme.Spacing.sm
    static let videoHeight: CGFloat = 150
    static let imageHeight: CGFloat = 190
    static let rowHeight: CGFloat = 26
    static let skipSeconds: Double = 5

    private let model: LibraryPanelModel
    private let viewer = NSView()
    private let imageView = NSImageView()
    private let playerLayer = AVPlayerLayer()
    private let message = NSTextField(labelWithString: "")
    private let elapsed = NSTextField(labelWithString: "0:00")
    private let total = NSTextField(labelWithString: "0:00")
    private let scrubber = SQSlider(value: 0, minValue: 0, maxValue: 1)
    private let volume = SQSlider(value: 0.8, minValue: 0, maxValue: 1)
    private lazy var playButton = IconButton(symbol: .play, label: "Play", size: 12) { [weak self] in self?.model.preview.togglePlayPause() }
    private lazy var backButton = IconButton(symbol: .reset, label: "Back 5 s", size: 12) { [weak self] in self?.model.preview.skip(by: -LibraryPreviewBar.skipSeconds) }
    private lazy var forwardButton = IconButton(symbol: .rotateCW, label: "Forward 5 s", size: 12) { [weak self] in self?.model.preview.skip(by: LibraryPreviewBar.skipSeconds) }
    private lazy var muteButton = IconButton(symbol: .volume, label: "Mute", size: 12) { [weak self] in self?.toggleMute() }
    private let transport = NSStackView()
    private var heightConstraint: NSLayoutConstraint!
    private var viewerHeight: NSLayoutConstraint!
    private var shownImageID: LibraryEntryID?
    private var imageTask: Task<Void, Never>?
    private var scrubbing = false
    private enum Gesture { case resize(startHeight: Double, startWindowY: CGFloat), drag(start: NSPoint) }
    private var gesture: Gesture?
    var defaults: UserDefaults = .standard

    init(model: LibraryPanelModel) {
        self.model = model
        super.init(frame: .zero)
        build()
        trackPreview { [weak self] in self?.refresh() }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    isolated deinit { imageTask?.cancel() }

    override var isFlipped: Bool { true }

    private func build() {
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.panel.cgColor
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = Theme.Colors.separator.cgColor

        viewer.wantsLayer = true
        viewer.layer?.cornerRadius = LibraryTile.thumbRadius
        viewer.layer?.masksToBounds = true
        viewer.layer?.backgroundColor = Theme.Colors.tileBackground.cgColor
        playerLayer.videoGravity = .resizeAspect
        viewer.layer?.addSublayer(playerLayer)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        viewer.addSubview(imageView)

        message.font = Theme.Typography.body
        message.textColor = Theme.Colors.label3
        message.lineBreakMode = .byTruncatingTail

        for t in [elapsed, total] {
            t.font = Theme.Typography.tabularBody
            t.textColor = Theme.Colors.label3
            t.setContentHuggingPriority(.required, for: .horizontal)
        }
        elapsed.alignment = .right
        total.alignment = .left
        scrubber.isContinuous = true
        scrubber.target = self
        scrubber.action = #selector(scrubbed)
        scrubber.onBegin = { [weak self] in self?.scrubbing = true }
        scrubber.onEnd = { [weak self] _ in self?.scrubbing = false }
        scrubber.sqToolTip = "Position"
        volume.target = self
        volume.action = #selector(volumeChanged)
        volume.defaultValue = 0.8
        volume.sqToolTip = "Volume"

        let scrubRow = NSStackView(views: [elapsed, scrubber, total])
        scrubRow.spacing = Theme.Spacing.sm
        let buttons = NSStackView(views: [backButton, playButton, forwardButton])
        buttons.spacing = Theme.Spacing.xs
        let right = NSStackView(views: [muteButton, volume])
        right.spacing = Theme.Spacing.xs
        let controlRow = NSStackView(views: [buttons, NSView(), right])
        controlRow.spacing = Theme.Spacing.sm
        transport.orientation = .vertical
        transport.alignment = .leading
        transport.spacing = 0
        transport.setViews([scrubRow, controlRow], in: .top)
        for r in [scrubRow, controlRow] {
            r.translatesAutoresizingMaskIntoConstraints = false
            r.heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true
            r.widthAnchor.constraint(equalTo: transport.widthAnchor).isActive = true
        }
        elapsed.translatesAutoresizingMaskIntoConstraints = false
        total.translatesAutoresizingMaskIntoConstraints = false
        elapsed.widthAnchor.constraint(equalToConstant: 38).isActive = true
        total.widthAnchor.constraint(equalToConstant: 38).isActive = true
        volume.translatesAutoresizingMaskIntoConstraints = false
        volume.widthAnchor.constraint(equalToConstant: 72).isActive = true

        for v in [line, viewer, message, transport] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        let pad = Theme.Spacing.sm
        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        viewerHeight = viewer.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            heightConstraint,
            line.topAnchor.constraint(equalTo: topAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
            viewer.topAnchor.constraint(equalTo: topAnchor, constant: pad),
            viewer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            viewer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            viewerHeight,
            imageView.topAnchor.constraint(equalTo: viewer.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: viewer.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: viewer.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: viewer.trailingAnchor),
            message.topAnchor.constraint(equalTo: viewer.bottomAnchor),
            message.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            message.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            transport.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            transport.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            transport.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Spacing.xs),
        ])
        isHidden = true
        refresh()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = viewer.bounds
        CATransaction.commit()
    }

    // MARK: Divider and drag-out

    private var storedHeight: Double? { defaults.object(forKey: Self.heightKey) == nil ? nil : defaults.double(forKey: Self.heightKey) }

    private func currentViewerHeight(fallback: CGFloat, override: Double? = nil) -> CGFloat {
        CGFloat(LibraryPreviewMath.viewerHeight(stored: override ?? storedHeight, fallback: Double(fallback),
                                                panelHeight: Double(superview?.bounds.height ?? 0)))
    }

    /// The divider strip and the viewer belong to the bar itself (resize / drag-out); controls keep their own clicks.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let local = superview.map({ convert(point, from: $0) }) else { return super.hitTest(point) }
        if local.y <= Self.handleZone && bounds.contains(local) { return self }
        if !viewer.isHidden, viewer.frame.contains(local) { return self }
        return super.hitTest(point)
    }

    override func resetCursorRects() {
        addCursorRect(NSRect(x: 0, y: 0, width: bounds.width, height: Self.handleZone), cursor: .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if p.y <= Self.handleZone, !viewer.isHidden { gesture = .resize(startHeight: Double(viewer.frame.height), startWindowY: event.locationInWindow.y) }
        else { gesture = .drag(start: p) }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch gesture {
        case .resize(let startHeight, let startWindowY):
            // Window space is bottom-up: pointer above the start = positive change = taller viewer.
            let delta = Double(startWindowY - event.locationInWindow.y)
            setViewerHeight(LibraryPreviewMath.resizedHeight(start: startHeight, dragDeltaY: delta))
        case .drag(let start):
            guard hypot(p.x - start.x, p.y - start.y) > 4, let url = model.previewItem?.url else { return }
            gesture = nil
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)   // the same payload a Library list row writes
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 48, height: 48)
            item.setDraggingFrame(NSRect(x: p.x - 24, y: p.y - 24, width: 48, height: 48), contents: icon)
            beginDraggingSession(with: [item], event: event, source: self)
        case nil: break
        }
    }

    override func mouseUp(with event: NSEvent) {
        gesture = nil
    }

    override var mouseDownCanMoveWindow: Bool { false }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

    private func setViewerHeight(_ h: Double) {
        let clamped = currentViewerHeight(fallback: Self.videoHeight, override: h)
        viewerHeight.constant = clamped
        let mode = model.preview.mode
        let messageH: CGFloat = model.preview.errorMessage != nil || mode == .image ? 18 : 0
        let hasTransport = mode == .audio || mode == .video
        let transportH = hasTransport ? 2 * Self.rowHeight + Theme.Spacing.xs : 0
        heightConstraint.constant = Theme.Spacing.sm + clamped + messageH + transportH + Theme.Spacing.xs
        defaults.set(Double(clamped), forKey: Self.heightKey)
    }

    // MARK: Refresh

    private func refresh() {
        let item = model.previewItem
        let p = model.preview
        let mode = p.mode
        let playing = p.isPlaying
        let seconds = p.seconds, duration = p.duration
        let error = p.errorMessage
        let vol = p.volume
        let muted = p.isMuted
        let hasTransport = mode == .audio || mode == .video

        guard let item, mode != nil else {
            isHidden = true
            heightConstraint.constant = 0
            playerLayer.player = nil
            shownImageID = nil
            return
        }
        isHidden = false
        let viewerH: CGFloat = mode == .video || mode == .image ? currentViewerHeight(fallback: mode == .video ? Self.videoHeight : Self.imageHeight) : 0
        viewer.isHidden = viewerH == 0
        viewerHeight.constant = viewerH
        let messageH: CGFloat = error != nil || mode == .image ? 18 : 0
        message.isHidden = messageH == 0
        message.stringValue = error ?? (mode == .image ? item.entry.name : "")
        message.textColor = error != nil ? Theme.Colors.label2 : Theme.Colors.label3
        transport.isHidden = !hasTransport
        let transportH = hasTransport ? 2 * Self.rowHeight + Theme.Spacing.xs : 0
        let top = viewerH > 0 ? Theme.Spacing.sm + viewerH : Theme.Spacing.xs
        heightConstraint.constant = top + messageH + transportH + (viewerH == 0 && !hasTransport ? 0 : Theme.Spacing.xs)

        playerLayer.player = mode == .video ? p.player : nil
        imageView.isHidden = mode != .image
        if mode == .image { showImage(item) } else { shownImageID = nil; imageView.image = nil }

        let canPlay = hasTransport && error == nil
        for b in [playButton, backButton, forwardButton] { b.isEnabled = canPlay }
        scrubber.isEnabled = canPlay && duration > 0
        playButton.setSymbol(playing ? .pause : .play, tint: Theme.Colors.label2, size: 12)
        playButton.sqToolTip = playing ? "Pause" : "Play"
        muteButton.setSymbol(muted || vol == 0 ? .volumeOff : .volume, tint: muted ? Theme.Colors.label3 : Theme.Colors.label2, size: 12)
        muteButton.sqToolTip = muted ? "Unmute" : "Mute"
        elapsed.stringValue = LibraryPreviewMath.timeText(seconds)
        total.stringValue = LibraryPreviewMath.timeText(duration)
        if !scrubbing { scrubber.doubleValue = duration > 0 ? seconds / duration : 0 }
        if abs(volume.doubleValue - Double(vol)) > 0.001 { volume.doubleValue = Double(vol) }
        volume.alphaValue = muted ? 0.4 : 1
    }

    private func showImage(_ item: LibraryItem) {
        guard shownImageID != item.id else { return }
        shownImageID = item.id
        imageView.image = nil
        imageTask?.cancel()
        let url = item.url, id = item.id
        imageTask = Task { [weak self] in
            let image = await Task.detached(priority: .userInitiated) { Self.loadImage(url) }.value
            guard !Task.isCancelled, let self, self.shownImageID == id else { return }
            self.imageView.image = image
            if image == nil { self.message.stringValue = "Can't show this image." }
        }
    }

    /// Downsampled read (max 1400 px): a photo never decodes at full size just for the preview.
    nonisolated private static func loadImage(_ url: URL) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: 1400]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    // MARK: Actions

    @objc private func scrubbed() { model.preview.scrub(toFraction: scrubber.doubleValue) }
    @objc private func volumeChanged() {
        model.preview.volume = Float(volume.doubleValue)
        if model.preview.isMuted, volume.doubleValue > 0 { setMuted(false) }
    }
    private func toggleMute() { setMuted(!model.preview.isMuted) }
    private func setMuted(_ on: Bool) {
        if model.preview.mode == .video { model.preview.videoMuted = on } else { model.preview.audioMuted = on }
    }
}
