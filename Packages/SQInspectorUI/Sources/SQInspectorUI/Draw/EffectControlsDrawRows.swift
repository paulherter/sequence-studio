import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import SQCore
import SQUIKit
import SQDrawKit
import SQEditorSession

/// The smaller Effect Controls rows (masks, color groups, grade range, stabilizer, disclosures), translated from their Mac
/// views (`SubjectMaskRow`, `MaskControlsRow`, `MaskTrackRow`, `PictureMaskRow`, `MaskUseRow`, `ColorRangeMaskRow`,
/// `ColorRangeAmountRow`, `TrackMaskTrackRow`, `ColorGroupHeaderRow`, `ColorMatchRow`, `GradeRangeRow`, `GradeFadeRow`,
/// `ColorGraphSummaryRow`, `StabilizeAnalyzeRow`, `EQCurveHeaderRow`, `MultibandEditorRow`, `MultibandParamsRow`).
/// Each row is a list of widgets on the Mac frames; the panel draws, hit-tests and fires them in one place.
extension EffectControlsDrawPanel {
    /// One control of a translated row, in row coordinates.
    struct Widget {
        enum Kind {
            /// A label (`makeLabel`): text, color, size, alignment.
            case text(String, DrawColor?, CGFloat?, TextFieldControl.Alignment)
            /// SQCheckbox with its title right of the box.
            case check(String, InspectorDraw.CheckState)
            case popup(String)
            /// IconButton.
            case icon(SQIcon, DrawColor?)
            /// SQButton.
            case button(String)
            case progress(Double)
            case well(DrawColor)
            /// A scrub field; `FieldSpec` configures it and takes its values.
            case field(FieldSpec)
            /// A text field (timecodes); `commit` gets the typed text.
            case textField(String, (@MainActor (String) -> Void))
            /// InspectorSectionHeader: chevron, bold title, optional enable box (whole row toggles).
            case disclosure(String, open: Bool, enabled: Bool?)
            /// The ring of a keyframe row.
            case ring(KeyframeControlState)
            /// Previous / key / next of a keyframe row (the whole navigation, hit slots are `.hit` widgets).
            case navigation(KeyframeControlState)
            /// Hit area only.
            case hit
            /// A drawn editor with its own pointer handling (curves, EQ), cached per key.
            case surface(@MainActor () -> DrawSurface)
        }
        var key: String
        var frame: CGRect
        var kind: Kind
        var enabled = true
        var help: String?
        /// A press released inside (buttons, checkboxes, icons, disclosures).
        var action: (@MainActor () -> Void)?
        /// A popup: the items, shown through `onMenu`.
        var menu: (@MainActor () -> [SQMenuItem])?
        /// The enable box of a disclosure.
        var toggle: (@MainActor () -> Void)?
        var toggleFrame: CGRect?
    }

    /// A scrub field of a translated row (ScrubField's configuration and callbacks on the Mac row).
    struct FieldSpec {
        var configure: @MainActor (inout ScrubFieldControl) -> Void
        var value: @MainActor () -> Double
        var begin: @MainActor () -> Void
        var change: @MainActor (Double) -> Void
        var end: @MainActor () -> Void
    }

    static func rowKey(_ k: EffectRow.Kind) -> String { String(describing: k) }

