import Testing
@testable import SQCore

@Test func moduleLoads() { #expect(SQCoreModule.name == "SQCore") }
