import CSQWinApp
import Foundation
import WinSDK

/// Result of `--dialog-test`: the window kept answering while the folder dialog was open, and the dialog closed.
@MainActor var dialogTestPassed = false

/// What the probe thread saw while the dialog was open.
private final class DialogProbe: @unchecked Sendable {
    let lock = NSLock()
    var answered = 0, timedOut = 0, closed = false
    let done = DispatchSemaphore(value: 0)
}

/// `--dialog-test`: opens the folder dialog on the UI thread (the Reconnect Media path). Another thread asks the main
/// window three times whether it answers (SendMessageTimeout, SMTO_ABORTIFHUNG, as Windows' "Not responding" check),
/// then closes the dialog. A hung UI thread (the MTA wait of the old build) shows as timeouts.
@MainActor func runDialogTest(_ owner: HWND) {
    print("dialog test: UI thread \(sq_com_is_sta() == 1 ? "STA" : "MTA")")
    let probe = DialogProbe()
    let raw = Int(bitPattern: owner)
    Thread.detachNewThread {
        guard let window = HWND(bitPattern: raw) else { probe.done.signal(); return }
        Thread.sleep(forTimeInterval: 1.0)
        for _ in 0..<3 {
            var result: DWORD_PTR = 0
            let ok = SendMessageTimeoutW(window, UINT(WM_NULL), 0, 0, UINT(SMTO_ABORTIFHUNG), 1000, &result) != 0
            probe.lock.lock(); if ok { probe.answered += 1 } else { probe.timedOut += 1 }; probe.lock.unlock()
            Thread.sleep(forTimeInterval: 0.2)
        }
        for _ in 0..<50 {
            if let dialog = GetWindow(window, UINT(GW_ENABLEDPOPUP)) {
                PostMessageW(dialog, UINT(WM_CLOSE), 0, 0)
                probe.lock.lock(); probe.closed = true; probe.lock.unlock()
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        probe.done.signal()
    }
    let started = Date()
    let picked = WinFilePicker.dialog(owner, mode: Int32(SQ_FILE_DIALOG_FOLDER), title: "Dialog test", filter: [])
    probe.done.wait()
    probe.lock.lock(); let answered = probe.answered, timedOut = probe.timedOut, closed = probe.closed; probe.lock.unlock()
    dialogTestPassed = answered == 3 && timedOut == 0 && closed
    print(String(format: "dialog test: open %.1f s, window answered %d of 3, %d timeouts, dialog closed: %@, picked %d -> %@",
                 Date().timeIntervalSince(started), answered, timedOut, closed ? "yes" : "no", picked.count,
                 dialogTestPassed ? "ok" : "FAIL"))
}
