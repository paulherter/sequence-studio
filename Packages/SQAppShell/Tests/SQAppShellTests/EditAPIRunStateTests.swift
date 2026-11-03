import Testing
@testable import SQAppShell

@Suite struct EditAPIRunStateTests {
    @Test func editAPIStateText() {
        #expect(EditAPIRunState.notRunning.text == "Not running")
        #expect(EditAPIRunState.listening(port: 8731).text == "Listening on 127.0.0.1, port 8731")
        #expect(EditAPIRunState.portInUse(port: 8731).text.hasPrefix("Port in use"))
        #expect(EditAPIRunState.notRunning.tone == .idle)
        #expect(EditAPIRunState.listening(port: 1).tone == .ok)
        #expect(EditAPIRunState.portInUse(port: 1).tone == .warning)
        #expect(EditAPIRunState.listening(port: 8731).copyablePort == 8731)
        #expect(EditAPIRunState.listeningNoFile(port: 9).copyablePort == 9)
        #expect(EditAPIRunState.notRunning.copyablePort == nil)
        #expect(EditAPIRunState.portInUse(port: 8731).copyablePort == nil)
    }
}