    /// The widgets of a row the panel draws generically, nil for the rows with their own code (sections, properties, speed).
    func widgets(_ r: EffectRow) -> [Widget]? {
        let h = r.height, g = ControlsGrid(width: size.width), key = Self.rowKey(r.kind)
        func k(_ s: String) -> String { key + "." + s }
        func trash(_ label: String, _ id: ClipMask.ID) -> Widget {
            Widget(key: k("remove"), frame: g.controlFrame(x: g.resetX, width: ControlsGrid.resetWidth, height: h), kind: .icon(.trash, nil),
                   help: label) { [model] in model.removeMask(id) }
        }
        func maskModeMenu(_ id: ClipMask.ID, _ current: MaskMode?) -> @MainActor () -> [SQMenuItem] {
            { [model] in MaskMode.allCases.map { m in SQMenuItem(title: m.title, isChecked: m == current) { model.setMaskMode(id, m) } } }
        }
        let labelFrame = g.labelFrame(height: h)
        func label(_ s: String, color: DrawColor? = nil) -> Widget {
            Widget(key: k("label"), frame: labelFrame, kind: .text(SQL10n.string(s), color, nil, .left))
        }
        switch r.kind {
        case .subjectMask(let id):
            guard let m = model.clip?.mask(id) else { return [] }
            let on = model.isBlendGroupEnabled
            let remove = trash("Delete Subject Mask", id)
            return [
                Widget(key: k("invert"), frame: g.controlFrame(x: ControlsGrid.labelX, width: ControlsGrid.labelWidth, height: h),
                       kind: .check("Inverted", m.inverted ? .on : .off), enabled: on, help: "Invert Subject Mask") { [model] in
                    model.setMaskInverted(id, !m.inverted)
                },
                Widget(key: k("mode"), frame: g.fillFrame(height: h, maxX: remove.frame.minX - ControlsGrid.gap,
                                                          maxWidth: ControlsMetrics.Portable.popupWidth),
                       kind: .popup(SQL10n.string(m.mode.title)), enabled: on, help: "Mask Mode", menu: maskModeMenu(id, m.mode)),
                remove,
            ]
        case .maskControls(let id):
            guard let m = model.clip?.mask(id) else { return [] }
            let on = m.enabled, state = model.maskRowKeyframeState(id)
            var out: [Widget] = [
                Widget(key: k("invert"), frame: g.controlFrame(x: ControlsGrid.labelX, width: ControlsGrid.labelWidth, height: h),
                       kind: .check("Inverted", m.inverted ? .on : .off), enabled: on, help: "Invert Mask") { [model] in
                    model.setMaskInverted(id, !m.inverted)
                },
                Widget(key: k("mode"), frame: g.fillFrame(height: h, maxX: g.valueMaxX, maxWidth: ControlsMetrics.Portable.popupWidth),
                       kind: .popup(SQL10n.string(m.mode.title)), enabled: on, help: "Mask Mode", menu: maskModeMenu(id, m.mode)),
            ]
            // A Magic mask has no path: its shape comes from the pick and Track. It keeps previous / next (its tracked frames).
            if !(m.source == .magic || m.source == .picture) {
                out.append(Widget(key: k("ring"), frame: g.toggleFrame(height: h), kind: .ring(state), help: "Mask Path") { [weak self] in
                    self?.stopwatch(.maskPath(id))
                })
            }
            if !(m.source == .picture || (m.source == .magic && model.magicKeys(id).isEmpty)) && state.showsNavigation {
                out += keyNavigation(k, h, state, previous: { [model] in model.goToPreviousMaskRowKey(id) },
                                     key: { [model] in _ = model.toggleMaskPathKeyAtPlayhead(id) },
                                     next: { [model] in model.goToNextMaskRowKey(id) })
            }
            return out
        case .maskTrack(let id):
            guard let m = model.clip?.mask(id) else { return [] }
            return maskTrackWidgets(id, m, h, g, k, trash("Delete Mask", id))
        case .pictureMask(let id):
            guard let m = model.clip?.mask(id) else { return [] }
            let remove = trash("Delete Mask", id)
            let cw: CGFloat = 84     // Theme.Inspector.channelWidth
            let channel = g.controlFrame(x: remove.frame.minX - ControlsGrid.gap - cw, width: cw, height: h)
            let choices = model.pictureTrackChoices()
            let sel = model.pictureTrackSelection(id, in: choices)
            let title = choices.indices.contains(sel) ? choices[sel].lane ?? choices[sel].title : ""
            return [
                label("Picture of"),
                Widget(key: k("track"), frame: g.fillFrame(height: h, maxX: channel.minX - ControlsGrid.gap), kind: .popup(title),
                       enabled: m.enabled, help: "The track whose picture is the mask", menu: { [model] in
                    choices.enumerated().map { i, c in
                        SQMenuItem(title: c.lane ?? c.title, isChecked: i == sel,
                                   help: c.lane == nil || c.title == c.lane ? nil : c.title) { model.setMaskPictureTrack(id, c.track) }
                    }
                }),
                Widget(key: k("channel"), frame: channel, kind: .popup(SQL10n.string(m.pictureChannel.title)), enabled: m.enabled,
                       help: "Shape: where the picture is. Brightness: how bright it is", menu: { [model] in
                    MatteChannel.allCases.map { c in
                        SQMenuItem(title: c.title, isChecked: c == m.pictureChannel) { model.setMaskPictureChannel(id, c) }
                    }
                }),
                remove,
            ]
        case .maskUse(let id):
            guard let m = model.clip?.mask(id) else { return [] }
            let list = model.maskInputChoices(id)
            let used = list.filter(\.on).count
            let title = list.isEmpty ? "No effect to use it in" : used == 0 ? "Use in effect…" : used == 1 ? "Used in 1 effect" : "Used in \(used) effects"
            return [
                Widget(key: k("cuts"), frame: g.toggleBox(ControlsGrid.toggleWidth, height: h), kind: .check("", m.usedByOpacity ? .on : .off),
                       enabled: m.enabled,
                       help: "The mask cuts out the clip's picture (off: it only limits the effects that use it)") { [model] in
                    model.setMask(id, usedByOpacity: !m.usedByOpacity)
                },
                label("Cuts picture"),
                Widget(key: k("useIn"), frame: g.fillFrame(height: h, maxWidth: ControlsMetrics.Portable.popupWidth),
                       kind: .popup(SQL10n.string(title)), enabled: m.enabled && !list.isEmpty,
                       help: "Effects that only work inside this mask", menu: { [model] in
                    list.map { c in SQMenuItem(title: c.title, isChecked: c.on) { model.setMask(id, input: !c.on, ofEffect: c.effect) } }
                }),
            ]
        case .colorRangeMask(let id):
            guard let m = model.clip?.mask(id) else { return [] }
            let on = model.isBlendGroupEnabled && m.enabled
            let remove = trash("Delete Mask", id)
            let well = g.controlFrame(x: ControlsGrid.valueX, width: 44, height: h)
            let x = well.maxX + ControlsGrid.gap
            let key = m.colorRange
            return [
                label("Color"),
                Widget(key: k("well"), frame: well, kind: .well(DrawColor(Float(key.red), Float(key.green), Float(key.blue), 1)),
                       enabled: on, help: "The color the mask keeps") { [weak self] in self?.pickMaskColor(id, anchorKey: k("well")) },
                Widget(key: k("invert"), frame: g.controlFrame(x: x, width: max(remove.frame.minX - ControlsGrid.gap - x, 0), height: h),
                       kind: .check("Inverted", m.inverted ? .on : .off), enabled: on,
                       help: "Keep everything except this color") { [model] in model.setMaskInverted(id, !m.inverted) },
                remove,
            ]
        case .colorRangeAmount(let id, let soft):
            guard let m = model.clip?.mask(id) else { return [] }
            let title = soft ? "Softness" : "Tolerance"
            let spec = FieldSpec(configure: { f in
                f.range = 0...100; f.step = 1; f.decimals = 0; f.unit = "%"; f.isPlain = true
                f.defaultValue = (soft ? ColorRangeKey.default.softness : ColorRangeKey.default.tolerance) * 100
            }, value: { [model] in
                let r = model.clip?.mask(id)?.colorRange ?? .default
                return (soft ? r.softness : r.tolerance) * 100
            }, begin: { [model] in model.beginGesture() }, change: { [model] percent in
                guard let k = model.colorRange(of: id) else { return }
                let v = min(max(percent, 0), 100) / 100
                model.setMaskColorRange(id, ColorRangeKey(red: k.red, green: k.green, blue: k.blue,
                                                          tolerance: soft ? k.tolerance : v, softness: soft ? v : k.softness))
            }, end: { [model] in model.endGesture() })
            return [
                label(title),
                Widget(key: k("field"), frame: g.valueFrame(0, height: h), kind: .field(spec), enabled: model.isBlendGroupEnabled && m.enabled,
                       help: soft ? "How gradually the mask fades out beyond the tolerance"
                                  : "How far from the picked color still counts as the color"),
            ]
        case .trackMaskTrack(let effect):
            let choices = model.pictureTrackChoices()
            let sel = model.trackMaskSelection(effect, in: choices)
            let title = choices.indices.contains(sel) ? choices[sel].lane ?? choices[sel].title : ""
            return [
                label("Track"),
                Widget(key: k("track"), frame: g.fillFrame(height: h), kind: .popup(title),
                       help: "The video track whose picture limits this clip", menu: { [model] in
                    choices.enumerated().map { i, c in
                        SQMenuItem(title: c.lane ?? c.title, isChecked: i == sel,
                                   help: c.lane == nil || c.title == c.lane ? nil : c.title) { model.setTrackMaskTrack(effect, c.track) }
                    }
                }),
            ]
        case .colorGroup(let effect, let groupKey):
            let p = EffectProperty.fx(effect, kind: ClipEffect.colorKind, key: groupKey)
            let name = EffectCatalog.param(ClipEffect.colorKind, groupKey)?.title ?? groupKey
            let open = model.openColorGroups.contains(EffectControlsModel.colorGroupID(effect, groupKey))
            let on = model.scalarValue(p) >= 0.5
            return [disclosure(k, h, name, open: open, enabled: on, toggle: { [model] in _ = model.setValue(p, to: on ? 0 : 1) }) { [weak self] in
                self?.model.toggleColorGroup(effect, groupKey); self?.relayout()
            }]
        case .eqCurveHeader(let effect):
            return [disclosure(k, h, "Curve", open: model.isEQCurveOpen(effect), enabled: nil, toggle: nil) { [weak self] in
                self?.model.toggleEQCurve(effect); self?.relayout()
            }]
        case .multibandParams(let effect):
            return [disclosure(k, h, "All Parameters", open: model.isMultibandParametersOpen(effect), enabled: nil, toggle: nil) { [weak self] in
                self?.model.toggleMultibandParameters(effect); self?.relayout()
            }]
        case .multiband(let effect):
            let w = max(estimatedButtonWidth("Edit Custom Setup"), 120)
            return [Widget(key: k("open"), frame: CGRect(x: ControlsGrid.labelX, y: ((h - CGFloat(InspectorTokens.capsule)) / 2).rounded(),
                                                         width: w, height: CGFloat(InspectorTokens.capsule)),
                           kind: .button("Edit Custom Setup")) { [weak self] in self?.onMultibandEditor?(effect) }]
        case .colorMatch(let effect):
            let block = model.colorMatchBlock(effect), ref = model.colorMatchReference(effect)
            let set = g.controlFrame(x: ControlsGrid.valueX, width: estimatedButtonWidth("Set Reference"), height: h)
            let match = g.controlFrame(x: set.maxX + ControlsGrid.gap, width: estimatedButtonWidth("Match"), height: h)
            let x = match.maxX + ControlsGrid.gap
            let status = ref.map { SQL10n.format("Ref: %@", $0.label) } ?? SQL10n.string("No reference")
            return [
                Widget(key: k("set"), frame: set, kind: .button("Set Reference"), help: "Set Reference") { [model] in
                    model.requestColorMatch(effect, .setReference)
                },
                Widget(key: k("match"), frame: match, kind: .button("Match"), enabled: block == nil, help: block ?? "Match") { [model] in
                    model.requestColorMatch(effect, .match)
                },
                Widget(key: k("status"), frame: CGRect(x: x, y: 0, width: max(g.tailMaxX - x, 0), height: h),
                       kind: .text(status, theme.label3, CGFloat(DrawTheme.TypeSize.caption), .left), help: block ?? ref?.label),
            ]
        case .gradeRange(let effect):
            guard let range = model.gradeRange(effect) else { return [] }
            let fd = model.frameDuration, fw: CGFloat = 78     // Theme.Inspector.timecodeWidth
            let start = g.controlFrame(x: ControlsGrid.valueX, width: fw, height: h)
            let end = g.controlFrame(x: start.maxX + ControlsGrid.gap, width: fw, height: h)
            let bx = end.maxX + ControlsGrid.gap
            return [
                label("Range", color: theme.label2),
                timecodeField(k("start"), start, range.start, fd, help: "Range Start") { [model] t in model.setGradeRange(effect, start: t, end: nil) },
                timecodeField(k("end"), end, range.end, fd, help: "Range End") { [model] t in model.setGradeRange(effect, start: nil, end: t) },
                Widget(key: k("whole"), frame: g.controlFrame(x: bx, width: min(estimatedButtonWidth("Whole Clip"), max(g.tailMaxX - bx, 0)), height: h),
                       kind: .button("Whole Clip"), help: "Whole Clip") { [model] in model.setGradeWholeClip(effect) },
            ]
        case .gradeFade(let effect):
            let fd = model.frameDuration, v = model.gradeFades(effect), fw: CGFloat = 78
            let fin = g.controlFrame(x: ControlsGrid.valueX, width: fw, height: h)
            let fout = g.controlFrame(x: fin.maxX + ControlsGrid.gap, width: fw, height: h)
            return [
                label("Fade", color: theme.label2),
                timecodeField(k("in"), fin, v.fadeIn, fd, help: "Fade In Length") { [model] t in model.setGradeFades(effect, fadeIn: t, fadeOut: nil) },
                timecodeField(k("out"), fout, v.fadeOut, fd, help: "Fade Out Length") { [model] t in model.setGradeFades(effect, fadeIn: nil, fadeOut: t) },
            ]
        case .colorGraph(let effect):
            let n = model.colorGraphStepCount(effect)
            let bw = min(estimatedButtonWidth("Adjust"), max(g.tailMaxX - ControlsGrid.valueX, 0))
            return [
                label(SQL10n.plural(n, one: "%@ Step", other: "%@ Steps"), color: theme.label2),
                Widget(key: k("adjust"), frame: g.controlFrame(x: ControlsGrid.valueX, width: bw, height: h), kind: .button("Adjust"),
                       help: "Adjust in the Color page") { [model] in model.onOpenColorPro?() },
            ]
        case .stabilizeAnalyze(let effect):
            return stabilizeWidgets(effect, h, k)
        default:
            return rowSurfaceWidgets(r)
        }
    }

