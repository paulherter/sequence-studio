//! Test support: a builder of small synthetic Premiere project XML with the same object graph as real files (flat objects,
//! ObjectRef/ObjectURef), and a minimal FlatBuffer writer for the text blob tests. Swift: PRFixture.swift.
//! Never a real project: shapes copied from docs/PRPROJ-IMPORT.md section 1.
#![allow(dead_code, reason = "shared by several test binaries, each uses a part")]
#![allow(clippy::unwrap_used, reason = "helpers of integration tests; clippy.toml only covers test functions")]

use std::collections::BTreeMap;

pub const SECOND: i64 = 254_016_000_000;
const STATIC_TIME: &str = "-91445760000000000";

/// What an item plays.
pub enum Source {
    Media(String),
    Sequence(String),
    Graphic,
    /// Color matte; the hex of its `ImporterPrefs` bytes, if any.
    Matte(Option<String>),
}

/// Everything `PRFixture::item` takes; build with `ItemSpec::new` and the chained setters.
pub struct ItemSpec {
    pub start: Option<i64>,
    pub end: i64,
    pub in_point: i64,
    pub out_point: i64,
    pub speed: Option<f64>,
    pub source: Source,
    pub components: Vec<String>,
    pub audio: bool,
    pub adjustment: bool,
    pub name: String,
    pub gain: Option<f64>,
    pub markers: Vec<String>,
}

impl ItemSpec {
    pub fn new(start: i64, end: i64, in_point: i64, out_point: i64, source: Source) -> ItemSpec {
        ItemSpec {
            start: Some(start),
            end,
            in_point,
            out_point,
            speed: None,
            source,
            components: Vec::new(),
            audio: false,
            adjustment: false,
            name: "clip".into(),
            gain: None,
            markers: Vec::new(),
        }
    }

    pub fn speed(mut self, s: f64) -> Self {
        self.speed = Some(s);
        self
    }

    pub fn components(mut self, c: &[&str]) -> Self {
        self.components = c.iter().map(|s| (*s).to_string()).collect();
        self
    }

    pub fn audio(mut self) -> Self {
        self.audio = true;
        self
    }

    pub fn adjustment(mut self) -> Self {
        self.adjustment = true;
        self
    }

    pub fn name(mut self, n: &str) -> Self {
        self.name = n.into();
        self
    }

    pub fn gain(mut self, g: f64) -> Self {
        self.gain = Some(g);
        self
    }

    pub fn markers(mut self, m: &[String]) -> Self {
        self.markers = m.to_vec();
        self
    }

    pub fn no_start(mut self) -> Self {
        self.start = None;
        self
    }
}

#[derive(Default)]
pub struct MediaSpec<'a> {
    pub par: Option<&'a str>,
    pub color_profile: Option<&'a str>,
    pub actual: Option<&'a str>,
    pub relative: Option<&'a str>,
}

pub struct PRFixture {
    objects: Vec<String>,
    next: i64,
}

impl Default for PRFixture {
    fn default() -> Self {
        PRFixture { objects: Vec::new(), next: 100 }
    }
}

impl PRFixture {
    pub fn new() -> PRFixture {
        PRFixture::default()
    }

    fn new_id(&mut self) -> String {
        self.next += 1;
        self.next.to_string()
    }

    fn new_uid(&mut self) -> String {
        self.next += 1;
        format!("00000000-0000-0000-0000-{:012}", self.next)
    }

    pub fn xml(&self) -> String {
        format!(
            "<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n<PremiereData Version=\"3\">\n{}\n</PremiereData>\n",
            self.objects.join("\n")
        )
    }

    pub fn data(&self) -> Vec<u8> {
        self.xml().into_bytes()
    }

    pub fn media(&mut self, path: &str, title: &str) -> String {
        self.media_with(path, title, &MediaSpec::default())
    }

