import AppKit
import DiskArbitration
import SQLibrary

/// What the card import knows about a mounted volume (the shared dialog's mount note and Card Import button read it).
enum CardImportCoordinator {
    nonisolated static func facts(for url: URL) -> VolumeFacts? {
        let keys: Set<URLResourceKey> = [.volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsLocalKey, .volumeIsBrowsableKey]
        guard let v = try? url.resourceValues(forKeys: keys) else { return nil }
        return VolumeFacts(url: url, isInternal: v.volumeIsInternal ?? true, isRemovable: v.volumeIsRemovable ?? false,
                           isEjectable: v.volumeIsEjectable ?? false, isLocal: v.volumeIsLocal ?? true, isBrowsable: v.volumeIsBrowsable ?? true,
                           isDiskImage: isDiskImage(url))
    }

    /// DiskArbitration reports mounted .dmg files with the device model "Disk Image".
    nonisolated static func isDiskImage(_ url: URL) -> Bool {
        guard let session = DASessionCreate(kCFAllocatorDefault), let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
              let desc = DADiskCopyDescription(disk) as? [String: Any] else { return false }
        if (desc[kDADiskDescriptionDeviceModelKey as String] as? String) == "Disk Image" { return true }
        return (desc[kDADiskDescriptionDeviceProtocolKey as String] as? String) == "Virtual Interface"
    }
}