    /// SQButton.intrinsicContentSize: text width (caption face metrics are not known here) plus the 11 pt padding.
    /// shortcut: estimates 6 pt per character when no canvas is at hand (hit testing); drawing measures. Upgrade with a
    /// canvas-free text measure.
    func estimatedButtonWidth(_ title: String) -> CGFloat {
        if let measure { return ceil(measure(SQL10n.string(title))) + 2 * InspectorDraw.buttonPadding }
        return CGFloat(SQL10n.string(title).count) * 6 + 2 * InspectorDraw.buttonPadding
    }

    private func keyNavigation(_ k: (String) -> String, _ h: CGFloat, _ state: KeyframeControlState,
                               previous: @escaping @MainActor () -> Void, key: @escaping @MainActor () -> Void,
                               next: @escaping @MainActor () -> Void) -> [Widget] {
        let n = navigationSlot(0, h).union(navigationSlot(2, h))
        return [
            Widget(key: k("nav"), frame: n, kind: .navigation(state)),
            Widget(key: k("previous"), frame: navigationSlot(0, h), kind: .hit, enabled: state.canGoPrevious, help: "Go to Previous Keyframe",
                   action: previous),
            Widget(key: k("key"), frame: navigationSlot(1, h), kind: .hit, enabled: state.canToggleKey, help: "Add or Remove Keyframe",
                   action: key),
            Widget(key: k("next"), frame: navigationSlot(2, h), kind: .hit, enabled: state.canGoNext, help: "Go to Next Keyframe", action: next),
        ]
    }

