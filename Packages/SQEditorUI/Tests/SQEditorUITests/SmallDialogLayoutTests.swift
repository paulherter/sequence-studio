import AppKit
@testable import SQCore
@testable import SQEditorSession
import Testing
@testable import SQUIKit
@testable import SQEditorUI

/// The small tool dialogs share the dialog rules: one label column, the unit after the number capsule (never inside it),
/// and the shared footer band. Each dialog is laid out offscreen in a real `SQDialog` card.
@MainActor @Suite struct SmallDialogLayoutTests {
    private func all(_ v: NSView) -> [NSView] { v.subviews + v.subviews.flatMap { all($0) } }

    /// Lays `accessory` out in a card of ladder step `size` and checks what every dialog owes its width: the card is exactly
    /// that wide, nothing inside is wider than the card, and no single-line label is cut off.
    private func lay(_ title: String, _ accessory: NSView, size: SQModal.Size, buttons: [String] = ["OK", "Cancel"]) -> NSView {
        let card = lay(title, accessory, width: size.width, buttons: buttons)
        #expect(abs(card.bounds.width - size.width) < 0.5, "\(title): card is \(card.bounds.width), ladder step \(size.width)")
        #expect(card.fittingSize.width <= size.width + 0.5, "\(title): content needs \(card.fittingSize.width) > \(size.width)")
        for t in all(card).compactMap({ $0 as? NSTextField }) where !t.stringValue.isEmpty && t.maximumNumberOfLines == 1 && !t.isEditable {
            #expect(t.frame.width + 0.5 >= t.intrinsicContentSize.width, "\(title): label \"\(t.stringValue)\" is cut (\(t.frame.width) < \(t.intrinsicContentSize.width))")
        }
        return card
    }

    private func lay(_ title: String, _ accessory: NSView, width: CGFloat, buttons: [String] = ["OK", "Cancel"]) -> NSView {
        let d = SQDialog()
        d.messageText = title
        d.width = width
        d.accessoryView = accessory
        for b in buttons { d.addButton(b) }
        let w = d.layout()
        w.setContentSize(NSSize(width: 900, height: 700))      // as `beginSheetModal`: the scrim covers the host window
        w.contentView!.layoutSubtreeIfNeeded()
        return (w.contentView as! SQModalScrimView).card
    }

    private func f(_ v: NSView, _ root: NSView) -> NSRect { root.convert(v.bounds, from: v) }

    /// Label column, unit outside, footer band for one dialog; `sliders` are the numeric controls in row order.
    private func check(_ name: String, _ root: NSView, labels: [String], sliders: [NumericSlider]) {
        let texts = all(root).compactMap { $0 as? NSTextField }.filter { labels.contains($0.stringValue) }
        #expect(texts.map(\.stringValue) == labels, "\(name): label rows \(texts.map(\.stringValue))")
        guard let first = texts.first else { return }
        let lx = texts.map { f($0, root).insetBy(dx: 2, dy: 0).minX }      // alignment rect: a label cell draws 2 pt inside its frame
        #expect(lx.allSatisfy { abs($0 - lx[0]) < 0.5 }, "\(name): one label column \(lx)")
        #expect(abs(lx[0] - SQDialogMetrics.sidePad) < 0.5, "\(name): labels start at the side padding \(lx)")
        let controlX = SQDialogMetrics.sidePad + SQDialogMetrics.labelWidth + SQDialogMetrics.labelGap
        let fieldRight = sliders.map { f($0.field, root).maxX }
        #expect(fieldRight.allSatisfy { abs($0 - fieldRight[0]) < 0.5 }, "\(name): one field edge \(fieldRight)")
        for s in sliders {
            #expect(s.unitOutside, "\(name): unit outside")
            #expect(abs(f(s, root).minX - controlX) < 0.5, "\(name): control starts where the label column ends")
            #expect(s.field.unitOutside, "\(name): capsule unit off")
            if !s.unit.isEmpty {
                #expect(!s.field.displayText.contains(s.unit), "\(name): capsule holds the bare number")
                #expect(abs((f(s.unitLabel, root).minX - f(s.field, root).maxX) - SQDialogMetrics.controlGap) < 0.5, "\(name): unit gap")
            }
        }
        let band = all(root).first { String(describing: type(of: $0)) == "SQDialogFooterBand" }
        #expect(band != nil, "\(name): footer band")
        if let band {
            #expect(abs(f(band, root).height - SQDialogMetrics.footerHeight) < 0.5, "\(name): footer height \(f(band, root))")
            #expect(abs(f(band, root).width - root.bounds.width) < 0.5 && (abs(f(band, root).maxY - root.bounds.maxY) < 0.5 || abs(f(band, root).minY) < 0.5), "\(name): band spans the card bottom")
            #expect(Set(all(band).compactMap { $0 as? SQButton }.map(\.title)) == ["OK", "Cancel"])
        }
    }

