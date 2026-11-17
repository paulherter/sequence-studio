// Stand-in for the outline point type SfntVariations.swift reads (GlyphRaster.swift needs the whole font reader).
enum GlyphRasterFont { struct Point { var x: Double, y: Double, onCurve: Bool } }
