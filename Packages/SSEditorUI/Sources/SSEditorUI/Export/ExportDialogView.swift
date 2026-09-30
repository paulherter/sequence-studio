import SwiftUI
import SSCore
import SSExport

/// Export sheet. Compact by default (4a), "Show Details" expands the same sheet (4b).
/// `onExport` is called with the chosen folder; the host enqueues via `ExportDialogModel.submit`.
public struct ExportDialogView: View {
    @Bindable var model: ExportDialogModel
    let onExport: () -> Void
    let onCancel: () -> Void
    @State private var showDetails = false

    public init(model: ExportDialogModel, onExport: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.model = model; self.onExport = onExport; self.onCancel = onCancel
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                sequenceList
                    .frame(width: showDetails ? 200 : 360)
                if showDetails {
                    Divider()
                    ScrollView { detailForm.padding(16) }
                        .frame(width: 420)
                }
            }
            .frame(height: showDetails ? 440 : nil)
            Divider()
            footer
        }
        .frame(minWidth: showDetails ? 620 : 360)
        .animation(.default, value: showDetails)
    }

    // MARK: Sequences

    private var sequenceList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export").font(.headline)
            List(selection: $model.selectedID) {
                ForEach(model.sequences) { item in
                    HStack {
                        Toggle(isOn: Binding(get: { model.isChecked(item.id) },
                                             set: { model.setChecked(item.id, $0) })) {
                            Text(item.name).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Text(Self.durationText(model.effectiveDuration(of: item.id)))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    .tag(item.id)
                }
            }
            .listStyle(.bordered)
            .frame(minHeight: 88)
            if !showDetails { compactSettings }
        }
        .padding(16)
    }

    private var compactSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Preset") { presetPicker }
            LabeledContent("Range") { rangePicker }
        }
    }

    private var presetPicker: some View {
        Picker("Preset", selection: $model.presetID) {
            ForEach(model.presets) { Text($0.name).tag($0.id) }
            if model.presetID == ExportDialogModel.customPresetID {
                Divider()
                Text("Custom").tag(ExportDialogModel.customPresetID)
            }
        }
        .labelsHidden().frame(width: 220)
    }

    private var rangePicker: some View {
        Picker("Range", selection: $model.useInOut) {
            Text("Entire sequence").tag(false)
            Text("In to Out").tag(true)
        }
        .pickerStyle(.segmented).labelsHidden().frame(width: 220)
        .disabled(!model.canUseInOut)
    }

    // MARK: Details

    private var detailForm: some View {
        Form {
            Section("Preset") {
                LabeledContent("Preset") { presetPicker }
            }
            Section("Video") {
                Picker("Codec", selection: $model.codec) {
                    Text("H.264").tag(VideoCodec.h264)
                    Text("HEVC").tag(VideoCodec.hevc)
                }
                LabeledContent("Size") {
                    HStack(spacing: 4) {
                        TextField("Width", value: $model.width, format: .number.grouping(.never))
                            .frame(width: 64).multilineTextAlignment(.trailing)
                        Text("x").foregroundStyle(.secondary)
                        TextField("Height", value: $model.height, format: .number.grouping(.never))
                            .frame(width: 64).multilineTextAlignment(.trailing)
                    }
                }
                Picker("Frame rate", selection: $model.fps) {
                    ForEach(ExportDialogModel.frameRates, id: \.self) { Text(Self.fpsText($0)).tag($0) }
                }
                LabeledContent("Bitrate") {
                    HStack(spacing: 4) {
                        TextField("Bitrate", value: $model.bitrateMbps, format: .number.precision(.fractionLength(0...1)))
                            .frame(width: 64).multilineTextAlignment(.trailing)
                        Text("Mbit/s").foregroundStyle(.secondary)
                    }
                }
            }
            Section("Audio") {
                Toggle("Normalize loudness to \(ExportDialogModel.loudnessTargetLUFS) LUFS", isOn: $model.normalizeLoudness)
            }
            Section("Captions") {
                Picker("Captions", selection: $model.captions) {
                    Text("None").tag(CaptionMode.none)
                    Text("Burn in").tag(CaptionMode.burnIn)
                    Text("Sidecar .srt").tag(CaptionMode.sidecarSRT)
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            Section("File") {
                LabeledContent("Range") { rangePicker }
                LabeledContent("Color") { Text("Rec. 709 (1-1-1)").foregroundStyle(.secondary) }
            }
        }
        .formStyle(.columns)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.validationMessages, id: \.self) { msg in
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow).font(.callout)
            }
            HStack {
                Button(showDetails ? "Hide Details" : "Show Details") { showDetails.toggle() }
                Spacer()
                Text(model.estimatedSizeText).monospacedDigit().foregroundStyle(.secondary)
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button("Export\u{2026}", action: onExport)
                    .keyboardShortcut(.defaultAction).disabled(!model.canExport)
            }
        }
        .padding(16)
    }

    // MARK: Formatting

    static func durationText(_ t: Time) -> String {
        let total = max(0, Int((Double(t.value) / Double(t.timescale)).rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func fpsText(_ fps: Double) -> String {
        fps == fps.rounded() ? "\(Int(fps)) fps" : String(format: "%.3g fps", fps)
    }
}