    private func disclosure(_ k: (String) -> String, _ h: CGFloat, _ title: String, open: Bool, enabled: Bool?,
                            toggle: (@MainActor () -> Void)?, _ action: @escaping @MainActor () -> Void) -> Widget {
        let x = ControlsGrid.levelIndent
        var w = Widget(key: k("disclosure"), frame: CGRect(x: x, y: 0, width: max(size.width - x, 0), height: h),
                       kind: .disclosure(SQL10n.string(title), open: open, enabled: enabled),
                       help: SQL10n.format(open ? "Collapse %@" : "Expand %@", SQL10n.string(title)), action: action)
        if enabled != nil {
            let box = InspectorTokens.checkbox
            w.toggle = toggle
            w.toggleFrame = CGRect(x: size.width - ControlsGrid.trailing - box, y: ((h - box) / 2).rounded(), width: box, height: box)
        }
        return w
    }

    private func timecodeField(_ key: String, _ frame: CGRect, _ t: Time, _ fd: Time, help: String,
                               _ set: @escaping @MainActor (Time) -> Void) -> Widget {
        Widget(key: key, frame: frame, kind: .textField(MarkersPanelModel.timecode(t, frameDuration: fd)) { text in
            if let t = MarkersPanelModel.parseTimecode(text, frameDuration: fd) { set(t) }
        }, help: help)
    }

