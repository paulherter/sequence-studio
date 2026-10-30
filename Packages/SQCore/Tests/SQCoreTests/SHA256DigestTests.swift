import Foundation
import Testing
@testable import SQCore

@Suite struct SHA256DigestTests {
    // FIPS 180-2 vectors.
    @Test func knownVectors() {
        #expect(SHA256Digest.hex(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(SHA256Digest.hex(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(SHA256Digest.hex(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8))
                == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    /// The portable code (the Windows path) gives the same digest as the system one for every padding boundary.
    @Test func portableMatchesSystem() {
        for n in [0, 1, 55, 56, 63, 64, 65, 119, 120, 1000, 100_003] {
            let d = Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
            #expect(SHA256Digest.portable([UInt8](d)) == SHA256Digest.hash(d), "length \(n)")
        }
        let million = [UInt8](repeating: UInt8(ascii: "a"), count: 1_000_000)
        #expect(SHA256Digest.portable(million).map { String(format: "%02x", $0) }.joined()
                == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    /// A digest fed in pieces (any split, also across the 64-byte blocks) equals the one-shot digest, on both paths.
    @Test func streamedDigestEqualsOneShot() {
        let d = Data((0..<10_007).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 5) })
        for step in [1, 7, 63, 64, 65, 4096, 10_007] {
            var system = SHA256Digest.Stream(), portable = SHA256Digest.PortableStream()
            var i = 0
            while i < d.count {
                let piece = d.subdata(in: i..<min(i + step, d.count))
                system.update(piece); portable.update(piece); i += step
            }
            #expect(system.finalize() == SHA256Digest.hash(d), "step \(step)")
            #expect(portable.finalize() == SHA256Digest.hash(d), "portable step \(step)")
        }
        var empty = SHA256Digest.Stream()
        #expect(empty.finalize() == SHA256Digest.hash(Data()))
    }
}
