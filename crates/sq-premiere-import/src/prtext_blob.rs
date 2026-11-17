// SPDX-License-Identifier: GPL-3.0-or-later
//! Swift: PRTextBlob.swift. The Source Text parameter of `AE.ADBE Text` (base64 `StartKeyframeValue`). Two formats:
//! - current: 8-byte prefix, identifier `44 33 22 11`, then a FlatBuffer. Root field 0 -> main table: field 0 = runs
//!   (each: field 0 text, field 1 style {1 size px, 8 tracking 1/1000 em}), field 1 = font PostScript names.
//!   Shadow: main table fields 10 (color table, fields 0-2 = r, g, b bytes), 11 (on), 12 (opacity %), 15 (size),
//!   16 (blur); angle and distance are not decoded (20/34 are constant per style, also with the shadow off). 15/16 are
//!   certain (the maintainer's Premiere panel: size 25.3, blur 151 = f15 25.3, f16 151); Background: field 17 (color
//!   table), 18 (on; omitted = off), 19 (opacity %), 13 (size), 14 (corner radius), the same color + switch pairing as the
//!   shadow's 10 + 11. Color tables hold r, g, b as one-byte fields packed side by side (offsets 4, 5, 6). Field 17 is NOT
//!   the fill: the maintainer's captions store cyan 75/203/214 there with 18 absent and render white in Premiere (S112 x2,
//!   TCL C8L; 2026-10-03). The fill color has no non-white sample yet (white = default), so the flat format leaves `fill`
//!   `None`. Stroke stays undecoded (33/40 unidentified). Run style table: field 0 = index into the font list (omitted =
//!   0), 1 = size, 8 = tracking. Premiere ends a paragraph with CR ("Bis zu\r3.200", TCL C8L); the decoded text uses LF
//!   like the rest of SQ.
//! - legacy (Mister Horse and older titles): 8-byte prefix, UTF-16LE JSON `mTextParam.mStyleSheet`.

use serde_json::Value;

/// Essential Graphics shadow, in text layer pixels.
#[derive(Debug, Clone, PartialEq)]
pub struct Shadow {
    pub red: f64,
    pub green: f64,
    pub blue: f64,
    /// 0...1.
    pub opacity: f64,
    /// Premiere degrees (light direction, same convention as `TextShadow(angle:)`).
    pub angle: f64,
    pub distance: f64,
    /// Spread before the blur.
    pub size: f64,
    pub blur: f64,
}

/// A color, channels 0...1.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Rgb {
    pub red: f64,
    pub green: f64,
    pub blue: f64,
}

/// Text outline.
#[derive(Debug, Clone, PartialEq)]
pub struct Stroke {
    pub color: Rgb,
    pub width: f64,
}

/// One run of the text in one font and size.
#[derive(Debug, Clone, PartialEq)]
pub struct Run {
    pub text: String,
    pub font_name: Option<String>,
    pub size: Option<f64>,
}

/// The font and size of the lines after the first, when they differ from the first line's (SQ two-style text).
#[derive(Debug, Clone, PartialEq)]
pub struct LineStyle {
    pub font_name: Option<String>,
    pub size: Option<f64>,
}

/// Background box behind the text.
#[derive(Debug, Clone, PartialEq)]
pub struct Background {
    pub color: Rgb,
    /// 0...1.
    pub opacity: f64,
    /// Premiere "Size": how far the box reaches past the text, px.
    pub size: f64,
    pub corner_radius: f64,
}

/// A decoded Source Text parameter.
#[derive(Debug, Clone, PartialEq)]
pub struct PRText {
    pub text: String,
    pub runs: Vec<Run>,
    /// Lines 2+ in one other style than line 1 (`None` = one style throughout, or `mixed_styles`).
    pub second_line: Option<LineStyle>,
    /// Styles change inside a line, or differ between the later lines: SQ keeps the first run's style (reported).
    pub mixed_styles: bool,
    /// Fill color; `None` = not stored or switched off (white default).
    pub fill: Option<Rgb>,
    /// Stroke; only the legacy format carries it so far (`None` = none / not decoded).
    pub stroke: Option<Stroke>,
    pub font_name: Option<String>,
    pub size: Option<f64>,
    /// 1/1000 em, Premiere units.
    pub tracking: Option<f64>,
    /// Area text: the paragraph box (main table fields 2, 3, px). `None` = point text.
    pub box_size: Option<(f64, f64)>,
    /// Paragraph alignment (main table field 4, NSTextAlignment order: 0 left, 1 right, 2 center); `None` = left.
    pub alignment: Option<i64>,
    /// `None` = no shadow (absent or switched off).
    pub shadow: Option<Shadow>,
    /// `None` = no background box (absent or switched off).
    pub background: Option<Background>,
}

