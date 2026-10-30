import Foundation
import SQExport
import SQUIKit

/// The status bar's export ring opens the queue (the Mac `ExportQueueView` popover, as an SQ menu): a header, then per
/// job its name and state; a waiting or running job offers Cancel, a finished one its file in Finder/Explorer.
/// `showExportQueue` now opens `ExportQueuePopover` (live bars); the menu rows stay for `exportQueueItems` tests.
extension ShellHost {
    /// One queue job as the menu shows it (`ExportJobStatus` has no public init, so tests build these).
    public typealias ExportQueueJob = (id: UUID, name: String, state: ExportJobState, progress: Double)

    /// The queue rows for `statuses` (pure, tested).
    public func exportQueueItems(_ statuses: [ExportQueueJob]) -> [SQMenuItem] {
        var rows: [SQMenuItem] = [.header("Export Queue")]
        guard !statuses.isEmpty else { return rows + [.caption("No exports yet")] }
        #if os(Windows)
        let reveal = "Show in Explorer"
        #else
        let reveal = "Reveal in Finder"
        #endif
        for s in statuses {
            let state: String
            var sub: [SQMenuItem] = []
            switch s.state {
            case .waiting: state = "Waiting"
            case .running: state = "\(Int((s.progress * 100).rounded())) %"
            case .done: state = "Done"
            case .failed(let why): state = "Failed: \(why)"
            case .cancelled: state = "Canceled"
            }
            switch s.state {
            case .waiting, .running:
                let id = s.id
                sub.append(SQMenuItem(title: "Cancel", action: { [weak self] in
                    guard let q = self?.exportQueue else { return }
                    Task { await q.cancel(id) }
                }))
            case .done(let url):
                sub.append(SQMenuItem(title: reveal, isEnabled: revealFile != nil, action: { [weak self] in self?.revealFile?(url) }))
            default: break
            }
            var row = SQMenuItem(title: "\(s.name) — \(state)", isEnabled: !sub.isEmpty)
            if !sub.isEmpty { row.submenu = sub }
            rows.append(row)
        }
        return rows
    }

    /// Opens the queue popover above `p` (window points, the status bar's ring); it refreshes while open. A second click
    /// on the ring closes it (the press lands outside the popover).
    public func showExportQueue(at p: CGPoint) {
        guard queuePopover == nil else { queuePopover = nil; return }
        let pop = ExportQueuePopover(anchor: p)
        #if os(Windows)
        pop.revealTitle = "Show in Explorer"
        #else
        pop.revealTitle = "Reveal in Finder"
        #endif
        pop.canReveal = revealFile != nil
        pop.onClose = { [weak self] in self?.queuePopover = nil }
        pop.onReveal = { [weak self] url in self?.revealFile?(url) }
        let queue = exportQueue
        pop.onCancelBackground = { [weak self] id in self?.cancelBackgroundJob?(id) }
        pop.onCancel = { id in guard let q = queue else { return }; Task { await q.cancel(id) } }
        queuePopover = pop
        menuBar.controller.dismiss()
        refreshQueuePopover(pop)
        guard let queue else {
            spawn { [weak self, weak pop] in
                while let self, let pop, self.queuePopover === pop {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    pop.update(pop.jobs, background: await self.backgroundJobs?() ?? [])
                    pop.layout(in: CGRect(origin: .zero, size: self.size))
                }
            }
            return
        }
        spawn { [weak self, weak pop] in
            while let self, let pop, self.queuePopover === pop {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard self.queuePopover === pop else { return }
                let all = await queue.allStatuses().map { ExportQueuePopover.Job(id: $0.id, name: $0.name, state: $0.state, progress: $0.progress) }
                pop.update(all, background: await self.backgroundJobs?() ?? [])
                pop.layout(in: CGRect(origin: .zero, size: self.size))
            }
        }
    }

    private func refreshQueuePopover(_ pop: ExportQueuePopover) {
        guard let queue = exportQueue else {
            spawn { [weak self, weak pop] in
                guard let self, let pop else { return }
                pop.update(pop.jobs, background: await self.backgroundJobs?() ?? [])
                pop.layout(in: CGRect(origin: .zero, size: self.size))
            }
            return
        }
        spawn { [weak self, weak pop] in
            let all = await queue.allStatuses().map { ExportQueuePopover.Job(id: $0.id, name: $0.name, state: $0.state, progress: $0.progress) }
            guard let self, let pop else { return }
            pop.update(all, background: await self.backgroundJobs?() ?? [])
            pop.layout(in: CGRect(origin: .zero, size: self.size))
        }
    }
}