    /// `par` ("160,121") and `color_profile` go into a referenced VideoStream (OriginalPAR / OriginalColorSpace JSON).
    /// `actual`: a different ActualMediaFilePath (FilePath stays `path`); `relative`: a RelativePath element.
    pub fn media_with(&mut self, path: &str, title: &str, spec: &MediaSpec) -> String {
        let uid = self.new_uid();
        let mut stream_xml = String::new();
        if spec.par.is_some() || spec.color_profile.is_some() {
            let sid = self.new_id();
            let par = spec.par.map(|p| format!("<OriginalPAR>{p}</OriginalPAR>")).unwrap_or_default();
            let cs = spec
                .color_profile
                .map(|c| format!("<OriginalColorSpace>{{&quot;baseColorProfile&quot;:{{&quot;colorProfileName&quot;:&quot;{c}&quot;}}}}</OriginalColorSpace>"))
                .unwrap_or_default();
            self.objects.push(format!("<VideoStream ObjectID=\"{sid}\" Version=\"5\">{par}{cs}</VideoStream>"));
            stream_xml = format!("<VideoStream ObjectRef=\"{sid}\"/>");
        }
        let relative = spec.relative.map(|r| format!("<RelativePath>{r}</RelativePath>")).unwrap_or_default();
        self.objects.push(format!(
            "<Media ObjectUID=\"{uid}\" Version=\"30\"><ActualMediaFilePath>{}</ActualMediaFilePath><FilePath>{path}</FilePath>{relative}<Title>{title}</Title>{stream_xml}</Media>",
            spec.actual.unwrap_or(path)
        ));
        uid
    }

    /// A parameter object; `value` is the static value, `keys` the raw `Keyframes` string.
    pub fn param(&mut self, pid: Option<i64>, value: &str, keys: Option<&str>, kind: &str) -> String {
        let id = self.new_id();
        let pid_xml = pid.map(|p| format!("<ParameterID>{p}</ParameterID>")).unwrap_or_default();
        let keys_xml = keys.map(|k| format!("<Keyframes>{k}</Keyframes>")).unwrap_or_default();
        self.objects.push(format!(
            "<{kind} ObjectID=\"{id}\" Version=\"10\">{pid_xml}<Name>P</Name><StartKeyframe>{STATIC_TIME},{value},0,0,0,0,0,0</StartKeyframe>{keys_xml}</{kind}>"
        ));
        id
    }

    /// A scalar video param.
    pub fn p(&mut self, pid: i64, value: &str) -> String {
        self.param(Some(pid), value, None, "VideoComponentParam")
    }

    /// A keyed scalar video param.
    pub fn pk(&mut self, pid: i64, value: &str, keys: &str) -> String {
        self.param(Some(pid), value, Some(keys), "VideoComponentParam")
    }

    /// A point video param.
    pub fn pt(&mut self, pid: i64, value: &str) -> String {
        self.param(Some(pid), value, None, "PointComponentParam")
    }

    pub fn blob_param(&mut self, pid: i64, base64: &str, hash: &str) -> String {
        let id = self.new_id();
        self.objects.push(format!(
            "<ArbVideoComponentParam ObjectID=\"{id}\" Version=\"3\"><ParameterID>{pid}</ParameterID><Name>Source Text</Name><StartKeyframeValue Encoding=\"base64\" BinaryHash=\"{hash}\">{base64}</StartKeyframeValue></ArbVideoComponentParam>"
        ));
        id
    }

    pub fn component(&mut self, match_name: &str, params: &[String]) -> String {
        let id = self.new_id();
        let ps: String =
            params.iter().enumerate().map(|(i, p)| format!("<Param Index=\"{i}\" ObjectRef=\"{p}\"/>")).collect();
        self.objects.push(format!(
            "<VideoFilterComponent ObjectID=\"{id}\" Version=\"9\"><Component Version=\"7\"><Params Version=\"1\">{ps}</Params><DisplayName>{match_name}</DisplayName></Component><MatchName>{match_name}</MatchName></VideoFilterComponent>"
        ));
        id
    }

    pub fn audio_component(&mut self, display_name: &str, match_name: &str, params: &[String]) -> String {
        let id = self.new_id();
        let ps: String =
            params.iter().enumerate().map(|(i, p)| format!("<Param Index=\"{i}\" ObjectRef=\"{p}\"/>")).collect();
        self.objects.push(format!(
            "<AudioFilterComponent ObjectID=\"{id}\" Version=\"9\"><AudioComponent><Component><Params>{ps}</Params><DisplayName>{display_name}</DisplayName></Component></AudioComponent><FilterMatchName>{match_name}</FilterMatchName></AudioFilterComponent>"
        ));
        id
    }

