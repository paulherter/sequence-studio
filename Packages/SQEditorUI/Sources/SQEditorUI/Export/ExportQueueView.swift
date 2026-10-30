import SwiftUI
import SQExport

/// Export queue list (4c). Shown in the title-bar tasks popover.
public struct ExportQueueView: View {
    let model: ExportQueueModel
    let jobs: JobCenter?

    public init(model: ExportQueueModel, jobs: JobCenter? = nil) { self.model = model; self.jobs = jobs }

    private static let label = Color(nsColor: Theme.Colors.label)
    private static let label2 = Color(nsColor: Theme.Colors.label2)

    public var body: some View {
        VStack(spacing: 0) {
            if let others = jobs?.otherJobs, !others.isEmpty {
                VStack(spacing: 0) {
                    ForEach(others) { job in backgroundRow(job) }
                }
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.xs)
                Rectangle().fill(Color(nsColor: Theme.Separator.hairline)).frame(height: Theme.Separator.width)
            }
            if model.jobs.isEmpty {
                Text(SQL10n.string(jobs?.otherJobs.isEmpty == false ? "No exports" : "No tasks running")).font(Theme.Typography.bodyFont).foregroundStyle(Self.label2)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.jobs, id: \.id) { job in row(job) }
                    }
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, Theme.Spacing.xs)
                }
                .frame(minHeight: 100, maxHeight: 320)
                Rectangle().fill(Color(nsColor: Theme.Separator.hairline)).frame(height: Theme.Separator.width)
                HStack {
                    Spacer()
                    Button(SQL10n.string("Clear Finished")) { model.clearFinished() }
                        .buttonStyle(SQFlatButtonStyle())
                        .disabled(!model.jobs.contains { ExportQueueModel.isFinished($0.state) })
                }
                .padding(Theme.Spacing.sm)
            }
        }
        .frame(width: 340)
        .task { model.start(); jobs?.startPolling() }
    }

    /// A background job (proxy, transcription, ...): title, progress and a Cancel button.
    private func backgroundRow(_ job: BackgroundJob) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            SQIcon.settings.swiftUIImage(size: 13).foregroundStyle(Self.label2)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(job.title).font(Theme.Typography.bodyFont).foregroundStyle(Self.label).lineLimit(1)
                if let p = job.progress, p > 0 { progressBar(p) }
                else { Text(SQL10n.string("Waiting")).font(Theme.Typography.captionFont).foregroundStyle(Self.label2) }
            }
            Spacer(minLength: Theme.Spacing.xs)
            Button { job.cancel(); Task { await jobs?.refresh() } } label: { SQIcon.closeCircleFilled.swiftUIImage(size: 13) }
                .buttonStyle(SQTextButtonStyle()).sqHelp(SQL10n.string("Cancel"))
        }
        .frame(minHeight: Theme.Row.list)
    }

    private func row(_ job: ExportQueueModel.Row) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            icon(job.state)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(job.name).font(Theme.Typography.bodyFont).foregroundStyle(Self.label).lineLimit(1)
                switch job.state {
                case .running:
                    progressBar(job.progress)
                case .waiting:
                    Text(ExportQueueModel.stateText(job.state)).font(Theme.Typography.captionFont).foregroundStyle(Self.label2)
                default:
                    Text(ExportQueueModel.stateText(job.state)).font(Theme.Typography.captionFont).foregroundStyle(Self.label2).lineLimit(2)
                    if let l = ExportQueueModel.loudnessText(job.loudness) {
                        Text(l).font(Theme.Typography.captionFont).foregroundStyle(Self.label2).lineLimit(2)
                    }
                }
            }
            Spacer(minLength: Theme.Spacing.xs)
            switch job.state {
            case .waiting, .running:
                Button { model.cancel(job.id) } label: { SQIcon.closeCircleFilled.swiftUIImage(size: 13) }
                    .buttonStyle(SQTextButtonStyle()).sqHelp(SQL10n.string("Stop"))
            case .done:
                Button { model.reveal(job) } label: { SQIcon.findFolder.swiftUIImage(size: 13) }
                    .buttonStyle(SQTextButtonStyle()).sqHelp(SQL10n.string("Show in Finder"))
            default:
                EmptyView()
            }
        }
        .frame(minHeight: Theme.Row.list)
    }

    /// Pip's edge in a queue row (fits the row height).
    static let pipSide: CGFloat = 28

    /// The app icon gradient (`Theme.IconGradient`): export progress and the finished state only.
    private static var iconGradient: LinearGradient {
        LinearGradient(colors: Theme.IconGradient.stops.map { Color(nsColor: $0) }, startPoint: .leading, endPoint: .trailing)
    }

    /// Own progress bar (no system ProgressView): fill track, icon gradient fill.
    private func progressBar(_ value: Double) -> some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: Theme.Radius.small).fill(Color(nsColor: Theme.Colors.fill))
                RoundedRectangle(cornerRadius: Theme.Radius.small).fill(Self.iconGradient)
                    .frame(width: g.size.width * CGFloat(min(max(value, 0), 1)))
            }
        }
        .frame(height: Theme.Spacing.xs)
    }

    @ViewBuilder private func icon(_ s: ExportJobState) -> some View {
        switch s {
        case .waiting: SQIcon.clock.swiftUIImage(size: 13).foregroundStyle(Self.label2)
        // Pip in the queue row (M7 working, M8 cheer, M9 oops); a switched-off place falls back to the icon.
        case .running where SQMascotPlace.exportRunning.isEnabled: SQMascotPlaceView(.exportRunning, side: Self.pipSide)
        case .done where SQMascotPlace.exportDone.isEnabled: SQMascotPlaceView(.exportDone, side: Self.pipSide)
        case .failed where SQMascotPlace.exportFailed.isEnabled: SQMascotPlaceView(.exportFailed, side: Self.pipSide)
        case .running: SQIcon.uploadCircle.swiftUIImage(size: 13).foregroundStyle(Color(nsColor: Theme.State.primary))
        case .done: SQIcon.checkCircleFilled.swiftUIImage(size: 13).foregroundStyle(Self.iconGradient)
        case .failed: SQIcon.warning.swiftUIImage(size: 13).foregroundStyle(Color(nsColor: Theme.Colors.yellow))
        case .cancelled: SQIcon.stopCircle.swiftUIImage(size: 13).foregroundStyle(Self.label2)
        }
    }
}
