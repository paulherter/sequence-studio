#if canImport(Metal)
import Foundation
import Metal
import Testing
@testable import SQRender

/// Q-PERF2 rec 5: the free intermediate pool can be trimmed (memory pressure, idle); oldest go first.
@Test func intermediatePoolTrimsOldestFirst() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { return }
    let comp = try Compositor(device: device)
    let one = 256 * 256 * 8
    let texs = (0..<4).compactMap { _ in comp.acquireIntermediate(width: 256, height: 256) }
    comp.releaseIntermediates(texs)
    #expect(comp.freeIntermediateBytes == 4 * one)
    comp.trimIntermediatePool(toBytes: 2 * one + 1)
    #expect(comp.freeIntermediateBytes == 2 * one)
    let again = comp.acquireIntermediate(width: 256, height: 256)
    #expect(again === texs[2] || again === texs[3])                       // the newest two were kept
    comp.trimIntermediatePool(toBytes: 0)
    #expect(comp.freeIntermediateBytes == 0)
    let before = comp.intermediateAllocations
    _ = comp.acquireIntermediate(width: 256, height: 256)
    #expect(comp.intermediateAllocations == before + 1)
}
#endif