    pub fn item(&mut self, spec: ItemSpec) -> String {
        let chain = self.new_id();
        let comps: String = spec
            .components
            .iter()
            .enumerate()
            .map(|(i, c)| format!("<Component Index=\"{i}\" ObjectRef=\"{c}\"/>"))
            .collect();
        let kind = if spec.audio { "Audio" } else { "Video" };
        self.objects.push(format!("<{kind}ComponentChain ObjectID=\"{chain}\"><ComponentChain><Components>{comps}</Components></ComponentChain></{kind}ComponentChain>"));
        let src = self.new_id();
        let media_source = |uid: &str| {
            format!(
                "<{kind}MediaSource ObjectID=\"{src}\"><MediaSource><Media ObjectURef=\"{uid}\"/></MediaSource></{kind}MediaSource>"
            )
        };
        match &spec.source {
            Source::Media(uid) => self.objects.push(media_source(uid)),
            Source::Graphic => {
                let uid = self.new_uid();
                self.objects.push(format!("<Media ObjectUID=\"{uid}\"><Infinite>true</Infinite><ActualMediaFilePath>1196574294</ActualMediaFilePath><Title>Graphic</Title></Media>"));
                self.objects.push(media_source(&uid));
            }
            Source::Matte(hex) => {
                let uid = self.new_uid();
                let prefs = hex
                    .as_ref()
                    .map(|h| {
                        let bytes: Vec<u8> =
                            (0..h.len()).step_by(2).filter_map(|i| u8::from_str_radix(&h[i..i + 2], 16).ok()).collect();
                        format!(
                            "<ImporterPrefs Encoding=\"base64\" BinaryHash=\"h{}\">{}</ImporterPrefs>",
                            &uid[uid.len() - 4..],
                            sq_core_time::base64::encode(&bytes)
                        )
                    })
                    .unwrap_or_default();
                self.objects.push(format!("<Media ObjectUID=\"{uid}\">{prefs}<Infinite>true</Infinite><ActualMediaFilePath>1129270354</ActualMediaFilePath><Title>Farbfl\u{E4}che</Title></Media>"));
                self.objects.push(media_source(&uid));
            }
            Source::Sequence(uid) => {
                self.objects.push(format!("<{kind}SequenceSource ObjectID=\"{src}\"><SequenceSource><Sequence ObjectURef=\"{uid}\"/></SequenceSource></{kind}SequenceSource>"));
            }
        }
        let clip = self.new_id();
        let speed_xml = spec.speed.map(|s| format!("<PlaybackSpeed>{s}</PlaybackSpeed>")).unwrap_or_default();
        let adj = if spec.adjustment { "<AdjustmentLayer>true</AdjustmentLayer>" } else { "" };
        let clip_markers = self.marker_owner(&spec.markers);
        let gain = spec.gain.map(|g| format!("<Gain>{g}</Gain>")).unwrap_or_default();
        self.objects.push(format!(
            "<{kind}Clip ObjectID=\"{clip}\"><Clip>{clip_markers}<Source ObjectRef=\"{src}\"/><InPoint>{}</InPoint><OutPoint>{}</OutPoint>{speed_xml}</Clip>{adj}{gain}</{kind}Clip>",
            spec.in_point, spec.out_point
        ));
        let sub = self.new_id();
        self.objects.push(format!(
            "<SubClip ObjectID=\"{sub}\"><Clip ObjectRef=\"{clip}\"/><Name>{}</Name></SubClip>",
            spec.name
        ));
        let item = self.new_id();
        let start_xml = spec.start.map(|s| format!("<Start>{s}</Start>")).unwrap_or_default();
        self.objects.push(format!(
            "<{kind}ClipTrackItem ObjectID=\"{item}\"><ClipTrackItem><ComponentOwner><Components ObjectRef=\"{chain}\"/></ComponentOwner><TrackItem><Node/>{start_xml}<End>{}</End></TrackItem><SubClip ObjectRef=\"{sub}\"/></ClipTrackItem></{kind}ClipTrackItem>",
            spec.end
        ));
        item
    }

    pub fn transition(&mut self, start: i64, end: i64, match_name: &str) -> String {
        let id = self.new_id();
        self.objects.push(format!(
            "<VideoTransitionTrackItem ObjectID=\"{id}\"><TransitionItem><TrackItem><Start>{start}</Start><End>{end}</End></TrackItem></TransitionItem><MatchName>{match_name}</MatchName></VideoTransitionTrackItem>"
        ));
        id
    }

    pub fn track(&mut self, items: &[String]) -> String {
        self.track_with(items, &[], false, false)
    }

    pub fn audio_track(&mut self, items: &[String]) -> String {
        self.track_with(items, &[], true, false)
    }

