import Testing
@testable import SQCore

@Suite struct ProjectLaunchPathTests {
    @Test func acceptsAnyCaseAndLegacy() {
        #expect(ProjectFile.launchProjectPath("C:\\a\\Film.SQPROJ") == "C:\\a\\Film.SQPROJ")
        #expect(ProjectFile.launchProjectPath("C:\\a\\Old.ssproj") == "C:\\a\\Old.ssproj")
        #expect(ProjectFile.launchProjectPath("/x/Old.SsProj") == "/x/Old.SsProj")
    }
    @Test func dropsTrailingSlashesAndQuotes() {
        #expect(ProjectFile.launchProjectPath("C:\\My Films\\Film.sqproj\\") == "C:\\My Films\\Film.sqproj")
        #expect(ProjectFile.launchProjectPath("/x/Film.sqproj//") == "/x/Film.sqproj")
        #expect(ProjectFile.launchProjectPath("\"C:\\My Films\\Film.sqproj\"") == "C:\\My Films\\Film.sqproj")
        #expect(ProjectFile.launchProjectPath("  'C:/My Films/Film.sqproj/' ") == "C:/My Films/Film.sqproj")
    }
    @Test func rejectsOthers() {
        #expect(ProjectFile.launchProjectPath("") == nil)
        #expect(ProjectFile.launchProjectPath("--render-frame") == nil)
        #expect(ProjectFile.launchProjectPath("clip.mov") == nil)
        #expect(ProjectFile.launchProjectPath("C:\\a.sqproj\\project.json") == nil)
        #expect(ProjectFile.launchProjectPath(".sqproj") == nil)
    }
    @Test func firstMatchInArguments() {
        #expect(ProjectFile.launchProjectPath(in: ["--x", "a.mov", "\"b c.SQPROJ\"", "d.sqproj"]) == "b c.SQPROJ")
        #expect(ProjectFile.launchProjectPath(in: []) == nil)
    }
}
