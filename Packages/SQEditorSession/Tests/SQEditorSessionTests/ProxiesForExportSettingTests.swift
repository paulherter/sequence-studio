import Foundation
import Testing
@testable import SQEditorSession

@Suite struct ProxiesForExportSettingTests {
    @Test func offByDefaultAndRoundTrips() {
        let name = "sq.test.proxyexport.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        defer { d.removePersistentDomain(forName: name) }
        #expect(AppSettings.load(from: d).useProxiesForExport == false)
        var s = AppSettings.load(from: d)
        s.useProxiesForExport = true
        s.save(to: d)
        #expect(AppSettings.load(from: d).useProxiesForExport)
        #expect(d.bool(forKey: "sq.proxy.export"))
    }
}