impl PRText {
    /// Text with one style and nothing else set.
    pub fn new(text: &str, font_name: Option<String>, size: Option<f64>, tracking: Option<f64>) -> PRText {
        PRText {
            text: text.to_string(),
            runs: Vec::new(),
            second_line: None,
            mixed_styles: false,
            fill: None,
            stroke: None,
            font_name,
            size,
            tracking,
            box_size: None,
            alignment: None,
            shadow: None,
            background: None,
        }
    }
}

/// Decoder of the Source Text blob.
pub struct PRTextBlob;

impl PRTextBlob {
    /// Decodes the base64 text of a `StartKeyframeValue`; characters outside the base64 alphabet are skipped.
    pub fn decode_base64(b64: &str) -> Option<PRText> {
        crate::prcontainer::decode_base64_lenient(b64).and_then(|d| Self::decode(&d))
    }

    /// Decodes the raw blob.
    pub fn decode(b: &[u8]) -> Option<PRText> {
        if b.len() <= 16 {
            return None;
        }
        if b[8] == 0x44 && b[9] == 0x33 && b[10] == 0x22 && b[11] == 0x11 {
            return FlatReader { b: &b[12..] }.premiere_text();
        }
        Self::legacy(&b[8..])
    }

    fn legacy(b: &[u8]) -> Option<PRText> {
        let units: Vec<u16> = crate::prcontainer::utf16le_units(b);
        let mut s = String::from_utf16(&units).ok()?;
        while s.ends_with('\0') {
            s.pop();
        }
        let json: Value = serde_json::from_str(&s).ok()?;
        let tp = json.as_object()?.get("mTextParam")?.as_object()?;
        let empty = serde_json::Map::new();
        let sheet = tp.get("mStyleSheet").and_then(Value::as_object).unwrap_or(&empty);
        let first = |key: &str| -> Option<&Value> {
            let values = sheet.get(key)?.as_object()?.get("mParamValues")?.as_array()?;
            let rows: Vec<&Vec<Value>> = values.iter().map(Value::as_array).collect::<Option<_>>()?;
            rows.first().and_then(|r| r.get(1))
        };
        let text = sheet.get("mText").or_else(|| tp.get("mText"))?.as_str()?;
        let rgb = |v: Option<&Value>| -> Option<Rgb> {
            let n = ns_int(v?)?;
            Some(Rgb {
                red: ((n >> 16) & 255) as f64 / 255.0,
                green: ((n >> 8) & 255) as f64 / 255.0,
                blue: (n & 255) as f64 / 255.0,
            })
        };
        let on = |key: &str| first(key).and_then(ns_bool).unwrap_or(false);
        let mut t = PRText::new(
            text,
            first("mFontName").and_then(Value::as_str).map(str::to_string),
            first("mFontSize").and_then(ns_double),
            first("mTracking").and_then(ns_double),
        );
        if on("mFillVisible") {
            t.fill = rgb(first("mFillColor"));
        }
        // mAlignment (paragraph): 0 left, 1 right, 2 center, 3 to 5 the justified variants (last line left / right / center).
        if let Some(a) = tp.get("mAlignment").and_then(ns_int) {
            match a {
                0..=2 => t.alignment = Some(a),
                3..=5 => t.alignment = Some(a - 3),
                _ => {}
            }
        }
        if on("mStrokeVisible")
            && let Some(c) = rgb(first("mStrokeColor"))
            && let Some(w) = first("mStrokeWidth").and_then(ns_double).filter(|&w| w > 0.0)
        {
            t.stroke = Some(Stroke { color: c, width: w });
        }
        Some(t)
    }
}

/// `NSNumber.doubleValue` of a JSON number or boolean.
fn ns_double(v: &Value) -> Option<f64> {
    match v {
        Value::Number(n) => n.as_f64(),
        Value::Bool(b) => Some(f64::from(u8::from(*b))),
        _ => None,
    }
}

