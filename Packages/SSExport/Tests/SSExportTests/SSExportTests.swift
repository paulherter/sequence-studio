import Testing
@testable import SSExport

@Test func moduleLoads() { #expect(SSExportModule.name == "SSExport") }