    private func maskTrackWidgets(_ id: ClipMask.ID, _ m: ClipMask, _ h: CGFloat, _ g: ControlsGrid, _ k: (String) -> String,
                                  _ remove: Widget) -> [Widget] {
        let on = m.enabled, ch = ControlsGrid.controlHeight
        if m.source == .magic {
            // One frame back, back to the start, Stop, on to the end, one frame forward, then the state line.
            let c = MaskTrackActivity.shared.magic
            let ready = on && model.playheadInClip && !c.isTracking
            var x = ControlsGrid.valueX
            var out: [Widget] = [Widget(key: k("label"), frame: g.labelFrame(height: h), kind: .text(SQL10n.string("Track"), nil, nil, .left))]
            let buttons: [(String, SQIcon, DrawColor?, Bool, String, @MainActor () -> Void)] = [
                ("stepBack", .chevronLeft, nil, ready, "Track One Frame Back", { [model] in model.onTrackMagic?(id, .step(forward: false)) }),
                ("back", .goToStart, nil, ready, "Track Backward to the Start", { [model] in model.onTrackMask?(id, false) }),
                ("stop", .stop, c.isTracking ? theme.accent : nil, c.isTracking, "Stop Tracking", { [model] in model.onTrackMagic?(id, nil) }),
                ("forward", .goToEnd, nil, ready, "Track Forward to the End", { [model] in model.onTrackMask?(id, true) }),
                ("stepForward", .chevronRight, nil, ready, "Track One Frame Forward", { [model] in model.onTrackMagic?(id, .step(forward: true)) }),
            ]
            for b in buttons {
                let f = g.controlFrame(x: x, width: ch, height: h)
                out.append(Widget(key: k(b.0), frame: f, kind: .icon(b.1, b.2), enabled: b.3, help: b.4, action: b.5))
                x = f.maxX + ControlsGrid.gap
            }
            out.append(Widget(key: k("status"), frame: CGRect(x: x, y: 0, width: max(remove.frame.minX - ControlsGrid.gap - x, 0), height: h),
                              kind: .text(c.statusText, theme.label2, CGFloat(DrawTheme.TypeSize.caption), .left)))
            out.append(remove)
            return out
        }
        // While a track runs (even from another playhead position) its button is a Stop button with the progress.
        let run = MaskTrackActivity.shared.run
        let mine = run?.mask == id ? run : nil
        let ready = on && model.playheadInClip && run == nil
        let back = g.controlFrame(x: ControlsGrid.valueX, width: ch, height: h)
        let forward = g.controlFrame(x: back.maxX + ControlsGrid.gap, width: ch, height: h)
        let tx = forward.maxX + ControlsGrid.gap
        let title = mine.map { $0.percent >= 0 ? "\($0.percent)%" : "…" } ?? SQL10n.string("Track")
        let backStops = mine.map { !$0.forward } ?? false, forwardStops = mine?.forward ?? false
        let modes = MaskTrackMode.allCases, current = model.maskTrackMode
        return [
            Widget(key: k("label"), frame: g.labelFrame(height: h), kind: .text(title, nil, nil, .left)),
            Widget(key: k("back"), frame: back, kind: .icon(backStops ? .stop : .stepBack, backStops ? theme.accent : nil),
                   enabled: mine.map { !$0.forward } ?? ready, help: "Track Mask Backward (click again to stop)") { [model] in
                model.onTrackMask?(id, false)
            },
            Widget(key: k("forward"), frame: forward, kind: .icon(forwardStops ? .stop : .stepForward, forwardStops ? theme.accent : nil),
                   enabled: mine.map(\.forward) ?? ready, help: "Track Mask Forward (click again to stop)") { [model] in
                model.onTrackMask?(id, true)
            },
            Widget(key: k("mode"), frame: g.controlFrame(x: tx, width: min(remove.frame.minX - ControlsGrid.gap - tx, ControlsMetrics.Portable.popupWidth),
                                                         height: h),
                   kind: .popup(SQL10n.string(current.title)), enabled: on, help: "What tracking follows", menu: { [model] in
                modes.map { md in SQMenuItem(title: md.title, isChecked: md == current) { model.maskTrackMode = md } }
            }),
            remove,
        ]
    }

