import CSQWin
import Foundation
import SQDrawKit
import WinSDK

nonisolated(unsafe) private var gWindow: GPUWindow?

private func wide(_ s: String) -> UnsafeMutablePointer<UInt16> {
    let u = Array(s.utf16) + [0]
    let p = UnsafeMutablePointer<UInt16>.allocate(capacity: u.count)
    p.initialize(from: u, count: u.count)
    return p
}

private func wndProc(_ hwnd: HWND?, _ msg: UINT, _ wp: WPARAM, _ lp: LPARAM) -> LRESULT {
    switch msg {
    case UINT(WM_SIZE):
        gWindow?.pendingSize = (Int32(lp & 0xFFFF), Int32((lp >> 16) & 0xFFFF))
        return 0
    case UINT(WM_LBUTTONDOWN):
        SetCapture(hwnd)
        gWindow?.mouse(down: true, x: Int(Int16(truncatingIfNeeded: lp)), y: Int(Int16(truncatingIfNeeded: lp >> 16)))
        return 0
    case UINT(WM_MOUSEMOVE):
        gWindow?.mouse(down: nil, x: Int(Int16(truncatingIfNeeded: lp)), y: Int(Int16(truncatingIfNeeded: lp >> 16)))
        return 0
    case UINT(WM_LBUTTONUP):
        ReleaseCapture()
        gWindow?.dragging = false
        return 0
    case UINT(WM_CLOSE):
        DestroyWindow(hwnd)
        return 0
    case UINT(WM_DESTROY):
        PostQuitMessage(0)
        return 0
    default:
        return DefWindowProcW(hwnd, msg, wp, lp)
    }
}

/// A Win32 window with a D3D12 swap chain. Thin: all GPU work is in the C++ target.
final class GPUWindow {
    var pendingSize: (Int32, Int32)?
    private var hwnd: HWND?
    private var gpu: OpaquePointer?

    struct Options {
        var seconds: Double = 0          // 0 = until closed
        var screenshot: String?
        var resizeTest = false
        var frame: SQDecoded?
        var shaderDir: String?           // Slang-made HLSL; applied to the video frame
        var timeline = false             // draw the shared timeline strip over everything
        var dragTest = false             // post synthetic mouse messages that drag the playhead
    }

    var playhead = 150                   // frames
    var dragging = false
    private var hasTimeline = false
    private let ruler = TimelineStrip.rulerHeight

    /// Mouse on the ruler (or near the playhead line) grabs the playhead; dragging moves it.
    func mouse(down: Bool?, x: Int, y: Int) {
        guard hasTimeline else { return }
        if down == true, y < ruler || abs(x - TimelineStrip.x(forFrame: playhead)) < 8 { dragging = true }
        if dragging { playhead = TimelineStrip.frame(forX: x) }
    }

    init?(title: String, width: Int32, height: Int32) {
        let cls = wide("SQWinSpikeWindow")
        var wc = WNDCLASSEXW()
        wc.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
        wc.lpfnWndProc = wndProc
        wc.hInstance = GetModuleHandleW(nil)
        wc.hCursor = LoadCursorW(nil, UnsafePointer<UInt16>(bitPattern: 32512))  // IDC_ARROW
        wc.lpszClassName = UnsafePointer(cls)
        guard RegisterClassExW(&wc) != 0 else { return nil }
        var r = RECT(left: 0, top: 0, right: width, bottom: height)
        AdjustWindowRect(&r, DWORD(WS_OVERLAPPEDWINDOW), false)
        hwnd = CreateWindowExW(0, cls, wide(title), DWORD(WS_OVERLAPPEDWINDOW), 100, 100,
                               r.right - r.left, r.bottom - r.top, nil, nil, wc.hInstance, nil)
        guard hwnd != nil else { return nil }
        var err = [CChar](repeating: 0, count: 256)
        gpu = sq_gpu_create(hwnd, width, height, &err, 256)
        guard gpu != nil else {
            print("GPU init failed: \(String(cString: err))")
            return nil
        }
        print("adapter: \(String(cString: sq_gpu_adapter_name(gpu)))")
        gWindow = self
        ShowWindow(hwnd, SW_SHOW)
    }

