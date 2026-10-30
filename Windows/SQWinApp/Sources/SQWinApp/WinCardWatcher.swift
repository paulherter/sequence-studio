import Foundation
import CSQWinApp
import SQEditorSession
import SQLibrary
import WinSDK

/// Opens the card import when a camera card, stick or external disk is connected (the Mac CardImportCoordinator's mount
/// note) and closes its dialog when the drive goes away (the Mac closes on unmount). A drive there at launch is offered
/// once, on the first look, when it looks like a camera card (`CardAtLaunch`). Which drive counts is the portable `DriveFacts` rule: removable, or fixed on a USB, FireWire, SD or MMC bus
/// (USB SSDs report DRIVE_FIXED), never the system drive.
/// shortcut: polls the drive letters every 2 s from the frame loop; upgrade to WM_DEVICECHANGE (DBT_DEVICEARRIVAL) when
/// the 2 s delay is noticed.
@MainActor
final class WinCardWatcher {
    private var arrivals: DriveArrivals
    private var last = Date()
    private let onCard: @MainActor (URL) -> Void
    private let onGone: @MainActor (URL) -> Void
    /// Camera cards already in at launch, offered on the first look.
    private var atLaunch: [String]

    init(onCard: @escaping @MainActor (URL) -> Void, onGone: @escaping @MainActor (URL) -> Void = { _ in }) {
        self.onCard = onCard
        self.onGone = onGone
        let present = Self.readyDrives()
        arrivals = DriveArrivals(present: present)
        atLaunch = CardAtLaunch.offers(present) { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] }
    }

    /// Call once per frame; looks at the drives every 2 seconds.
    func poll(now: Date = Date()) {
        guard now.timeIntervalSince(last) >= 2 else { return }
        last = now
        let change = arrivals.update(Self.readyDrives())
        for r in change.removed { onGone(URL(fileURLWithPath: r, isDirectory: true)) }
        guard CardImportSettings.enabled else { atLaunch = []; return }
        for r in atLaunch where !change.removed.contains(r) { onCard(URL(fileURLWithPath: r, isDirectory: true)) }
        atLaunch = []
        for r in change.added { onCard(URL(fileURLWithPath: r, isDirectory: true)) }
    }

    private static func root(_ i: Int) -> String { String(UnicodeScalar(UInt8(65 + i))) + ":\\" }

    /// The drive letters with a medium in them (a card reader keeps its letter while empty). The bus is asked only of
    /// fixed drives (removable ones count anyway).
    static func readyDrives() -> [DriveFacts] {
        let all = UInt32(GetLogicalDrives())
        let system = (ProcessInfo.processInfo.environment["SystemDrive"] ?? "C:").uppercased().prefix(1)
        var out: [DriveFacts] = []
        for i in 0..<26 where all & (1 << UInt32(i)) != 0 {
            let r = root(i)
            let facts: DriveFacts? = Array(r.utf16 + [0]).withUnsafeBufferPointer { p -> DriveFacts? in
                let type = GetDriveTypeW(p.baseAddress)
                guard GetVolumeInformationW(p.baseAddress, nil, 0, nil, nil, nil, nil, 0) else { return nil }
                let kind: DriveFacts.Kind = type == UINT(DRIVE_REMOVABLE) ? .removable : type == UINT(DRIVE_FIXED) ? .fixed : .other
                var bus = DriveFacts.Bus.other
                if kind == .fixed {
                    switch sq_drive_bus_type(p.baseAddress) {
                    case 7: bus = .usb
                    case 4: bus = .firewire
                    case 12: bus = .sd
                    case 13: bus = .mmc
                    default: bus = .other
                    }
                }
                return DriveFacts(root: r, kind: kind, bus: bus, isSystem: r.hasPrefix(system))
            }
            if let facts { out.append(facts) }
        }
        return out
    }
}