    private func stabilizeWidgets(_ effect: ClipEffect.ID, _ h: CGFloat, _ k: (String) -> String) -> [Widget] {
        let state = model.stabilizeStatus(effect)
        let title: String, enabled: Bool, tip: String?, status: String
        var fraction: Double?
        switch state {
        case .analysing(let p):
            title = "Stop"; enabled = true; tip = "Stop the analysis"; fraction = p
            status = "\(Int((p * 100).rounded(.down))) %"
        case .working(let step): title = "Stop"; enabled = true; tip = "Stop the analysis"; status = step
        case .failed(let why): title = "Start Again"; enabled = true; tip = "Try the analysis again"; status = why
        case .notAnalysed, .analysed, .needsAnalysis:
            title = state == .notAnalysed ? "Start" : "Start Again"; enabled = true; tip = "Measure the camera shake of this clip"
            status = state == .analysed ? "Analyzed" : state == .needsAnalysis ? "New frames need analyzing" : "Not analyzed"
        case .blocked(let why): title = "Start"; enabled = false; tip = why; status = why
        }
        let bh = CGFloat(InspectorTokens.capsule), lh = ControlsGrid.labelHeight
        let button = CGRect(x: ControlsGrid.valueX, y: ((h - bh) / 2).rounded(), width: max(estimatedButtonWidth(title), 72), height: bh)
        let x = button.maxX + ControlsGrid.gap, w = max(size.width - x - ControlsGrid.trailing, 0)
        var out = [Widget(key: k("button"), frame: button, kind: .button(title), enabled: enabled, help: tip) { [model] in
            model.analyzeOrCancelStabilizer(effect)
        }]
        let caption = CGFloat(DrawTheme.TypeSize.caption)
        if let fraction {
            let pct: CGFloat = 36
            let bar = CGRect(x: x, y: (h - 4) / 2, width: max(w - pct - ControlsGrid.gap, 0), height: 4)
            out.append(Widget(key: k("progress"), frame: bar, kind: .progress(fraction)))
            out.append(Widget(key: k("status"), frame: CGRect(x: bar.maxX + ControlsGrid.gap, y: (h - lh) / 2, width: pct, height: lh),
                              kind: .text(status, theme.label3, caption, .left)))
        } else {
            out.append(Widget(key: k("status"), frame: CGRect(x: x, y: (h - lh) / 2, width: w, height: lh),
                              kind: .text(SQL10n.string(status), theme.label3, caption, .left), help: status))
        }
        return out
    }

