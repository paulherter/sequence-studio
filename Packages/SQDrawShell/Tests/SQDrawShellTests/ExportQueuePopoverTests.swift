import Foundation
import Testing
import SQDrawKit
import SQExport
import SQUIKit
@testable import SQDrawShell

@MainActor @Suite struct ExportQueuePopoverTests {
    static let window = CGRect(x: 0, y: 0, width: 1000, height: 700)
    static func jobs() -> [ExportQueuePopover.Job] {
        [.init(id: UUID(), name: "Cut A", state: .done(URL(fileURLWithPath: "/tmp/a.mp4")), progress: 1),
         .init(id: UUID(), name: "Cut B", state: .running, progress: 0.4),
         .init(id: UUID(), name: "Cut C", state: .waiting, progress: 0)]
    }
    static func make() -> ExportQueuePopover {
        let p = ExportQueuePopover(anchor: CGPoint(x: 980, y: 690))
        p.update(jobs())
        p.layout(in: window)
        return p
    }

    @Test func opensAboveTheRingInsideTheWindow() {
        let p = Self.make()
        #expect(p.frame.maxY <= 690 && p.frame.minX >= 8 && p.frame.maxX <= 992)
        #expect(p.frame.width == ExportQueuePopover.width)
    }

    @Test func clearFinishedHidesOnlyFinishedJobsAndStaysHidden() {
        let p = Self.make()
        let all = p.jobs
        p.clearFinished()
        #expect(p.jobs.map(\.name) == ["Cut B", "Cut C"])
        p.update(all)                                  // the queue still reports the done job
        #expect(p.jobs.map(\.name) == ["Cut B", "Cut C"])
    }

    @Test func theActionButtonsCancelAndReveal() {
        let p = Self.make()
        var canceled: UUID?, revealed: URL?
        p.onCancel = { canceled = $0 }
        p.onReveal = { revealed = $0 }
        let x = Float(p.frame.maxX - 22)
        func click(row: Int) {
            let y = Float(p.frame.minY + CGFloat(row) * ExportQueuePopover.rowHeight + 24)
            _ = p.handle(.mouseDown(x: x, y: y, modifiers: []), scale: 1)
        }
        click(row: 0); #expect(revealed?.lastPathComponent == "a.mp4")
        click(row: 1); #expect(canceled == p.jobs[1].id)
    }

    @Test func aPressOutsideOrEscapeCloses() {
        let p = Self.make()
        var closed = 0
        p.onClose = { closed += 1 }
        #expect(p.handle(.mouseDown(x: 5, y: 5, modifiers: []), scale: 1))
        #expect(p.handle(.keyDown(.escape, modifiers: []), scale: 1))
        #expect(closed == 2)
    }

    @Test func drawsABarForTheRunningJob() {
        let p = Self.make()
        var c = Canvas(width: 1000, height: 700, atlas: nil, scale: 1)
        let before = c.list.quads.count
        p.draw(&c, theme: DrawTheme())
        #expect(c.list.quads.count > before)
    }

    @Test func backgroundJobsSitAboveTheListAndCancel() {
        let p = Self.make()
        let plain = p.frame.height
        var canceled: String?
        p.onCancelBackground = { canceled = $0 }
        p.update(p.jobs, background: [.init(id: "proxy-1", title: "Proxy: a.mov", progress: 0.4)])
        p.layout(in: CGRect(x: 0, y: 0, width: 1000, height: 700))
        #expect(p.frame.height == plain + ExportQueuePopover.backgroundRowHeight + 9)
        let x = Float(p.frame.maxX - 22), y = Float(p.frame.minY + 4 + ExportQueuePopover.backgroundRowHeight / 2)
        _ = p.handle(.mouseDown(x: x, y: y, modifiers: []), scale: 1)
        #expect(canceled == "proxy-1")
        // The first export row is now lower by the section height.
        var revealed: URL?
        p.onReveal = { revealed = $0 }
        let ry = Float(p.frame.minY + p.frame.height - plain + 24)
        _ = p.handle(.mouseDown(x: x, y: ry, modifiers: []), scale: 1)
        #expect(revealed?.lastPathComponent == "a.mp4")
    }

    @Test func pipDrawsForRunningDoneAndFailedRows() {
        var c = Canvas(width: 100, height: 100, atlas: nil, scale: 1)
        for a in [SQMascotAnim.work, .cheer, .oops, .sad] {
            let before = c.list.quads.count
            ShellMascot.draw(a, in: CGRect(x: 10, y: 10, width: 28, height: 28), into: &c)
            #expect(c.list.quads.count > before)
        }
        #expect(ExportQueuePopover.pipAnimation(.waiting) == nil)
        #expect(ExportQueuePopover.pipAnimation(.running) == .work)
    }
}
