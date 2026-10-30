import Foundation
import Testing
@testable import SQEditorSession

@Suite struct UpdateCheckTests {
    private static func json(_ v: String, url: String = "https://example.org/dl") -> Data {
        Data("{\"version\":\"\(v)\",\"url\":\"\(url)\"}".utf8)
    }

    @Test func versionOrder() {
        #expect(UpdateCheck.isNewer("1.2.0", than: "1.1.9"))
        #expect(UpdateCheck.isNewer("v1.10", than: "1.9.3"))
        #expect(!UpdateCheck.isNewer("1.2", than: "1.2.0"))
        #expect(!UpdateCheck.isNewer("1.1", than: "1.2"))
        #expect(!UpdateCheck.isNewer("beta", than: "1.0"))
        #expect(UpdateCheck.isNewer("2.0.0-rc1", than: "1.9"))
    }

    @Test func outcomes() {
        #expect(UpdateCheck.outcome(data: Self.json("1.0.1"), localVersion: "1.0.0")
                == .available(.init(version: "1.0.1", url: "https://example.org/dl", notes: nil)))
        #expect(UpdateCheck.outcome(data: Self.json("1.0.0"), localVersion: "1.0.0") == .upToDate)
        #expect(UpdateCheck.outcome(data: Data("nope".utf8), localVersion: "1.0.0") == .failed)
        #expect(UpdateCheck.outcome(data: Self.json("2.0", url: "http://insecure"), localVersion: "1.0") == .failed)
    }

    private static let github = Data("""
    {"tag_name":"v1.4.0","html_url":"https://github.com/paulherter/sequence-studio/releases/tag/v1.4.0","body":" Fixes ",
     "assets":[{"name":"SequenceStudio-1.4.0.dmg","browser_download_url":"https://example.org/a.dmg"},
               {"name":"SequenceStudio-Setup-1.4.0.EXE","browser_download_url":"https://example.org/Setup.exe"}]}
    """.utf8)

    @Test func githubReleaseUsesInstallerAssetOfThisSystem() {
        let exe = UpdateCheck.githubRelease(from: Self.github, suffix: ".exe")
        #expect(exe == .init(version: "v1.4.0", url: "https://example.org/Setup.exe", notes: "Fixes"))
        #expect(UpdateCheck.githubRelease(from: Self.github, suffix: ".dmg")?.url == "https://example.org/a.dmg")
        #expect(UpdateCheck.githubRelease(from: Self.github, suffix: ".zip")?.url == "https://github.com/paulherter/sequence-studio/releases/tag/v1.4.0")
        #expect(UpdateCheck.outcome(data: Self.github, localVersion: "1.3.9") != .failed)
        #expect(UpdateCheck.outcome(data: Self.github, localVersion: "1.4.0") == .upToDate)
        #expect(UpdateCheck.githubRelease(from: Data("{\"message\":\"Not Found\"}".utf8)) == nil)
    }

    @Test func defaultAddressIsGitHubReleasesAndCanBeSwitchedOff() {
        #expect(UpdateCheck.defaultFeedURL == "https://api.github.com/repos/paulherter/sequence-studio/releases/latest")
        #expect(UpdateCheck.feedURL == UpdateCheck.defaultFeedURL || ProcessInfo.processInfo.environment["SQ_UPDATE_URL"] != nil)
    }

    @Test func emptyAddressIsInertAndNeverFetches() async {
        let o = await UpdateCheck.check(localVersion: "1.0", feed: "", fetch: { _ in Issue.record("fetched"); return Data() })
        #expect(o == .notConfigured)
    }

    @Test func fetchesConfiguredAddress() async {
        let o = await UpdateCheck.check(localVersion: "1.0", feed: "https://example.org/u.json", fetch: { _ in Self.json("1.1") })
        if case .available(let r) = o { #expect(r.version == "1.1") } else { Issue.record("not available") }
    }

    @Test func settingsFlagsPersist() throws {
        let suite = "sq.test.updatecheck.\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        var s = AppSettings.load(from: d)
        #expect(s.checkForUpdates && !s.onboardingSeen)
        s.checkForUpdates = false; s.onboardingSeen = true
        s.save(to: d)
        let back = AppSettings.load(from: d)
        #expect(!back.checkForUpdates && back.onboardingSeen)
    }
}