    /// ColorRangeMaskRow.colorChanged: a pick is one undo step, ended when the picker closes.
    private func pickMaskColor(_ id: ClipMask.ID, anchorKey: String) {
        guard let key = model.colorRange(of: id) else { return }
        var began = false
        let anchor = widgetFrameInPanel(anchorKey) ?? .zero
        onPickColor?(EffectColor(red: key.red, green: key.green, blue: key.blue, alpha: 1), anchor) { [weak self] color in
            guard let self else { return }
            guard let c = color?.clamped else { if began { self.model.endGesture() }; return }
            if !began { self.model.beginGesture(); began = true }
            let k = self.model.colorRange(of: id) ?? key
            self.model.setMaskColorRange(id, ColorRangeKey(red: c.red, green: c.green, blue: c.blue, tolerance: k.tolerance, softness: k.softness))
        }
    }

    /// A widget's frame in panel points (the anchor of its popup or picker).
    func widgetFrameInPanel(_ key: String) -> CGRect? {
        for r in rows {
            guard let w = widgets(r)?.first(where: { $0.key == key }) else { continue }
            return w.frame.offsetBy(dx: 0, dy: rowTopInPanel(r))
        }
        return nil
    }

    // MARK: Drawing

    func drawWidgets(_ r: EffectRow, _ ws: [Widget], _ c: inout Canvas, hover: Target) {
        let t = theme, h = r.height
        let fill: DrawColor
        switch r.kind {
        case .colorGroup, .eqCurveHeader, .multibandParams, .trackMaskTrack: fill = t.panel
        case .multiband, .colorMatch, .gradeRange, .gradeFade, .colorGraph, .curves, .eqCurve: fill = t.content
        default: fill = t.panel
        }
        c.fill(CGRect(x: 0, y: 0, width: size.width, height: h), fill)
        c.fill(CGRect(x: 0, y: h - 1, width: size.width, height: 1), t.trackRowLine)
        let body = CGFloat(DrawTheme.TypeSize.body)
        for w in ws {
            let hovered = hover == .widget(w.key), pressed = pressTarget == .widget(w.key)
            let a: Float = w.enabled ? 1 : InspectorTokens.disabledAlpha
            switch w.kind {
            case .text(let s, let color, let fs, let align):
                let size = fs ?? body
                let col = color ?? t.label2
                let text = Self.middleCut(s, width: w.frame.width) { c.size(of: $0, fontSize: size).width }
                c.draw(text, in: w.frame, fontSize: size, col.alpha(col.a * a), align: align.listAlign)
            case .check(let title, let state):
                let s = InspectorTokens.checkbox
                let box = CGRect(x: w.frame.minX, y: (w.frame.midY - s / 2).rounded(), width: s, height: s)
                InspectorDraw.checkbox(&c, state, box: box, hovering: hovered, pressed: pressed, enabled: w.enabled, t)
                if !title.isEmpty {
                    c.draw(SQL10n.string(title), in: CGRect(x: box.maxX + 5, y: w.frame.minY, width: max(w.frame.width - s - 5, 0), height: w.frame.height),
                           fontSize: body, t.label.alpha(t.label.a * a))
                }
            case .popup(let title):
                InspectorDraw.popup(&c, title: title, in: w.frame, hovering: hovered, open: false, enabled: w.enabled, t)
            case .icon(let i, let tint):
                icon(&c, i, in: w.frame, size: 12, buttonTint(tint, hovered: hovered, enabled: w.enabled))
            case .button(let title):
                InspectorDraw.button(&c, title: SQL10n.string(title), in: w.frame, hovering: hovered, pressed: pressed, enabled: w.enabled, t)
            case .progress(let f): InspectorDraw.progress(&c, fraction: f, in: w.frame, t)
            case .well(let col):
                InspectorDraw.colorWell(&c, w.enabled ? col : col.alpha(InspectorTokens.disabledAlpha), in: w.frame, hovering: hovered, t)
            case .field:
                let id = FieldID(ref: .custom(w.key), component: .all)
                fields[id]?.draw(&c, in: w.frame, theme: t, focused: focusedField == id)
            case .textField:
                var f = textFields[w.key] ?? TextFieldControl()
                f.hovering = hovered
                f.draw(&c, in: w.frame, theme: t, focused: focusedText == w.key)
            case .disclosure(let title, let open, let on):
                if hovered { c.fill(w.frame, t.fillHover) }
                c.fill(CGRect(x: 0, y: 0, width: size.width, height: 1), t.separator)
                let slot = CGRect(x: ControlsGrid.toggleX, y: 0, width: ControlsGrid.toggleWidth, height: h)
                InspectorDraw.chevron(&c, in: slot, direction: open ? .down : .right, t.label3)
                var maxX = w.frame.maxX - ControlsGrid.trailing
                if let on, let box = w.toggleFrame {
                    InspectorDraw.checkbox(&c, on ? .on : .off, box: box, hovering: hover == .widgetToggle(w.key),
                                           pressed: pressTarget == .widgetToggle(w.key), enabled: true, t)
                    maxX = box.minX - ControlsGrid.gap
                }
                // shortcut: bodyStrong draws in the regular face (one atlas face); upgrade with a bold atlas face.
                c.draw(title, in: CGRect(x: ControlsGrid.labelX, y: 0, width: max(maxX - ControlsGrid.labelX, 0), height: h), fontSize: body,
                       on == false ? t.label3 : t.label)
            case .ring(let state):
                InspectorDraw.ring(&c, state.showsNavigation ? .onKey : .none, hovering: hovered,
                                   center: CGPoint(x: w.frame.midX, y: w.frame.midY), t)
            case .navigation(let state):
                InspectorDraw.navigation(&c, state, in: w.frame, enabled: true, t)
            case .hit: break
            case .surface(let make):
                surface(w.key, make).draw(&c, in: w.frame, theme: t, panel: self)
            }
        }
    }

