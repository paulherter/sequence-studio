import AppKit
import Metal
import SQCore
import SQEditorUI
import SQLibrary
import SQPlayback

/// Title templates in the app (TEMPLATE-ECOSYSTEM T3): Save as Template, apply from the Library, zones toggle.
extension EditorPanels {
    /// Name sheet for the selected video layers, then saves them to the Library under Titles with a thumbnail.
    func saveSelectionAsTemplate() {
        guard let window = timelineView.window else { return }
        let name = session.singleSelectedClip?.name ?? "Title"
        guard session.titleTemplateFromSelection(name: name) != nil else {
            onStatus?(session.lastError ?? "Select the title layers first.")
            return
        }
        TitleTemplateSaveSheet.present(on: window, defaultName: name) { [weak self] chosen in
            guard let self, let chosen, let template = session.titleTemplateFromSelection(name: chosen) else { return }
            let wantsThumbnail = session.playheadIsInsideSelectedVideo
            session.stopPlayback()
            let engine = session.engine
            Task { @MainActor in
                var png: Data?
                if wantsThumbnail {
                    await engine.withFullSizeFrame { result in
                        if case .frame(let texture) = result { png = Self.thumbnailPNG(texture) }
                    }
                }
                do {
                    let item = try TitleTemplatePreset(template: template, thumbnail: png).presetItem(name: chosen)
                    try await libraryModel.savePreset(item)
                    let note = wantsThumbnail && png == nil ? " " + SQL10n.string("No preview image could be made.") : ""
                    onStatus?(SQL10n.format("Saved template “%@”. Find it in the Library under Titles.", chosen) + note)
                } catch {
                    onStatus?(SQL10n.format("The template could not be saved: %@", SQL10n.errorText(error)))
                }
            }
        }
    }

    /// A 320 px wide PNG of a rendered frame; nil when the frame cannot be read.
    @MainActor static func thumbnailPNG(_ texture: MTLTexture?) -> Data? {
        guard let texture, let snap = FrameExport.snapshot(of: texture), let full = FrameExport.cgImage(from: snap), full.width > 0 else { return nil }
        let w = min(320, full.width), h = max(1, full.height * w / full.width)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(full, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let small = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: small).representation(using: .png, properties: [:])
    }

    /// Zones on for all selected clips when any is off, else off.
    func toggleZonesOfSelection() {
        let clips = session.selectedZoneClips
        guard !clips.isEmpty else { onStatus?("Select a title clip first."); return }
        let on = clips.contains { $0.zones == nil }
        for c in clips where !session.setZonesEnabled(on, clip: c.id) { onStatus?(session.lastError ?? "Zones could not be changed."); return }
    }
}
