import Foundation
import Testing
import SQCore
@testable import SQLibrary

@Suite struct KeystoneLibraryTests {
    private func mine(_ name: String = "Mine") -> Keystone {
        Keystone(name: name, duration: Time(1, 1),
                 rotation: KeyframeTrack(keys: [Keyframe(time: .zero, value: 0.0), Keyframe(time: Time(1, 1), value: 45.0)]))
    }

    private var shown: [Keystone] { Keystone.builtIns.filter { !HiddenCatalog.isHidden(keystone: $0.id) } }

    @Test func hiddenBuiltInsAreNotListedUnlessTheUserEditedThem() throws {
        let ids = KeystoneLibrary.keystones(from: []).map(\.id)
        #expect(ids == shown.map(\.id))   // hidden: Spin In is the one built-in left (SQ_SHOW_HIDDEN=1 lists all)
        var punch = Keystone.builtIn(named: "Punch In")!
        punch.easing = .easeInOut
        let edited = KeystoneLibrary.keystones(from: [try KeystoneLibrary.presetItem(for: punch)]).map(\.id)
        #expect(edited.contains(punch.id) && Set(edited) == Set(shown.map(\.id) + [punch.id]) && edited.count == Set(edited).count)
    }

    @Test func deletingTheChangesOfAHiddenBuiltInRevertsItWithoutADanglingEntry() throws {
        var punch = Keystone.builtIn(named: "Punch In")!
        punch.easing = .easeInOut
        let saved = [try KeystoneLibrary.presetItem(for: punch)]
        #expect(KeystoneLibrary.keystone(id: punch.id, from: saved)?.easing == .easeInOut)
        let afterDelete = saved.filter { $0.id != punch.id }
        // Listed as before the edit (hidden again), no duplicate, no leftover changes; the id still resolves to the built-in.
        #expect(KeystoneLibrary.keystones(from: afterDelete).map(\.id) == KeystoneLibrary.keystones(from: []).map(\.id))
        #expect(!KeystoneLibrary.isCustomised(punch.id, in: afterDelete))
        let back = try #require(KeystoneLibrary.keystone(id: punch.id, from: afterDelete))
        #expect(back == Keystone.builtIn(named: "Punch In") && back.easing == Keystone.builtIn(named: "Punch In")?.easing)
        #expect(KeystoneLibrary.keystone(id: UUID(), from: afterDelete) == nil)
    }

    @Test func builtInsComeFirstThenUserKeystones() throws {
        let k = mine()
        let items = [try KeystoneLibrary.presetItem(for: k)]
        let all = KeystoneLibrary.keystones(from: items)
        #expect(all.prefix(shown.count).map(\.id) == shown.map(\.id))
        #expect(all.last == k)
        #expect(items[0].kind == .keystone && items[0].id == k.id && items[0].name == "Mine")
    }

    @Test func savedBuiltInReplacesItInPlace() throws {
        var punch = Keystone.builtIn(named: "Punch In")!
        punch.easing = .easeInOut
        let all = KeystoneLibrary.keystones(from: [try KeystoneLibrary.presetItem(for: punch)])
        #expect(all.count == shown.count + (HiddenCatalog.isHidden(keystone: punch.id) ? 1 : 0))   // the edited, hidden Punch In is the user's own now
        #expect(all.first { $0.id == punch.id }?.easing == .easeInOut)
        #expect(KeystoneLibrary.isCustomised(punch.id, in: [try KeystoneLibrary.presetItem(for: punch)]))
    }

    @Test func otherKindsAndDamagedPayloadsAreSkipped() throws {
        let junk = PresetItem(kind: .keystone, name: "bad", payload: Data("{}".utf8), payloadVersion: 1)
        let other = PresetItem(kind: .effect, name: "fx", payload: Data("{}".utf8), payloadVersion: 1)
        #expect(KeystoneLibrary.keystones(from: [junk, other]).count == shown.count)
    }

    @Test func keystoneRoundTripsThroughPresetFile() throws {
        let k = mine("Spin")
        let back = try PresetFile.decode(try PresetFile.encode(try KeystoneLibrary.presetItem(for: k)))
        #expect(back.kind == .keystone)
        let decoded = try Keystone(payload: back.payload, version: back.payloadVersion)
        #expect(decoded.duration == k.duration && decoded.rotation == k.rotation)
    }

    @Test func damagedKeystoneFileIsRejected() throws {
        let file: [String: Any] = ["format": PresetFile.formatName, "formatVersion": 1, "kind": "keystone", "name": "x",
                                   "payloadVersion": 1, "payload": ["nope": 1]]
        let data = try JSONSerialization.data(withJSONObject: file)
        #expect(throws: PresetFileError.damagedPayload) { try PresetFile.decode(data) }
    }

    @Test func storeKeepsKeystones() async throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let store = try PresetStore(applicationSupport: dir.url)
        try await store.add(try KeystoneLibrary.presetItem(for: mine()))
        let reopened = try PresetStore(applicationSupport: dir.url)
        #expect(KeystoneLibrary.keystones(from: await reopened.presets(kind: .keystone)).last?.name == "Mine")
    }
}