    func surface(_ key: String, _ make: @escaping @MainActor () -> DrawSurface) -> DrawSurface {
        if let s = surfaces[key] { return s }
        let s = make()
        surfaces[key] = s
        return s
    }
}

/// A drawn editor inside a row (curves, EQ curve): draws itself and takes the pointer while pressed. Points are row
/// coordinates; `rect` is the surface's frame in the row.
@MainActor protocol DrawSurface: AnyObject {
    func draw(_ c: inout Canvas, in rect: CGRect, theme: DrawTheme, panel: EffectControlsDrawPanel)
    func mouseDown(at p: CGPoint, in rect: CGRect, clickCount: Int, modifiers: InputModifiers)
    func mouseDragged(to p: CGPoint, in rect: CGRect, modifiers: InputModifiers)
    func mouseUp(at p: CGPoint, in rect: CGRect)
    func mouseMoved(to p: CGPoint?, in rect: CGRect)
    func help(at p: CGPoint, in rect: CGRect) -> String?
    /// Wheel over the surface; true when it used it (otherwise the panel scrolls).
    func scroll(at p: CGPoint, in rect: CGRect, dy: CGFloat) -> Bool
}

extension DrawSurface {
    func mouseMoved(to p: CGPoint?, in rect: CGRect) {}
    func help(at p: CGPoint, in rect: CGRect) -> String? { nil }
    func scroll(at p: CGPoint, in rect: CGRect, dy: CGFloat) -> Bool { false }
}
