import Testing
@testable import SSCore

@Test func moduleLoads() { #expect(SSCoreModule.name == "SSCore") }