    pub fn track_with(&mut self, items: &[String], transitions: &[String], audio: bool, muted: bool) -> String {
        let uid = self.new_uid();
        let kind = if audio { "Audio" } else { "Video" };
        let its: String =
            items.iter().enumerate().map(|(i, x)| format!("<TrackItem Index=\"{i}\" ObjectRef=\"{x}\"/>")).collect();
        let trs: String = transitions
            .iter()
            .enumerate()
            .map(|(i, x)| format!("<TrackItem Index=\"{i}\" ObjectRef=\"{x}\"/>"))
            .collect();
        let mute = if muted { "<IsMuted>true</IsMuted>" } else { "" };
        self.objects.push(format!(
            "<{kind}ClipTrack ObjectUID=\"{uid}\"><ClipTrack><Track><ID>1</ID>{mute}</Track><ClipItems><TrackItems>{its}</TrackItems></ClipItems><TransitionItems><TrackItems>{trs}</TrackItems></TransitionItems></ClipTrack></{kind}ClipTrack>"
        ));
        uid
    }

    /// A 1080x1920 sequence at 8467200000 ticks per frame.
    pub fn sequence(&mut self, name: &str, video: &[String], audio: &[String]) -> String {
        self.sequence_with(name, 8_467_200_000, 1080, 1920, video, audio, None, &[])
    }

    #[allow(clippy::too_many_arguments, reason = "mirrors the Swift fixture's parameter list")]
    pub fn sequence_with(
        &mut self,
        name: &str,
        ticks_per_frame: i64,
        width: i64,
        height: i64,
        video: &[String],
        audio: &[String],
        uid: Option<&str>,
        markers: &[String],
    ) -> String {
        let uid = uid.map_or_else(|| self.new_uid(), str::to_string);
        let marker_xml = self.marker_owner(markers);
        let (vg, ag) = (self.new_id(), self.new_id());
        let vt: String =
            video.iter().enumerate().map(|(i, x)| format!("<Track Index=\"{i}\" ObjectURef=\"{x}\"/>")).collect();
        let at: String =
            audio.iter().enumerate().map(|(i, x)| format!("<Track Index=\"{i}\" ObjectURef=\"{x}\"/>")).collect();
        self.objects.push(format!("<VideoTrackGroup ObjectID=\"{vg}\"><TrackGroup><Tracks>{vt}</Tracks><FrameRate>{ticks_per_frame}</FrameRate></TrackGroup><FrameRect>0,0,{width},{height}</FrameRect></VideoTrackGroup>"));
        self.objects.push(format!("<AudioTrackGroup ObjectID=\"{ag}\"><TrackGroup><Tracks>{at}</Tracks><FrameRate>5292000</FrameRate></TrackGroup></AudioTrackGroup>"));
        self.objects.push(format!("<Sequence ObjectUID=\"{uid}\"><Name>{name}</Name>{marker_xml}<TrackGroups><TrackGroup Index=\"0\"><First>a</First><Second ObjectRef=\"{vg}\"/></TrackGroup><TrackGroup Index=\"1\"><First>b</First><Second ObjectRef=\"{ag}\"/></TrackGroup></TrackGroups></Sequence>"));
        uid
    }

    /// `<MarkerOwner>` pointing at a Markers object with one Marker object per DVAMarker JSON; "" for none.
    fn marker_owner(&mut self, markers: &[String]) -> String {
        if markers.is_empty() {
            return String::new();
        }
        let mut refs = String::new();
        for (i, json) in markers.iter().enumerate() {
            let id = self.new_id();
            self.objects.push(format!("<Marker ObjectID=\"{id}\"><DVAMarker>{json}</DVAMarker></Marker>"));
            refs += &format!("<Marker Index=\"{i}\"><First>g{i}</First><Second ObjectRef=\"{id}\"/></Marker>");
        }
        let mid = self.new_id();
        self.objects.push(format!("<Markers ObjectID=\"{mid}\"><Markers>{refs}</Markers></Markers>"));
        format!("<MarkerOwner><Markers ObjectRef=\"{mid}\"/></MarkerOwner>")
    }

    /// A clip marker as Premiere writes one whose only change is its time.
    pub fn plain_marker(ticks: i64) -> String {
        format!(
            "{{&quot;DVAMarker&quot;:{{&quot;mMarkerID&quot;:&quot;m{ticks}&quot;,&quot;mStartTime&quot;:{{&quot;ticks&quot;:{ticks}}},&quot;mType&quot;:&quot;Comment&quot;}}}}"
        )
    }

