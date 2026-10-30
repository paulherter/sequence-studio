#if canImport(CryptoKit)
import CryptoKit
#endif
import Foundation
import Testing
@testable import SQCore

// v67: Fast Cut (`Timeline.editMode`, `Clip.attachment`). Normal-only projects are written exactly as the v66 build wrote
// them (apart from the writing build's `appFormat`); a Fast Cut sequence or any attachment makes the file v67, which a v66
// build refuses.

/// A fixed Normal-mode project (fixed ids) with a main track, a linked b-roll pair, a title on V2, a nested sequence and a
/// transition: what every Normal-only project looks like on disk.
func v67FixtureProject() -> Project {
    func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }
    let fd = Time(1, 30)
    let a = Clip(id: id(1), name: "A", media: id(100), kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)),
                 start: .zero, link: id(50), mediaDuration: Time(20, 1))
    let aSound = Clip(id: id(2), name: "A", media: id(100), kind: .audio, source: TimeRange(start: .zero, duration: Time(4, 1)),
                      start: .zero, link: id(50), mediaDuration: Time(20, 1))
    let b = Clip(id: id(3), name: "B", media: id(101), kind: .video, source: TimeRange(start: Time(2, 1), duration: Time(3, 1)),
                 start: Time(4, 1), mediaDuration: Time(20, 1))
    let title = Clip(id: id(4), name: "T", media: id(102), kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)),
                     start: Time(5, 1), mediaDuration: Time(10, 1))
    let roll = Clip(id: id(5), name: "R", media: id(103), kind: .video, source: TimeRange(start: .zero, duration: Time(1, 1)),
                    start: Time(1, 1), link: id(51), mediaDuration: Time(10, 1))
    let rollSound = Clip(id: id(6), name: "R", media: id(103), kind: .audio, source: TimeRange(start: .zero, duration: Time(2, 1)),
                         start: Time(1, 1), link: id(51), mediaDuration: Time(10, 1))
    let v1 = Track(id: id(10), kind: .video, clips: [a, b], isTargeted: true,
                   transitions: [Transition(id: id(60), kind: .crossDissolve, duration: Time(1, 1), outgoing: id(1), incoming: id(3))])
    let v2 = Track(id: id(11), kind: .video, clips: [roll, title])
    let a1 = Track(id: id(12), kind: .audio, clips: [aSound], isTargeted: true)
    let a2 = Track(id: id(13), kind: .audio, clips: [rollSound])
    let top = Timeline(id: id(20), name: "Sequence 01", format: SequenceFormat(width: 1920, height: 1080, frameDuration: fd),
                       tracks: [v1, v2, a1, a2])
    let inner = Timeline(id: id(21), name: "Nested", format: SequenceFormat(width: 1920, height: 1080, frameDuration: fd),
                         tracks: [Track(id: id(14), kind: .video)])
    return Project(id: id(30), name: "Fixture", timelines: [top, inner])
}

/// SHA-256 of `ProjectFile.encode(v67FixtureProject())` as the v66 build wrote it (appFormat 66, formatVersion 36).
private let v66FixtureSHA256 = "5fff30b978ed97b5f20485de3446c44adcaba3123f0a592f46d3748cad813d2d"

#if canImport(CryptoKit)
private func sha256(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
#else
/// Plain SHA-256 for platforms without CryptoKit (Linux).
private func sha256(_ d: Data) -> String {
    let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2]
    var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
    var msg = [UInt8](d)
    let bitLen = UInt64(msg.count) * 8
    msg.append(0x80)
    while msg.count % 64 != 56 { msg.append(0) }
    for i in (0..<8).reversed() { msg.append(UInt8((bitLen >> (UInt64(i) * 8)) & 0xff)) }
    func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
    for chunk in stride(from: 0, to: msg.count, by: 64) {
        var w = [UInt32](repeating: 0, count: 64)
        for i in 0..<16 {
            let o = chunk + i * 4
            w[i] = UInt32(msg[o]) << 24 | UInt32(msg[o + 1]) << 16 | UInt32(msg[o + 2]) << 8 | UInt32(msg[o + 3])
        }
        for i in 16..<64 {
            let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
            let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }
        var v = h
        for i in 0..<64 {
            let s1 = rotr(v[4], 6) ^ rotr(v[4], 11) ^ rotr(v[4], 25)
            let ch = (v[4] & v[5]) ^ (~v[4] & v[6])
            let t1 = v[7] &+ s1 &+ ch &+ k[i] &+ w[i]
            let s0 = rotr(v[0], 2) ^ rotr(v[0], 13) ^ rotr(v[0], 22)
            let maj = (v[0] & v[1]) ^ (v[0] & v[2]) ^ (v[1] & v[2])
            v = [t1 &+ s0 &+ maj, v[0], v[1], v[2], v[3] &+ t1, v[4], v[5], v[6]]
        }
        for i in 0..<8 { h[i] = h[i] &+ v[i] }
    }
    return h.map { String(format: "%08x", $0) }.joined()
}
#endif

private func json(_ d: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: d) as? [String: Any])
}

@Suite struct ProjectFileV67Tests {
    @Test func versionConstant() {
        #expect(ProjectFile.v67Version == 67)
        #expect(ProjectFile.currentVersion >= 67)
    }

