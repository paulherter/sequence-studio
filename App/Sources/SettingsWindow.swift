import AppKit
import CoreAudio
import SQEditorUI

/// Settings window (⌘,): General, Playback, Media. Real AppKit controls in an NSTabView; every change is
/// written to UserDefaults at once (`AppSettings`). Autosave interval and audio output are read at launch.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    unowned let controller: AppController
    private var window: NSWindow?

    private let autosavePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let recoveryCheck = NSButton(checkboxWithTitle: "Offer to restore the last autosave after an unclean quit", target: nil, action: nil)
    private let qualityPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let textDurationPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let cachePath = NSTextField(labelWithString: "")
    private let usedLabel = NSTextField(labelWithString: "")

    init(controller: AppController) {
        self.controller = controller
        super.init()
    }

    func show() {
        if window == nil { build() }
        load()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Build

    private func build() {
        let tabs = NSTabView()
        tabs.addTabViewItem(item("General", "gearshape", generalPage()))
        tabs.addTabViewItem(item("Playback", "play.rectangle", playbackPage()))
        tabs.addTabViewItem(item("Media", "externaldrive", mediaPage()))
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Sequence Studio Settings"
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = tabs
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        w.setFrameAutosaveName("SequenceStudioSettings")
        window = w
    }

    private func item(_ title: String, _ symbol: String, _ view: NSView) -> NSTabViewItem {
        let i = NSTabViewItem(identifier: title)
        i.label = title
        i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        let host = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor, constant: 16),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 20),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -20),
        ])
        i.view = host
        return i
    }

    private func row(_ title: String, _ control: NSView) -> NSStackView {
        let l = NSTextField(labelWithString: title + ":")
        l.alignment = .right
        l.widthAnchor.constraint(equalToConstant: 130).isActive = true
        let s = NSStackView(views: [l, control])
        s.alignment = .firstBaseline
        s.spacing = 8
        return s
    }

    private func note(_ text: String) -> NSTextField {
        let n = NSTextField(wrappingLabelWithString: text)
        n.font = .systemFont(ofSize: 11)
        n.textColor = .secondaryLabelColor
        n.preferredMaxLayoutWidth = 480
        return n
    }

    private func column(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 12
        return s
    }

    private func generalPage() -> NSView {
        for (i, v) in AppSettings.autosaveChoices.enumerated() {
            autosavePopUp.addItem(withTitle: v < 120 ? "Every minute" : "Every \(Int(v / 60)) minutes")
            autosavePopUp.lastItem?.tag = i
        }
        autosavePopUp.target = self; autosavePopUp.action = #selector(changed)
        recoveryCheck.target = self; recoveryCheck.action = #selector(changed)
        for s in AppSettings.textDurationChoices { textDurationPopUp.addItem(withTitle: s == 1 ? "1 second" : "\(s) seconds"); textDurationPopUp.lastItem?.tag = s }
        textDurationPopUp.target = self; textDurationPopUp.action = #selector(changed)
        return column([row("Autosave", autosavePopUp), row("Recovery", recoveryCheck),
                       row("New text length", textDurationPopUp),
                       note("Changed projects are saved to a recovery copy; your project file is only written when you save. The interval applies the next time Sequence Studio starts.")])
    }

    private func playbackPage() -> NSView {
        for q in MonitorQuality.allCases { qualityPopUp.addItem(withTitle: q.title); qualityPopUp.lastItem?.representedObject = q.rawValue }
        qualityPopUp.target = self; qualityPopUp.action = #selector(changed)
        return column([row("Default quality", qualityPopUp),
                       note("Quality is the Program monitor's playback resolution at launch; change it any time in the monitor. Audio plays on the system output device.")])
    }

    private func mediaPage() -> NSView {
        cachePath.lineBreakMode = .byTruncatingMiddle
        cachePath.widthAnchor.constraint(lessThanOrEqualToConstant: 300).isActive = true
        let clear = NSButton(title: "Clear Cache", target: self, action: #selector(clearCache))
        usedLabel.textColor = .secondaryLabelColor
        return column([row("Cache folder", cachePath), row("In use", usedLabel), row("", clear),
                       note("Previews and proxies are stored here. Clearing the cache is safe: files are rebuilt when needed.")])
    }

    // MARK: State

    private func load() {
        let s = controller.settings
        autosavePopUp.selectItem(at: AppSettings.autosaveChoices.firstIndex(of: s.autosaveInterval) ?? 2)
        recoveryCheck.state = s.offerRecovery ? .on : .off
        qualityPopUp.selectItem(at: MonitorQuality.allCases.firstIndex(of: s.defaultQuality) ?? 0)
        textDurationPopUp.selectItem(withTag: s.defaultTextSeconds)
        if textDurationPopUp.selectedItem == nil { textDurationPopUp.selectItem(withTag: 5) }
        cachePath.stringValue = s.effectiveCacheFolder.path
        refreshUsed()
    }

    @objc private func changed() {
        var s = controller.settings
        s.autosaveInterval = AppSettings.autosaveChoices[max(autosavePopUp.indexOfSelectedItem, 0)]
        s.offerRecovery = recoveryCheck.state == .on
        if let raw = qualityPopUp.selectedItem?.representedObject as? String, let q = MonitorQuality(rawValue: raw) { s.defaultQuality = q }
        if let t = textDurationPopUp.selectedItem?.tag, t > 0 { s.defaultTextSeconds = t }
        controller.settings = s
        s.save()
    }

    @objc private func clearCache() {
        let url = controller.settings.effectiveCacheFolder
        if let items = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
            for f in items { try? FileManager.default.removeItem(at: f) }
        }
        refreshUsed()
    }

    private func refreshUsed() {
        usedLabel.stringValue = "Calculating…"
        let url = controller.settings.effectiveCacheFolder
        Task.detached(priority: .utility) {
            let bytes = Self.folderSize(url)
            let text = bytes == 0 ? "Empty" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            await MainActor.run { [weak self] in self?.usedLabel.stringValue = text }
        }
    }

    nonisolated private static func folderSize(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            total += Int64((try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