    @Test func toneDialog() {
        let v = ToneDialog.makeView(ToneSpec(frequencyHz: 800, levelDB: -6))
        check("Tone", lay("Tone Settings", v.view, size: .xs), labels: ["Frequency", "Level"], sliders: [v.frequency, v.level])
    }

    @Test func trackMixDialog() {
        let v = TrackMixDialog.makeView(volumeDB: -3, pan: 0.2)
        check("Track Mix", lay("Track", v.view, size: .xs), labels: ["Volume", "Pan"], sliders: [v.volume, v.pan])
        let s = TrackMixDialog.makeSequenceVolumeView(volumeDB: 0)
        check("Sequence Volume", lay("Sequence Volume", s.view, size: .xs), labels: ["Volume"], sliders: [s.volume])
    }

    @Test func colorMatteDialog() {
        let v = ColorMatteDialog.makeView(name: "Matte", color: .default, durationSeconds: 5)
        check("Color Matte", lay("Color Matte", v.view, size: .xs), labels: ["Name", "Color", "Duration"], sliders: [v.duration])
    }

    @Test func removeSilencesDialog() {
        let v = RemoveSilencesDialog.makeView(initial: .standard) { _ in (0, Time(0, 1)) }
        let c = v.controller
        check("Remove Silences", lay("Remove Silences", v.view, size: .s), labels: ["Level", "Min. Length", "Keep Each Side"],
              sliders: [c.threshold, c.minimum, c.padding])
    }

    @Test func voiceoverDialog() {
        let c = VoiceoverFieldsController(voices: [VoiceoverVoiceChoice(id: "a", title: "A")], initialVoice: "a", initialRate: 0.5)
        let root = lay("Voiceover", c.view, size: .s)
        let rate = all(root).compactMap { $0 as? NumericSlider }
        #expect(rate.count == 1 && rate[0].unit == "x" && rate[0].unitOutside)
        check("Voiceover", root, labels: ["Voice", "Speed"], sliders: rate)
    }

    @Test func customPixelAspectDialog() {
        let field = SQDialog.makeNumberField(value: 1, range: 0.25...4, step: 0.01, decimals: 4, defaultValue: 1, width: nil)
        field.leadingText = true
        let root = lay("Custom Pixel Aspect", SQDialogForm(rows: [SQDialog.formRow("Ratio", field)]), size: .xs)
        check("Pixel Aspect", root, labels: ["Ratio"], sliders: [])
    }

    @Test func anonymizeDialog() {
        let ui = AnonymizeDialog.makeView(people: [])
        let root = lay("Anonymize", ui.view, size: .s)
        withExtendedLifetime(ui.controller) {}
        let band = all(root).first { String(describing: type(of: $0)) == "SQDialogFooterBand" }
        #expect(band != nil)
    }

