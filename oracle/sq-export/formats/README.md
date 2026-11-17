# sq-export formats oracle

`golden/`: output of the real Swift writers (EDLWriter, FCPXMLWriter, XMEMLWriter, OTIOWriter, SRTWriter, VTTWriter,
ITTWriter, MarkerCSV, YouTubeChapters) for the scenarios in `swift-dump/main.swift`: `<name>.out` is the file text,
`<name>.warn` the warnings joined by newline. `urls.tsv` is `URL(fileURLWithPath:).absoluteString` for every ASCII
character in a path. The Rust tests (`crates/sq-export/src/formats/tests.rs`) mirror the scenarios and compare byte for byte.

Regenerate: `oracle/sq-export/formats/run.sh` (needs Xcode; builds a scratch package outside the repo that symlinks the
writer sources and depends on SQCore and SQText, about 3 minutes). Change the Swift and the Rust scenario together.

Known differences: a path with a precomposed accent is not decomposed (Foundation writes `e` + U+0301); speed ramps
(`speedKeys`) are not in the scenarios.
