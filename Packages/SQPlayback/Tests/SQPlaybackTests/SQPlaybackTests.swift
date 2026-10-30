import Testing
@testable import SQPlayback

@Test func moduleLoads() { #expect(SQPlaybackModule.name == "SQPlayback") }