    /// What every dialog owes: controls inside the card, buttons not cut, ScrubField units after the capsule, footer band
    /// with exactly `buttons`.
    private func checkCommon(_ name: String, _ root: NSView, buttons: [String]) {
        for v in all(root) where (v is NSControl && !(v is NSScroller)) || v is NumericSlider {
            let r = f(v, root)
            #expect(r.minX >= -0.5 && r.maxX <= root.bounds.width + 0.5, "\(name): \(type(of: v)) \(r) sticks out of the card (\(root.bounds.width))")
        }
        for b in all(root).compactMap({ $0 as? SQButton }) {
            #expect(b.frame.width + 0.5 >= b.intrinsicContentSize.width, "\(name): button \"\(b.title)\" is cut")
        }
        for s in all(root).compactMap({ $0 as? ScrubField }) where s.unitOutside && !s.unit.isEmpty {
            #expect(!s.displayText.contains(s.unit), "\(name): capsule holds the bare number")
            let labels = all(root).compactMap { $0 as? SQUnitLabel }.filter { abs(f($0, root).midY - f(s, root).midY) < 4 && f($0, root).minX >= f(s, root).maxX - 0.5 }
            #expect(!labels.isEmpty, "\(name): unit \(s.unit) after the capsule")
            if let u = labels.first { #expect(abs(f(u, root).minX - f(s, root).maxX - SQDialogMetrics.controlGap) < 0.5, "\(name): unit gap") }
        }
        let band = all(root).first { String(describing: type(of: $0)) == "SQDialogFooterBand" }
        #expect(band != nil, "\(name): footer band")
        if let band {
            #expect(abs(f(band, root).height - SQDialogMetrics.footerHeight) < 0.5, "\(name): footer height")
            #expect(Set(all(band).compactMap { $0 as? SQButton }.map(\.title)) == Set(buttons), "\(name): footer buttons")
        }
    }

    /// Labels in one column starting at the side padding.
    private func checkLabels(_ name: String, _ root: NSView, _ labels: [String]) {
        let texts = all(root).compactMap { $0 as? NSTextField }.filter { labels.contains($0.stringValue) }
        #expect(texts.map(\.stringValue) == labels, "\(name): label rows \(texts.map(\.stringValue))")
        let lx = texts.map { f($0, root).insetBy(dx: 2, dy: 0).minX }
        #expect(lx.allSatisfy { abs($0 - SQDialogMetrics.sidePad) < 0.5 }, "\(name): labels at the side padding \(lx)")
    }

    @Test func anglesDialog() {
        let angles = [AngleCandidate(name: "Cam A", media: nil, hasAudio: true), AngleCandidate(name: "Cam B", media: nil, hasAudio: false)]
        let ui = AnglesDialog.makeView(angles: angles, fromTimeline: false, name: "Angles 1")
        let root = lay("Create Angles Clip", ui.view, size: .s)
        checkLabels("Angles", root, ["Name", "Sync by", "Sound from"])
        checkCommon("Angles", root, buttons: ["OK", "Cancel"])
        #expect(abs(f(ui.name, root).maxX - f(ui.sync, root).maxX) < 3, "Angles: name field ends where the popups end (\(f(ui.name, root)) vs \(f(ui.sync, root)))")
    }

    @Test func audioGainDialog() {
        let item = AudioGainPlan.Item(id: Clip.ID(), name: "Interview", gainDB: 2, peak: 0.6)
        let ui = AudioGainDialog.makeView(items: [item])
        let root = lay("Audio Gain", ui.view, size: .s)
        checkCommon("Audio Gain", root, buttons: ["OK", "Cancel"])
        #expect(ui.fields.count == 5 && ui.fields.prefix(4).allSatisfy { $0.unit == "dB" && $0.unitOutside } && ui.fields[4].unit == "LUFS")
        let xs = ui.fields.map { f($0, root).minX }
        #expect(xs.allSatisfy { abs($0 - xs[0]) < 0.5 }, "Audio Gain: one field column \(xs)")
    }

    @Test func changeFormatDialogs() {
        let current = SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30), audioSampleRate: 48000)
        for (title, name, button) in [("Change Format", String?.none, "Change"), ("Duplicate as Format", "", "Duplicate")] {
            let sheet = ChangeFormatSheet(current: current)
            let root = lay(title, sheet.accessory(hasSelection: true, name: name), size: .s, buttons: [button, "Cancel"])
            checkLabels(title, root, (name == nil ? [] : ["Name"]) + ["Format", "Frame Size", "Clips", "Selected Clips"])
            checkCommon(title, root, buttons: [button, "Cancel"])
            let w = f(sheet.widthField, root), h = f(sheet.heightField, root)
            #expect(h.minX >= w.maxX && h.maxX <= root.bounds.width - SQDialogMetrics.sidePad + 0.5, "\(title): size fields inside the control column")
            #expect(abs(f(sheet.modePopup, root).maxX - h.maxX) < 0.5, "\(title): fields end where the popups end")
        }
    }

    @Test func punchInCutsDialog() {
        let sheet = PunchInCutsSheetView(PunchInCutsOptions(scales: [115], ease: .hold, pattern: .alternate))
        let root = lay("Punch In Cuts", sheet.form, size: .xs, buttons: ["Apply", "Cancel"])
        checkLabels("Punch In", root, ["Pattern", "Ease", "Zoom"])
        checkCommon("Punch In", root, buttons: ["Apply", "Cancel"])
    }

    @Test func checkCutsDialog() {
        var stats = EditStats()
        stats.shotCount = 24; stats.averageShotSeconds = 2.4
        stats.histogram = ["<1 s", "1-2 s", "2-3 s", "3-5 s", "5 s+"].enumerated().map { ShotBucket(label: $0.element, count: 3 + $0.offset * 2) }
        let report = CutCheckReport(findings: [], stats: stats, platform: .tiktok)
        let sheet = CutCheckSheetView(report: report, rerun: { _ in report })
        let root = lay("Check Cuts", sheet.form, size: .s, buttons: ["Done"])
        checkLabels("Check Cuts", root, ["Safe Zone"])
        let controlX = SQDialogMetrics.sidePad + SQDialogMetrics.labelWidth + SQDialogMetrics.labelGap
        let note = all(root).compactMap { $0 as? NSTextField }.first { $0.attributedStringValue.string.contains("shots") }
        let chart = all(root).first { $0 is ShotHistogramView }
        #expect(note != nil && abs(f(note!, root).minX - controlX) < 3, "Check Cuts: summary starts in the control column")
        #expect(chart != nil && abs(f(chart!, root).minX - controlX) < 0.5, "Check Cuts: chart starts in the control column")
        #expect(chart != nil && f(chart!, root).maxX <= root.bounds.width - SQDialogMetrics.sidePad + 0.5, "Check Cuts: chart inside the side padding")
        checkCommon("Check Cuts", root, buttons: ["Done"])
    }

    @Test func checkTheseFramesDialog() {
        let rows = [SQDialog.formText("0:12:04 to 0:12:09, the person may be outside the cover and the detection was unsure for the whole range"),
                    SQDialog.formText("0:31:00 to 0:31:02"),
                    SQDialog.formText("and 4 more ranges where the detection was unsure.")]
        let root = lay("Anonymize: Check These Frames", SQDialogForm(rows: rows), size: .sList, buttons: ["Go to First", "Close"])
        checkCommon("Check These Frames", root, buttons: ["Go to First", "Close"])
    }

    /// Header title, cut-free wrapping text and a footer inside the card: shared by the three dialogs built from App sources.
    private func checkCard(_ name: String, _ root: NSView, title: String, buttons: [String], leading: [String] = []) {
        checkCommon(name, root, buttons: buttons + leading)
        let head = all(root).compactMap { $0 as? NSTextField }.first { $0.stringValue == title }
        #expect(head != nil, "\(name): header title")
        if let head { #expect(f(head, root).midY <= Theme.Modal.headerHeight + 0.5 || f(head, root).midY >= root.bounds.height - Theme.Modal.headerHeight - 0.5, "\(name): title sits in the header band \(f(head, root))") }
        let band = all(root).first { String(describing: type(of: $0)) == "SQDialogFooterBand" }
        for b in all(band ?? NSView()).compactMap({ $0 as? SQButton }) {
            let r = f(b, root), br = f(band!, root)
            #expect(r.minX >= br.minX - 0.5 && r.maxX <= br.maxX + 0.5 && r.minY >= br.minY - 0.5 && r.maxY <= br.maxY + 0.5, "\(name): button \"\(b.title)\" inside the footer")
        }
        // No clipped text: every wrapping label is as tall as its text needs at its width.
        for t in all(root).compactMap({ $0 as? NSTextField }) where !t.stringValue.isEmpty && !t.isEditable {
            let need = t.sizeThatFits(NSSize(width: t.frame.width, height: .greatestFiniteMagnitude)).height
            #expect(t.frame.height + 1 >= need, "\(name): \"\(t.stringValue.prefix(30))\" is clipped (\(t.frame.height) < \(need))")
        }
    }

    @Test func aboutDialog() {
        for supporters in [[String](), ["Ada", "Grace", "Linus"]] {
            let body = AboutDialog.makeBody(width: AboutDialog.bodyWidth, icon: NSImage(size: NSSize(width: 64, height: 64)), versionLine: "Version 0.1 (1)",
                                            discord: nil, supporters: supporters, target: nil, selector: { _ in #selector(NSApplication.terminate(_:)) },
                                            supportSelector: #selector(NSApplication.terminate(_:)))
            let root = lay("About", body, size: .sList, buttons: ["Done"])
            checkCard("About", root, title: "About", buttons: ["Done"])
            let titles = all(root).compactMap { $0 as? SQButton }.map(\.title)
            #expect(titles.contains("GitHub") && titles.contains("Support"), "About: link buttons \(titles)")
            #expect(all(root).contains { ($0 as? NSTextField)?.stringValue == "Supporters" } == !supporters.isEmpty)
        }
        #expect(AboutDialog.bodyWidth == SQModal.Size.sList.width - SQDialogMetrics.sidePad * 2)
    }

    @Test func acknowledgmentsDialog() {
        let body = AboutDialog.makeAcknowledgmentsBody(width: AboutDialog.bodyWidth)
        let root = lay("Acknowledgments", body, size: .sList, buttons: ["Done", "Back"])
        checkCard("Acknowledgments", root, title: "Acknowledgments", buttons: ["Done", "Back"])
        let names = all(root).compactMap { ($0 as? NSTextField)?.stringValue }
        for a in AboutContent.acknowledgments { #expect(names.contains { $0.hasPrefix(a.name) }, "Acknowledgments: \(a.name) listed") }
    }

    @Test func keymapImportResultDialog() {
        func cmd(_ id: String, _ specs: String...) -> ForeignCommand { ForeignCommand(sourceID: id, chords: specs.compactMap { ForeignChord(spec: $0) }) }
        let result = KeymapImport.build([cmd("InsertMedia", "w", "return"), cmd("Cut", "cmd+q"), cmd("NoSuchCommandAnywhere", "x")])
        let root = lay(KeymapImportResultDialog.title(result), KeymapImportResultDialog.makeAccessory(result), size: .sList, buttons: ["Save as Set", "Cancel"])
        checkCommon("Import Result", root, buttons: ["Save as Set", "Cancel"])
        let scroll = all(root).first { $0 is NSScrollView }
        #expect(scroll != nil && abs(f(scroll!, root).height - KeymapImportResultDialog.listHeight) < 0.5, "Import Result: list block height")
        #expect(scroll != nil && f(scroll!, root).maxX <= root.bounds.width - SQDialogMetrics.sidePad + 0.5, "Import Result: list inside the side padding")
        let empty = lay("Nothing", KeymapImportResultDialog.makeAccessory(KeymapImport.build([])), size: .sList, buttons: ["Save as Set", "Cancel"])
        #expect(!all(empty).contains { $0 is NSScrollView }, "Import Result: no list block when nothing to list")
    }

    @Test func ladderIsTheOnlyWidthSource() {
        #expect([SQModal.Size.xs, .s, .sList, .m, .l].map(\.width) == [360, 440, 480, 600, 860])
    }
}
