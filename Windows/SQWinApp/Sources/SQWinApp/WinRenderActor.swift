import Foundation
import SQGPUD3D12

/// Where export frame sources render: off the main thread, so the Export sheet's picture and a running export never
/// hold up the window (the first preview frame used to stall it ~0.8 s). One serial actor with its own D3D12 device:
/// the shim records one command list per device at a time, and the main thread's device belongs to the Program engine
/// and the UI renderer. Work on this actor may interleave at its awaits; no command list stays open across one
/// (`WinCompositor.render` records and commits in one synchronous call).
@globalActor actor WinRenderActor {
    static let shared = WinRenderActor()
}

/// The render actor's D3D12 device, made on first use (on the actor) and kept for the app's life.
@WinRenderActor enum WinRenderDevice {
    private static var made: Result<D3D12GPUDevice, any Error>?

    static func get() throws -> D3D12GPUDevice {
        if let made { return try made.get() }
        let r = Result { try D3D12GPUDevice() }
        made = r
        return try r.get()
    }
}