    func run(_ o: Options) -> Int32 {
        if let f = o.frame, let px = f.rgba {
            if sq_gpu_set_frame_rgba(gpu, px, f.width, f.height) != 0 { print("frame upload failed") }
        }
        if let dir = o.shaderDir {
            var err = [CChar](repeating: 0, count: 512)
            if sq_gpu_set_grade(gpu, dir + "\\Grade.vs.hlsl", dir + "\\Grade.ps.hlsl", 0.5, 1.4, 0.6, &err, 512) != 0 {
                print("grade shader failed: \(String(cString: err))")
                return 1
            }
            print("grade shader (Slang -> HLSL) active")
        }
        hasTimeline = o.timeline
        let start = Date()
        var dragStep = 0
        var width: Int32 = 0, height: Int32 = 0
        var frames = 0
        var shotDone = false
        var resized = false
        var msg = MSG()
        while true {
            while PeekMessageW(&msg, nil, 0, 0, UINT(PM_REMOVE)) {
                if msg.message == UINT(WM_QUIT) { return finish(frames) }
                TranslateMessage(&msg)
                DispatchMessageW(&msg)
            }
            let t = Date().timeIntervalSince(start)
            if o.resizeTest, !resized, t > 0.5 {
                SetWindowPos(hwnd, nil, 0, 0, 1000, 560, UINT(SWP_NOMOVE | SWP_NOZORDER))
                resized = true
            }
            if let s = pendingSize {
                pendingSize = nil
                if sq_gpu_resize(gpu, s.0, s.1) != 0 { print("resize failed") }
                else { print("resized: \(s.0)x\(s.1)") }
            }
            if o.dragTest {  // synthetic input through the real window procedure
                let steps: [(Double, UINT, Int)] = [(0.2, UINT(WM_LBUTTONDOWN), 180), (0.3, UINT(WM_MOUSEMOVE), 300),
                                                    (0.4, UINT(WM_MOUSEMOVE), 450), (0.5, UINT(WM_MOUSEMOVE), 640),
                                                    (0.6, UINT(WM_LBUTTONUP), 640)]
                if dragStep < steps.count, t > steps[dragStep].0 {
                    let s = steps[dragStep]
                    PostMessageW(hwnd, s.1, s.1 == UINT(WM_LBUTTONUP) ? 0 : 1, LPARAM(s.2 | (12 << 16)))
                    dragStep += 1
                }
            }
            if o.timeline {
                var rc = RECT()
                GetClientRect(hwnd, &rc)
                width = rc.right; height = rc.bottom
                let rects = TimelineStrip.draw(width: Int(width), height: Int(height), playheadFrame: playhead).flattened()
                    .map { SQRect(x: $0.x, y: $0.y, w: $0.w, h: $0.h, r: $0.color.r, g: $0.color.g, b: $0.color.b, a: $0.color.a) }
                _ = sq_gpu_set_rects(gpu, rects, Int32(rects.count))
            }
            // Slow color pulse so a frozen window is visible.
            let k = Float(0.5 + 0.5 * sin(t * 2))
            var shot: String?
            if let p = o.screenshot, !shotDone, t > (o.resizeTest ? 1.2 : 0.8) { shot = p; shotDone = true }
            let rc = shot != nil
                ? shot!.withCString { sq_gpu_render(gpu, 0.10, 0.15 + 0.2 * k, 0.45, $0) }
                : sq_gpu_render(gpu, 0.10, 0.15 + 0.2 * k, 0.45, nil)
            if rc != 0 { print("render failed"); return 1 }
            frames += 1
            if o.seconds > 0, t > o.seconds { SendMessageW(hwnd, UINT(WM_CLOSE), 0, 0) }
        }
    }

    private func finish(_ frames: Int) -> Int32 {
        print("closed cleanly after \(frames) frames, playhead frame \(playhead)")
        sq_gpu_destroy(gpu)
        gpu = nil
        return 0
    }
}
