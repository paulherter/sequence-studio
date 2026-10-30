// The one icon registry of the app (DECISIONS 2026-10-10). Lucide glyphs (ISC) plus own drawings, see docs/THIRD_PARTY.md.
// Cases are semantic names. Nothing else in the code base may load icon files or use SF Symbols.

public enum SQIcon: String, CaseIterable, Sendable {
    /// Text panel: style toggles, vertical alignment, direction, shadow angle (graphic layer system, step 1).
    case textBold, textItalic, textUnderline, textStrikethrough, textOverline, textCaseUpper
    case textTop, textMiddle, textBottom, textLTR, textRTL, shadowAngle
    case chevronRight, chevronDown, chevronUp, chevronLeft, goToStart, goToEnd, arrowDownToLine, arrowUpToLine
    case arrowUpFromLine, arrowRightToLine, arrowLeftToLine, stepBack, stepForward, play, pause, stop
    case playCircle, playRectangle, marker, markerOff, insertEdit, overwriteEdit, camera, heart
    case discord, mail, code, close, closeCircle, closeCircleFilled, trash, folder, folderFilled
    case folderAdd, folderRemove, eye, eyeOff, trackLock, trackUnlock, trackSyncLock, link
    case unlink, plus, minus, ellipsis, search, zoomIn, zoomOut, zoomSparkle
    case star, starFilled, starOff, grid, list, grid3, reset, rotateCW
    case refresh, copy, paste, pasteInsert, file, download, upload, toolBlade
    case bladeBadge, paintbrush, pencil, pen, draw, toolMask, sparkles, text
    case textAlignLeft, textAlignCenter, textAlignRight, alignLeft, alignCenterH, alignRight, alignTop, alignCenterV
    case alignBottom, distributeH, distributeV, shapeRectangle, shapeEllipse, shapeLine, arrowRight, arrowUpRight
    case arrowDownRight, moveHorizontal, moveVertical, move, maximize, minimize, flipHorizontal, pushRight
    case slideOut, openExternal, merge, swap, film, sequence, stack, generator
    case group, ungroup, bundle, unbundle, duplicate, waveform, waveformLines, activity
    case microphone, voice, volume, volumeLow, volumeOff, image, imageRemove, slidersVertical
    case slidersHorizontal, chartBars, chartLine, zapOff, zap, foldVertical, unfoldVertical, loop
    case landmark, drama, circleDotted, wind, triangle, sunRays, circleDashed, contrast
    case palette, sunDim, sunMedium, lightbulb, droplet, aperture, circleDot, tornado
    case waves, checkerboard, grain, moon, squareDashed, panelBottom, flower, columns3
    case columns2, hexagon, crop, roundedSquare, scan, vibrate, radio, timer
    case calendarClock, menu, user, gauge, captions, tag, bookmark, bookmarkFilled
    case checkCircle, checkCircleFilled, equal, plusCircle, minusCircle, addRectangle, warning, clock
    case uploadCircle, stopCircle, settings, findFolder, power, powerOn, powerOff, unknown
    case driveOffline, package, diamond, curve, toolHand, pointerHand, toolSelect, markClip
    case openInSource, timelineSelection, viewfinder, keyboard, eyedropper, tv, cloud, check
    case share, home, book, snap, toolSlip, toolSlide, toolRipple, toolRoll
    case toolRateStretch, keyframe, pageEdit, pageColor, markIn, markOut, markInOut

    /// Closed shapes are filled as well as stroked (play, pause, stop, heart, star, folder, bookmark).
    public var isFilled: Bool {
        switch self {
        case .play, .pause, .stop, .heart, .folderFilled, .starFilled, .bookmarkFilled: true
        default: false
        }
    }
}