    /// A UID for a sequence declared later (nesting refers forward).
    pub fn reserve_uid(&mut self) -> String {
        self.new_uid()
    }
}

/// Shadow parameters of the text blob writer.
pub struct ShadowSpec {
    pub rgb: (u8, u8, u8),
    pub on: bool,
    pub opacity: f32,
    pub distance: f32,
    pub angle: f32,
    pub size: f32,
    pub blur: f32,
}

/// Background parameters of the text blob writer.
pub struct BackgroundSpec {
    pub rgb: (u8, u8, u8),
    pub on: bool,
    pub opacity: f32,
    pub size: f32,
    pub radius: f32,
}

/// Minimal FlatBuffer writer: tables laid out front to back with patched offsets.
#[derive(Default)]
pub struct FlatBlob {
    pub bytes: Vec<u8>,
}

impl FlatBlob {
    fn align4(&mut self) {
        while !self.bytes.len().is_multiple_of(4) {
            self.bytes.push(0);
        }
    }

    fn u32(&mut self, v: u32) {
        self.bytes.extend_from_slice(&v.to_le_bytes());
    }

    fn u16(&mut self, v: u16) {
        self.bytes.extend_from_slice(&v.to_le_bytes());
    }

    /// Writes a table whose fields are all 4 bytes wide; returns the table position and each field's absolute position.
    fn table(&mut self, field_count: usize, present: &[usize]) -> (usize, BTreeMap<usize, usize>) {
        self.align4();
        let vt = self.bytes.len();
        self.u16((4 + 2 * field_count) as u16);
        self.u16((4 + 4 * present.len()) as u16);
        let mut offs = BTreeMap::new();
        for i in 0..field_count {
            if let Some(k) = present.iter().position(|&p| p == i) {
                offs.insert(i, 4 + 4 * k);
                self.u16((4 + 4 * k) as u16);
            } else {
                self.u16(0);
            }
        }
        self.align4();
        let t = self.bytes.len();
        self.u32((t - vt) as u32); // soffset: vtable = table - soffset
        for _ in present {
            self.u32(0);
        }
        (t, offs.into_iter().map(|(k, v)| (k, t + v)).collect())
    }

    /// A color table as Premiere writes it: fields 0, 1, 2 are one byte each, packed next to each other (offsets 4, 5, 6),
    /// followed by an unrelated byte, so a 4-byte read of a channel picks up its neighbors.
    fn packed_colour_table(&mut self, rgb: (u8, u8, u8)) -> usize {
        self.align4();
        let vt = self.bytes.len();
        for v in [10u16, 8, 4, 5, 6] {
            self.u16(v);
        }
        self.align4();
        let t = self.bytes.len();
        self.u32((t - vt) as u32);
        self.bytes.extend_from_slice(&[rgb.0, rgb.1, rgb.2, 0x0a]);
        t
    }

    fn set_u32(&mut self, at: usize, v: u32) {
        self.bytes[at..at + 4].copy_from_slice(&v.to_le_bytes());
    }

    fn set_f32(&mut self, at: usize, v: f32) {
        self.set_u32(at, v.to_bits());
    }

    /// Points the uoffset at `at` to `target` (absolute).
    fn link(&mut self, at: usize, target: usize) {
        self.set_u32(at, (target - at) as u32);
    }

    fn string(&mut self, s: &str) -> usize {
        self.align4();
        let p = self.bytes.len();
        self.u32(s.len() as u32);
        self.bytes.extend_from_slice(s.as_bytes());
        self.bytes.push(0);
        p
    }

    /// A vector of uoffsets; returns (vector position, element slot positions).
    fn vector(&mut self, count: usize) -> (usize, Vec<usize>) {
        self.align4();
        let p = self.bytes.len();
        self.u32(count as u32);
        let slots = (0..count).map(|i| p + 4 + 4 * i).collect();
        for _ in 0..count {
            self.u32(0);
        }
        (p, slots)
    }

