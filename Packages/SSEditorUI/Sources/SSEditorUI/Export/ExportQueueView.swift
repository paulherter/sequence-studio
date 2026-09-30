import SwiftUI
import SSExport

/// Export queue list (4c). Shown in the title-bar tasks popover.
public struct ExportQueueView: View {
    let model: ExportQueueModel

    public init(model: ExportQueueModel) { self.model = model }

    public var body: some View {
        VStack(spacing: 0) {
            if model.jobs.isEmpty {
                Text("No exports").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                List(model.jobs, id: \.id) { job in row(job) }
                    .listStyle(.plain)
                    .frame(minHeight: 100, maxHeight: 320)
                Divider()
                HStack {
                    Spacer()
                    Button("Clear Finished") { model.clearFinished() }
                        .disabled(!model.jobs.contains { ExportQueueModel.isFinished($0.state) })
                }
                .padding(8)
            }
        }
        .frame(width: 340)
        .task { model.start() }
    }

    private func row(_ job: ExportQueueModel.Row) -> some View {
        HStack(spacing: 8) {
            icon(job.state)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.name).lineLimit(1)
                switch job.state {
                case .running:
                    ProgressView(value: job.progress)
                case .waiting:
                    Text(ExportQueueModel.stateText(job.state)).font(.caption).foregroundStyle(.secondary)
                default:
                    Text(ExportQueueModel.stateText(job.state)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            switch job.state {
            case .waiting, .running:
                Button { model.cancel(job.id) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).help("Stop")
            case .done:
                Button { model.reveal(job) } label: { Image(systemName: "magnifyingglass.circle.fill") }
                    .buttonStyle(.borderless).help("Show in Finder")
            default:
                EmptyView()
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private func icon(_ s: ExportJobState) -> some View {
        switch s {
        case .waiting: Image(systemName: "clock").foregroundStyle(.secondary)
        case .running: Image(systemName: "arrow.up.circle").foregroundStyle(.tint)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
        case .cancelled: Image(systemName: "stop.circle").foregroundStyle(.secondary)
        }
    }
}