    /// Normal-only projects: the bytes a v66 build wrote, apart from the writing build's `appFormat`.
    @Test func normalProjectIsByteIdenticalToV66Output() throws {
        let p = v67FixtureProject()
        #expect(!p.containsV67Content)
        let data = try ProjectFile.encode(p)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("editMode") && !text.contains("attachment"))
        let asV66 = text.replacingOccurrences(of: "\"appFormat\" : \(ProjectFile.currentVersion),", with: "\"appFormat\" : 66,")
        #expect(sha256(Data(asV66.utf8)) == v66FixtureSHA256)
        // Decode and encode again (direct and through the migration chain): still the same bytes.
        #expect(try ProjectFile.encode(try ProjectFile.decode(data, migrations: nil)) == data)
        #expect(try ProjectFile.encode(try ProjectFile.decode(data, migrations: ProjectFile.migrations)) == data)
    }

    /// Back to Normal without attachments: nothing of the mode is left behind.
    @Test func modeBackToNormalWithoutAttachmentsIsByteIdentical() throws {
        let p = v67FixtureProject()
        var q = p
        q.timelines[0].editMode = .magnetic
        q.timelines[0].editMode = .normal
        #expect(try ProjectFile.encode(q) == ProjectFile.encode(p))
    }

    @Test func fastCutSequenceWritesV67AndRoundTrips() throws {
        var p = v67FixtureProject()
        try p.setEditMode(.magnetic, of: p.timelines[0].id)
        #expect(p.containsV67Content)
        #expect(ProjectFile.writtenVersion(for: p) == 67)
        let data = try ProjectFile.encode(p)
        let obj = try json(data)
        #expect(obj["formatVersion"] as? Int == 67)
        #expect(obj["appFormat"] as? Int == ProjectFile.currentVersion)
        let back = try ProjectFile.decode(data, migrations: nil)
        #expect(back == p)
        #expect(back.timelines[0].editMode == .magnetic)
        #expect(back.timelines[1].editMode == .normal)
        #expect(back.timelines[0].tracks.flatMap(\.clips).contains { $0.attachment != nil })
        #expect(try ProjectFile.encode(back) == data)
        #expect(try ProjectFile.decode(data, migrations: ProjectFile.migrations) == p)
    }

    /// An attachment alone (a Normal sequence that was in Fast Cut before) also needs v67.
    @Test func attachmentAloneWritesV67() throws {
        var p = v67FixtureProject()
        p.timelines[0].setEditMode(.magnetic)
        p.timelines[0].setEditMode(.normal)
        #expect(p.timelines[0].editMode == .normal)
        #expect(p.containsV67Content)
        #expect(ProjectFile.writtenVersion(for: p) == 67)
        let data = try ProjectFile.encode(p)
        #expect(!String(decoding: data, as: UTF8.self).contains("editMode"))
        #expect(try ProjectFile.decode(data, migrations: nil) == p)
    }

    @Test func nestedSequenceInFastCutGatesToo() {
        var p = v67FixtureProject()
        p.timelines[1].editMode = .magnetic
        #expect(p.containsV67Content)
        #expect(ProjectFile.writtenVersion(for: p) == 67)
    }

    @Test func v67WinsOverOlderGates() {
        var p = v67FixtureProject()
        p.timelines[0].masterVolumeDB = -6
        #expect(ProjectFile.writtenVersion(for: p) == 66)
        p.timelines[0].editMode = .magnetic
        #expect(ProjectFile.writtenVersion(for: p) == 67)
    }

    @Test func v66FileStillOpens() throws {
        let p = v67FixtureProject()
        var obj = try json(try ProjectFile.encode(p))
        obj["formatVersion"] = 66
        obj["appFormat"] = 66
        let back = try ProjectFile.decode(try JSONSerialization.data(withJSONObject: obj), migrations: ProjectFile.migrations)
        #expect(back == p)
        #expect(back.timelines.allSatisfy { $0.editMode == .normal })
    }

    /// What a v66 build does with a v67 file: the file says 67, past the v66 reader, which refuses it like every newer
    /// version (shown here one version past this build).
    @Test func olderReaderRefusesV67File() throws {
        var p = v67FixtureProject()
        p.timelines[0].setEditMode(.magnetic)
        var obj = try json(try ProjectFile.encode(p))
        #expect(obj["formatVersion"] as? Int == 67)
        #expect(ProjectFile.writtenVersion(for: p) == 67)
        #expect(ProjectFile.writtenVersion(for: v67FixtureProject()) < 67)
        obj["formatVersion"] = ProjectFile.currentVersion + 1
        let newer = try JSONSerialization.data(withJSONObject: obj)
        #expect(throws: ProjectFileError.newerVersion(found: ProjectFile.currentVersion + 1, supported: ProjectFile.currentVersion)) {
            _ = try ProjectFile.decode(newer, migrations: ProjectFile.migrations)
        }
        #expect(throws: ProjectFileError.newerVersion(found: ProjectFile.currentVersion + 1, supported: ProjectFile.currentVersion)) {
            _ = try ProjectFile.decode(newer, migrations: nil)
        }
    }

    /// Saving over a file a v66 build wrote keeps a backup of it, like every earlier version step.
    @Test func savingOverAV66FileBacksItUp() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("v67-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let pkg = dir.appendingPathComponent("P.\(ProjectFile.fileExtension)")
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        var obj = try json(try ProjectFile.encode(v67FixtureProject()))
        obj["appFormat"] = 66
        try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
            .write(to: pkg.appendingPathComponent(ProjectFile.fileName))
        var p = v67FixtureProject()
        p.timelines[0].setEditMode(.magnetic)
        try ProjectFile.write(p, to: pkg)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("P.\(ProjectFile.fileExtension).v36.bak").path))
        #expect(try ProjectFile.read(from: pkg) == p)
    }

    /// An unknown future edit mode opens as Normal instead of failing the whole file.
    @Test func unknownEditModeDecodesAsNormal() throws {
        var obj = try json(try JSONEncoder().encode(Timeline(name: "S", frameDuration: Time(1, 30))))
        obj["editMode"] = "storyline"
        let t = try JSONDecoder().decode(Timeline.self, from: try JSONSerialization.data(withJSONObject: obj))
        #expect(t.editMode == .normal)
    }
}
