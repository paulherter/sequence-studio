import Foundation
import SQAppShell
import SQDrawShell
import SQRender
import SQUIKit

/// View > View Gamma on Windows: the UI renderer raises the monitor picture to gamma / 2.2 (`UIRenderer.setViewGamma`).
/// The swap chain shows code values as sRGB, so Windows starts at Web 2.2 (picture unchanged).
/// Sequence > New Shape takes the Create tool's path (`MonitorHost.createShapeAtCenter`), as on the Mac.
extension AppController {
    func configureViewOptions() {
        shell.onNewShape = { [weak self] kind in
            guard let self else { return }
            monitors.monitor.createShapeAtCenter(kind, graphics: graphics.editor)
        }
        ViewGamma.current = .web
        let next = shell.onCommand
        shell.onCommand = { c in
            guard case .viewGamma(let choice) = c, let gamma = ViewGamma(rawValue: choice.rawValue) else { return next?(c) ?? false }
            ViewGamma.current = gamma
            return true   // the window redraws after every command; the next frame picks the exponent up
        }
        shell.menuChecks.append {
            Set(ViewGammaChoice.allCases.filter { $0.rawValue == ViewGamma.current.rawValue }.map { EditorCommand.viewGamma($0) })
        }
    }
}
