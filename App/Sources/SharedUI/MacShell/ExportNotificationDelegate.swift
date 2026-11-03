import AppKit
import UserNotifications

/// Click on an "Export finished" notification: shows the exported file in Finder.
final class ExportNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let pathKey = "sq.export.path"

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let path = response.notification.request.content.userInfo[Self.pathKey] as? String else { return }
        await MainActor.run {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: path) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            else { NSWorkspace.shared.open(url.deletingLastPathComponent()) }
        }
    }
}
