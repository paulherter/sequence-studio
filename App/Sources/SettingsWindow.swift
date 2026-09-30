import AppKit
import CoreAudio
import SSEditorUI

/// Settings window (⌘,): General, Playback, Media, Keyboard. Real AppKit controls in an NSTabView; every change is
/// written to UserDefaults at once (`AppSettings`). Autosave interval and audio output are read at launch.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    unowned let controller: AppController
    private var window: NSWindow?

    private let autosavePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let recoveryCheck = NSButton(checkboxWithTitle: "Offer to restore the last autosave after an unclean quit", target: nil, action: nil)
    private let qualityPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let audioPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let cachePath = NSTextField(labelWithString: "")
    private let capPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let usedLabel = NSTextField(labelWithString: "")
    private let keyTable = NSTableView()
    private var keyRows: [KeyboardListing.Row] = []

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
        tabs.addTabViewItem(item("Keyboard", "keyboard", keyboardPage()))
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
        return column([row("Autosave", autosavePopUp), row("Recovery", recoveryCheck),
                       note("Changed projects are saved to a recovery copy; your project file is only written when you save. The interval applies the next time Sequence Studio starts.")])
    }

    private func playbackPage() -> NSView {
        for q in MonitorQuality.allCases { qualityPopUp.addItem(withTitle: q.title); qualityPopUp.lastItem?.representedObject = q.rawValue }
        qualityPopUp.target = self; qualityPopUp.action = #selector(changed)
        audioPopUp.addItem(withTitle: "System Default")
        for d in Self.outputDevices() {
            audioPopUp.addItem(withTitle: d.name)
            audioPopUp.lastItem?.representedObject = d.uid
        }
        audioPopUp.target = self; audioPopUp.action = #selector(changed)
        return column([row("Default quality", qualityPopUp), row("Audio output", audioPopUp),
                       note("Quality is the Program monitor's playback resolution at launch; change it any time in the monitor. The audio output is stored and used by the playback engine once device selection is wired.")])
    }

    private func mediaPage() -> NSView {
        cachePath.lineBreakMode = .byTruncatingMiddle
        cachePath.widthAnchor.constraint(lessThanOrEqualToConstant: 280).isActive = true
        let choose = NSButton(title: "Choose…", target: self, action: #selector(chooseCache))
        let reset = NSButton(title: "Default", target: self, action: #selector(resetCache))
        let folder = NSStackView(views: [cachePath, choose, reset])
        folder.spacing = 8
        for g in AppSettings.cacheCapChoices { capPopUp.addItem(withTitle: "\(g) GB"); capPopUp.lastItem?.tag = g }
        capPopUp.target = self; capPopUp.action = #selector(changed)
        usedLabel.textColor = .secondaryLabelColor
        return column([row("Cache folder", folder), row("Size cap", capPopUp), row("In use", usedLabel),
                       note("Proxies and render cache are stored here. When the cap is reached the oldest files are removed first.")])
    }

    private func keyboardPage() -> NSView {
        keyRows = KeyboardListing.rows(controller.commandMap)
        for (id, title, w) in [("command", "Command", 220.0), ("shortcut", "Shortcut", 110), ("scope", "Active in", 110)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title; c.width = w
            keyTable.addTableColumn(c)
        }
        keyTable.dataSource = self
        keyTable.delegate = self
        keyTable.rowHeight = 20
        keyTable.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView()
        scroll.documentView = keyTable
        scroll.hasVerticalScroller = true
        scroll.heightAnchor.constraint(equalToConstant: 250).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 500).isActive = true
        return column([scroll, note("Premiere's default shortcuts. Editing shortcuts comes later.")])
    }

    // MARK: State

    private func load() {
        let s = controller.settings
        autosavePopUp.selectItem(at: AppSettings.autosaveChoices.firstIndex(of: s.autosaveInterval) ?? 2)
        recoveryCheck.state = s.offerRecovery ? .on : .off
        qualityPopUp.selectItem(at: MonitorQuality.allCases.firstIndex(of: s.defaultQuality) ?? 0)
        if let uid = s.audioOutputUID, let i = audioPopUp.itemArray.firstIndex(where: { $0.representedObject as? String == uid }) {
            audioPopUp.selectItem(at: i)
        } else { audioPopUp.selectItem(at: 0) }
        cachePath.stringValue = s.effectiveCacheFolder.path
        capPopUp.selectItem(withTag: s.cacheCapGB)
        refreshUsed()
    }

    @objc private func changed() {
        var s = controller.settings
        s.autosaveInterval = AppSettings.autosaveChoices[max(autosavePopUp.indexOfSelectedItem, 0)]
        s.offerRecovery = recoveryCheck.state == .on
        if let raw = qualityPopUp.selectedItem?.representedObject as? String, let q = MonitorQuality(rawValue: raw) { s.defaultQuality = q }
        s.audioOutputUID = audioPopUp.selectedItem?.representedObject as? String
        s.cacheCapGB = capPopUp.selectedItem?.tag ?? s.cacheCapGB
        controller.settings = s
        s.save()
    }

    @objc private func chooseCache() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.prompt = "Choose"
        p.directoryURL = controller.settings.effectiveCacheFolder
        guard let w = window else { return }
        p.beginSheetModal(for: w) { [weak self] r in
            MainActor.assumeIsolated {
                guard let self, r == .OK, let url = p.url else { return }
                self.controller.settings.cacheFolder = url
                self.controller.settings.save()
                self.load()
            }
        }
    }

    @objc private func resetCache() {
        controller.settings.cacheFolder = nil
        controller.settings.save()
        load()
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

    // MARK: Keyboard table

    func numberOfRows(in tableView: NSTableView) -> Int { keyRows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let r = keyRows[row]
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "command": text = r.command
        case "shortcut": text = r.shortcut
        default: text = r.scope
        }
        let l = NSTextField(labelWithString: text)
        l.font = tableColumn?.identifier.rawValue == "shortcut" ? .monospacedSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 12)
        return l
    }

    // MARK: Audio devices

    private static func outputDevices() -> [(name: String, uid: String)] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard hasOutput(id), let name = string(id, kAudioObjectPropertyName), let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            return (name, uid)
        }
    }

    private static func hasOutput(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                              mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }
}
