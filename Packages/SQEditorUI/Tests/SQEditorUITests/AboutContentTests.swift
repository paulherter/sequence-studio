import Foundation
import Testing
@testable import SQEditorUI
import SQUIKit

@Suite struct AboutContentTests {
    @Test func discordOnlyWithInvite() {
        #expect(AboutContent.links(discord: nil) == [.github, .support])
        #expect(AboutContent.links(discord: URL(string: "https://discord.gg/x")) == [.github, .support, .discord])
    }
    @Test func noDonationWordingAndNoWebsite() {
        let all = AboutContent.links(discord: URL(string: "https://x.y")).map(\.title).joined(separator: " ") + AboutContent.tagline
        #expect(!all.lowercased().contains("donat"))
        #expect(!all.lowercased().contains("website"))
    }
    @Test func acknowledgmentsAreComplete() {
        #expect(AboutContent.acknowledgments.count == 8)
        #expect(AboutContent.acknowledgments.allSatisfy { !$0.name.isEmpty && !$0.license.isEmpty })
    }
}