    /// The Premiere text blob for one run of `text` in `font` at `size` with `tracking`.
    pub fn premiere_text(
        text: &str,
        font: &str,
        size: f32,
        tracking: f32,
        shadow: Option<ShadowSpec>,
        background: Option<BackgroundSpec>,
    ) -> Vec<u8> {
        let mut b = FlatBlob::default();
        b.u32(0); // root uoffset, patched
        let root = b.table(1, &[0]);
        b.link(0, root.0);
        let mut present = vec![0usize, 1];
        if shadow.is_some() {
            present.extend([10, 11, 12, 15, 16, 20, 34]);
        }
        if let Some(bg) = &background {
            present.extend([13, 14, 17, 19]);
            if bg.on {
                present.push(18);
            }
        }
        present.sort_unstable();
        let main = b.table(present.iter().max().copied().unwrap_or(0) + 1, &present);
        if let Some(bg) = &background {
            if bg.on {
                b.bytes[main.1[&18]] = 1;
            }
            b.set_f32(main.1[&19], bg.opacity);
            b.set_f32(main.1[&13], bg.size);
            b.set_f32(main.1[&14], bg.radius);
            let colour = b.packed_colour_table(bg.rgb);
            b.link(main.1[&17], colour);
        }
        b.link(root.1[&0], main.0);
        if let Some(sh) = &shadow {
            b.bytes[main.1[&11]] = u8::from(sh.on);
            b.set_f32(main.1[&12], sh.opacity);
            b.set_f32(main.1[&15], sh.size);
            b.set_f32(main.1[&16], sh.blur);
            b.set_f32(main.1[&20], sh.angle);
            b.set_f32(main.1[&34], sh.distance);
            let colour = b.table(3, &[0, 1, 2]);
            b.link(main.1[&10], colour.0);
            b.bytes[colour.1[&0]] = sh.rgb.0;
            b.bytes[colour.1[&1]] = sh.rgb.1;
            b.bytes[colour.1[&2]] = sh.rgb.2;
        }
        let runs = b.vector(1);
        b.link(main.1[&0], runs.0);
        let run = b.table(2, &[0, 1]);
        b.link(runs.1[0], run.0);
        let style = b.table(9, &[1, 8]);
        b.link(run.1[&1], style.0);
        b.set_f32(style.1[&1], size);
        b.set_f32(style.1[&8], tracking);
        let s = b.string(text);
        b.link(run.1[&0], s);
        let fonts = b.vector(1);
        b.link(main.1[&1], fonts.0);
        let f = b.string(font);
        b.link(fonts.1[0], f);
        b.wrapped()
    }

    /// A blob with several runs (text, font index into `fonts`, size): style table field 0 = font index (omitted for 0), 1 =
    /// size, as in TCL C8L's 'Bis zu\r3.200' (line 1 Regular 136, line 2 Bold 195).
    pub fn premiere_runs(runs: &[(&str, usize, f32)], fonts: &[&str]) -> Vec<u8> {
        let mut b = FlatBlob::default();
        b.u32(0);
        let root = b.table(1, &[0]);
        b.link(0, root.0);
        let main = b.table(2, &[0, 1]);
        b.link(root.1[&0], main.0);
        let vec = b.vector(runs.len());
        b.link(main.1[&0], vec.0);
        for (i, r) in runs.iter().enumerate() {
            let run = b.table(2, &[0, 1]);
            b.link(vec.1[i], run.0);
            let style = b.table(2, if r.1 == 0 { &[1] } else { &[0, 1] });
            b.link(run.1[&1], style.0);
            if r.1 != 0 {
                b.bytes[style.1[&0]] = r.1 as u8;
            }
            b.set_f32(style.1[&1], r.2);
            let s = b.string(r.0);
            b.link(run.1[&0], s);
        }
        let fv = b.vector(fonts.len());
        b.link(main.1[&1], fv.0);
        for (i, f) in fonts.iter().enumerate() {
            let s = b.string(f);
            b.link(fv.1[i], s);
        }
        b.wrapped()
    }

    fn wrapped(&self) -> Vec<u8> {
        let mut out = Vec::new();
        out.extend_from_slice(&((self.bytes.len() + 4) as u32).to_le_bytes());
        out.extend_from_slice(&[0, 0, 0, 0, 0x44, 0x33, 0x22, 0x11]);
        out.extend_from_slice(&self.bytes);
        out
    }
}

/// Raw deflate as stored blocks (valid input for the inflater, no compression).
pub fn stored_deflate(data: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    let mut chunks = data.chunks(65_535).peekable();
    if chunks.peek().is_none() {
        out.extend_from_slice(&[1, 0, 0, 0xff, 0xff]);
    }
    while let Some(c) = chunks.next() {
        out.push(u8::from(chunks.peek().is_none()));
        out.extend_from_slice(&(c.len() as u16).to_le_bytes());
        out.extend_from_slice(&(!(c.len() as u16)).to_le_bytes());
        out.extend_from_slice(c);
    }
    out
}