/// `NSNumber.intValue`: floats truncate.
fn ns_int(v: &Value) -> Option<i64> {
    match v {
        Value::Number(n) => n.as_i64().or_else(|| n.as_f64().map(|f| f as i64)),
        Value::Bool(b) => Some(i64::from(*b)),
        _ => None,
    }
}

/// `NSNumber.boolValue`.
fn ns_bool(v: &Value) -> Option<bool> {
    ns_double(v).map(|d| d != 0.0)
}

/// Bounds-checked FlatBuffer reading (little endian). Every accessor returns `None` instead of failing on bad offsets.
struct FlatReader<'a> {
    b: &'a [u8],
}

impl FlatReader<'_> {
    fn u32(&self, o: i64) -> Option<i64> {
        let o = usize::try_from(o).ok()?;
        let s = self.b.get(o..o.checked_add(4)?)?;
        Some(i64::from(u32::from_le_bytes([s[0], s[1], s[2], s[3]])))
    }

    fn i32(&self, o: i64) -> Option<i64> {
        self.u32(o).map(|v| i64::from(v as u32 as i32))
    }

    fn u16(&self, o: i64) -> Option<i64> {
        let o = usize::try_from(o).ok()?;
        let s = self.b.get(o..o.checked_add(2)?)?;
        Some(i64::from(u16::from_le_bytes([s[0], s[1]])))
    }

    fn f32(&self, o: i64) -> Option<f32> {
        self.u32(o).map(|v| f32::from_bits(v as u32))
    }

    /// Absolute position of field `i` of the table at `t`, `None` when absent.
    fn field(&self, t: i64, i: i64) -> Option<i64> {
        let so = self.i32(t)?;
        let vt = t - so;
        let size = self.u16(vt)?;
        if 4 + 2 * i >= size {
            return None;
        }
        let off = self.u16(vt + 4 + 2 * i).filter(|&o| o != 0)?;
        Some(t + off)
    }

    /// Follows the uoffset stored at `p`.
    fn deref(&self, p: Option<i64>) -> Option<i64> {
        let p = p?;
        self.u32(p).map(|v| p + v)
    }

    fn string(&self, p: Option<i64>) -> Option<String> {
        let s = self.deref(p)?;
        let n = self.u32(s)?;
        if s + 4 + n > self.b.len() as i64 {
            return None;
        }
        String::from_utf8(self.b[(s + 4) as usize..(s + 4 + n) as usize].to_vec()).ok()
    }

    /// Element slot positions of the vector referenced at `p`.
    fn vector(&self, p: Option<i64>) -> Vec<i64> {
        let Some(v) = self.deref(p) else { return Vec::new() };
        let Some(n) = self.u32(v).filter(|&n| n < 100_000 && v + 4 + 4 * n <= self.b.len() as i64) else {
            return Vec::new();
        };
        (0..n).map(|i| v + 4 + 4 * i).collect()
    }

    fn byte(&self, p: Option<i64>) -> Option<i64> {
        let p = usize::try_from(p?).ok()?;
        self.b.get(p).map(|&v| i64::from(v))
    }

    fn float(&self, main: i64, i: i64) -> Option<f64> {
        self.field(main, i).and_then(|p| self.f32(p)).map(f64::from)
    }

    fn premiere_text(&self) -> Option<PRText> {
        let root_table = self.deref(Some(0))?;
        let main = self.deref(self.field(root_table, 0))?;
        let fonts: Vec<Option<String>> =
            self.vector(self.field(main, 1)).into_iter().map(|p| self.string(Some(p))).collect();
        let first_font = fonts.first().cloned().flatten();
        let (mut text, mut size, mut tracking, mut font, mut got_style) = (String::new(), None, None, None, false);
        let mut runs: Vec<Run> = Vec::new();
        for slot in self.vector(self.field(main, 0)) {
            let Some(run) = self.deref(Some(slot)) else { continue };
            let piece = self.string(self.field(run, 0)).unwrap_or_default().replace("\r\n", "\n").replace('\r', "\n");
            text += &piece;
            let mut r = Run { text: piece, font_name: first_font.clone(), size: None };
            if let Some(style) = self.deref(self.field(run, 1)) {
                let index = self.byte(self.field(style, 0)).unwrap_or(0);
                if let Some(f) = usize::try_from(index).ok().and_then(|i| fonts.get(i)) {
                    r.font_name = f.clone();
                }
                r.size = self.float(style, 1);
                if !got_style {
                    got_style = true;
                    size = r.size;
                    font = r.font_name.clone();
                    tracking = self.float(style, 8);
                }
            }
            runs.push(r);
        }
        let mut t = PRText::new(&text, font.or(first_font), size, tracking);
        (t.second_line, t.mixed_styles) = Self::line_styles(&runs);
        t.runs = runs;
        if let (Some(w), Some(h)) =
            (self.field(main, 2).and_then(|p| self.f32(p)), self.field(main, 3).and_then(|p| self.f32(p)))
            && w > 0.0
            && h > 0.0
        {
            t.box_size = Some((f64::from(w), f64::from(h)));
        }
        t.alignment = self.field(main, 4).and_then(|p| if p < self.b.len() as i64 { self.byte(Some(p)) } else { None });
        t.shadow = self.shadow(main);
        t.background = self.background(main);
        Some(t)
    }

    /// Line 1's style against the later lines' (SQ text has one style for line 1 and one for every later line).
    fn line_styles(runs: &[Run]) -> (Option<LineStyle>, bool) {
        let mut first: Vec<LineStyle> = Vec::new();
        let mut later: Vec<LineStyle> = Vec::new();
        let mut line = 0;
        for r in runs {
            let style = LineStyle { font_name: r.font_name.clone(), size: r.size };
            for (i, part) in r.text.split('\n').enumerate() {
                if i > 0 {
                    line += 1;
                }
                if part.is_empty() {
                    continue;
                }
                let list = if line == 0 { &mut first } else { &mut later };
                if !list.contains(&style) {
                    list.push(style.clone());
                }
            }
        }
        if first.len() > 1 || later.len() > 1 {
            return (None, true);
        }
        match (later.first(), first.first()) {
            (Some(l), Some(f)) if l != f => (Some(l.clone()), false),
            _ => (None, false),
        }
    }

    /// A color table (fields 0, 1, 2 = r, g, b, one byte each).
    fn colour(&self, p: Option<i64>) -> Option<Rgb> {
        let c = self.deref(p)?;
        let (r, g, bl) = (self.byte(self.field(c, 0))?, self.byte(self.field(c, 1))?, self.byte(self.field(c, 2))?);
        Some(Rgb { red: r as f64 / 255.0, green: g as f64 / 255.0, blue: bl as f64 / 255.0 })
    }

    fn background(&self, main: i64) -> Option<Background> {
        if self.byte(self.field(main, 18)) != Some(1) {
            return None;
        }
        let c = self.colour(self.field(main, 17))?;
        let f = |i: i64| self.float(main, i).filter(|v| v.is_finite());
        let bg = Background {
            color: c,
            opacity: (f(19).unwrap_or(100.0) / 100.0).clamp(0.0, 1.0),
            size: f(13).unwrap_or(0.0).max(0.0),
            corner_radius: f(14).unwrap_or(0.0).max(0.0),
        };
        (bg.opacity > 0.0).then_some(bg)
    }

    fn shadow(&self, main: i64) -> Option<Shadow> {
        if self.byte(self.field(main, 11)) != Some(1) {
            return None;
        }
        let f = |i: i64| self.float(main, i).unwrap_or(0.0);
        // Fields 20 and 34 are NOT the shadow angle / distance: every sample of the maintainer's projects (18 files) carries
        // them with one constant pair per text style (44.6/53.5, 19.3/17.8, 51.8/60.0), also on texts whose shadow switch
        // (11) is off, while his panel reads angle 0 / distance 0. No field varies with the shadow's angle or distance, so
        // both stay 0 (shortcut: an angled shadow is not importable until a sample with a non-zero panel angle exists).
        let c = self.colour(self.field(main, 10)).unwrap_or(Rgb { red: 0.0, green: 0.0, blue: 0.0 });
        let s = Shadow {
            red: c.red,
            green: c.green,
            blue: c.blue,
            opacity: f(12) / 100.0,
            angle: 0.0,
            distance: 0.0,
            size: f(15),
            blur: f(16),
        };
        (s.opacity > 0.0).then_some(s)
    }
}
