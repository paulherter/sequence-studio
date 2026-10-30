import SQRender

extension MonitorPanelModel {
    /// How the monitors show Rec.709 (Mac 1.96, Web 2.2, Broadcast 2.4): a preview of the display, export is unchanged.
    /// Shared by Source and Program (one presenter state); session-only.
    public var viewGamma: ViewGamma { viewGammaID.flatMap(ViewGamma.init(rawValue:)) ?? .current }
    public func setViewGamma(_ g: ViewGamma) { viewGammaID = g.rawValue; ViewGamma.current = g }
    /// Which display the monitors preview for (SDR, P3, HDR 1000 nit, not tone-mapped); a view only, export is unchanged.
    public var displayView: DisplayView { displayViewID.flatMap(DisplayView.init(rawValue:)) ?? .current }
    public func setDisplayView(_ v: DisplayView) { displayViewID = v.rawValue; DisplayView.current = v }
}
