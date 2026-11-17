// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: ColorDecisionImport.swift
//! Reads ASC CDL files: `.cdl` (ColorDecisionList), `.cc` (one ColorCorrection), `.ccc` (ColorCorrectionCollection)
//! and the `*ASC_SOP` / `*ASC_SAT` comments of a CMX `.edl`.

use crate::color_graph::StepPrimariesExt;
use sq_core_model::{ColorTriple, StepPrimaries};
use std::fmt;

/// One ASC color decision: out = (in * slope + offset)^power, then saturation (Rec.709 luma weights).
#[derive(Clone, Debug, PartialEq)]
pub struct ColorDecision {
    /// The `ColorCorrection` id, the EDL clip name, or the EDL event number.
    pub id: String,
    /// Slope.
    pub slope: ColorTriple,
    /// Offset.
    pub offset: ColorTriple,
    /// Power.
    pub power: ColorTriple,
    /// Saturation.
    pub saturation: f32,
}

impl ColorDecision {
    /// A neutral decision.
    pub fn new(id: impl Into<String>) -> ColorDecision {
        ColorDecision {
            id: id.into(),
            slope: ColorTriple::all(1.0),
            offset: ColorTriple::all(0.0),
            power: ColorTriple::all(1.0),
            saturation: 1.0,
        }
    }

    /// The decision as Step primaries (lift 0, contrast 1: the same maths), clamped to the Step ranges: a negative
    /// slope becomes 0, a power of 0 or below the smallest exponent, huge values the range ends.
    pub fn primaries(&self) -> StepPrimaries {
        fn clamp(v: f32, r: (f32, f32)) -> f32 {
            if v.is_finite() { v.max(r.0).min(r.1) } else { r.0 }
        }
        fn clamp3(t: ColorTriple, r: (f32, f32)) -> ColorTriple {
            ColorTriple { r: clamp(t.r, r), g: clamp(t.g, r), b: clamp(t.b, r) }
        }
        StepPrimaries {
            gain: clamp3(self.slope, StepPrimaries::GAIN_RANGE),
            offset: clamp3(self.offset, StepPrimaries::OFFSET_RANGE),
            gamma: clamp3(self.power, StepPrimaries::GAMMA_RANGE),
            saturation: clamp(self.saturation, StepPrimaries::SATURATION_RANGE),
            ..StepPrimaries::default()
        }
    }
}

/// Why a decision file was refused.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ImportError {
    /// The file holds no color decision.
    NoDecisions,
    /// A Slope / Offset / Power / Saturation value is not a number (or not three numbers).
    BadValue(String),
}

impl fmt::Display for ImportError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ImportError::NoDecisions => f.write_str("The file holds no color decision"),
            ImportError::BadValue(what) => write!(f, "Bad value in {what}"),
        }
    }
}

impl std::error::Error for ImportError {}

/// The file extensions the importer reads.
pub const FILE_EXTENSIONS: [&str; 4] = ["cdl", "cc", "ccc", "edl"];

/// Parses a decision file; `ext` picks the reader (case-insensitive).
pub fn parse(data: &[u8], ext: &str) -> Result<Vec<ColorDecision>, ImportError> {
    let out = if ext.to_lowercase() == "edl" {
        parse_edl(&String::from_utf8_lossy(data))?
    } else {
        parse_xml(&String::from_utf8_lossy(data))?
    };
    if out.is_empty() {
        return Err(ImportError::NoDecisions);
    }
    Ok(out)
}

// MARK: XML (.cdl / .cc / .ccc)

/// The part after the last `:` of an element name.
fn local(n: &str) -> &str {
    n.rsplit(':').next().unwrap_or(n)
}

/// Value of attribute `key` in the text of a start tag (after the element name).
fn attribute(tag: &str, key: &str) -> Option<String> {
    let mut rest = tag;
    while let Some(eq) = rest.find('=') {
        let name = rest[..eq].trim().rsplit(char::is_whitespace).next().unwrap_or("");
        let after = rest[eq + 1..].trim_start();
        let quote = after.chars().next().filter(|c| *c == '"' || *c == '\'')?;
        let body = &after[1..];
        let end = body.find(quote)?;
        if name == key {
            return Some(unescape(&body[..end]));
        }
        rest = &body[end + 1..];
    }
    None
}

fn unescape(s: &str) -> String {
    s.replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"").replace("&apos;", "'").replace("&amp;", "&")
}

/// Walks the elements like `XMLParser` does; malformed markup ends the walk and keeps what was read so far.
fn parse_xml(s: &str) -> Result<Vec<ColorDecision>, ImportError> {
    let mut out: Vec<ColorDecision> = Vec::new();
    let mut current: Option<ColorDecision> = None;
    let mut text = String::new();
    let mut count = 0;
    let mut rest = s;
    while !rest.is_empty() {
        let Some(lt) = rest.find('<') else {
            text.push_str(&unescape(rest));
            break;
        };
        text.push_str(&unescape(&rest[..lt]));
        rest = &rest[lt..];
        // Comments, CDATA, processing instructions and the doctype carry no elements.
        let skip = if rest.starts_with("<!--") {
            Some("-->")
        } else if rest.starts_with("<![CDATA[") {
            Some("]]>")
        } else if rest.starts_with("<?") {
            Some("?>")
        } else if rest.starts_with("<!") {
            Some(">")
        } else {
            None
        };
        if let Some(close) = skip {
            let Some(end) = rest.find(close) else { break };
            rest = &rest[end + close.len()..];
            continue;
        }
        let Some(gt) = rest.find('>') else { break };
        let inner = &rest[1..gt];
        rest = &rest[gt + 1..];
        let (closing, inner) = match inner.strip_prefix('/') {
            Some(i) => (true, i),
            None => (false, inner),
        };
        let self_closing = !closing && inner.ends_with('/');
        let inner = inner.strip_suffix('/').unwrap_or(inner);
        let name_end = inner.find(char::is_whitespace).unwrap_or(inner.len());
        let (name, attrs) = inner.split_at(name_end);
        if !closing {
            text.clear();
            if local(name) == "ColorCorrection" {
                count += 1;
                current = Some(ColorDecision::new(attribute(attrs, "id").unwrap_or_else(|| count.to_string())));
            }
        }
        if closing || self_closing {
            if let Some(c) = current.as_mut() {
                match local(name) {
                    "Slope" => c.slope = triple(&text, name)?,
                    "Offset" => c.offset = triple(&text, name)?,
                    "Power" => c.power = triple(&text, name)?,
                    "Saturation" => c.saturation = number(&text, name)?,
                    "ColorCorrection" => out.extend(current.take()),
                    _ => {}
                }
            }
            text.clear();
        }
    }
    Ok(out)
}

// MARK: EDL comments

fn is_newline(c: char) -> bool {
    matches!(c, '\n' | '\r' | '\u{b}' | '\u{c}' | '\u{85}' | '\u{2028}' | '\u{2029}')
}

fn trim_blanks(s: &str) -> &str {
    s.trim_matches(|c: char| c.is_whitespace() && !is_newline(c))
}

fn parse_edl(s: &str) -> Result<Vec<ColorDecision>, ImportError> {
    let mut out: Vec<ColorDecision> = Vec::new();
    let mut event: Option<ColorDecision> = None;
    let mut has_cdl = false;
    let close = |event: &mut Option<ColorDecision>, has_cdl: &mut bool, out: &mut Vec<ColorDecision>| {
        if let Some(e) = event.take()
            && *has_cdl
        {
            out.push(e);
        }
        *has_cdl = false;
    };
    for raw in s.split(is_newline).filter(|l| !l.is_empty()) {
        let line = trim_blanks(raw);
        let first = line.split(' ').find(|p| !p.is_empty());
        if let Some(first) = first.filter(|f| f.chars().all(char::is_numeric)) {
            close(&mut event, &mut has_cdl, &mut out);
            event = Some(ColorDecision::new(first));
        } else if let (Some(ev), Some(rest)) = (event.as_mut(), line.strip_prefix('*')) {
            let body = trim_blanks(rest);
            if body.to_uppercase().starts_with("FROM CLIP NAME:") {
                let name = trim_blanks(body.get("FROM CLIP NAME:".len()..).unwrap_or(""));
                if !name.is_empty() {
                    ev.id = name.to_string();
                }
            } else if let Some(sop) = body.strip_prefix("ASC_SOP") {
                let groups: Vec<String> = sop
                    .split('(')
                    .filter(|g| !g.is_empty())
                    .map(|g| g.replace(')', ""))
                    .filter(|g| !trim_blanks(g).is_empty())
                    .collect();
                if groups.len() != 3 {
                    return Err(ImportError::BadValue("ASC_SOP".into()));
                }
                ev.slope = triple(&groups[0], "ASC_SOP")?;
                ev.offset = triple(&groups[1], "ASC_SOP")?;
                ev.power = triple(&groups[2], "ASC_SOP")?;
                has_cdl = true;
            } else if let Some(sat) = body.strip_prefix("ASC_SAT") {
                ev.saturation = number(sat, "ASC_SAT")?;
                has_cdl = true;
            }
        }
    }
    close(&mut event, &mut has_cdl, &mut out);
    Ok(out)
}

// MARK: Numbers

fn number(s: &str, what: &str) -> Result<f32, ImportError> {
    match s.trim().parse::<f32>() {
        Ok(v) if v.is_finite() => Ok(v),
        _ => Err(ImportError::BadValue(what.to_string())),
    }
}

fn triple(s: &str, what: &str) -> Result<ColorTriple, ImportError> {
    let parts: Vec<&str> =
        s.split(|c: char| c == ' ' || c == '\t' || is_newline(c)).filter(|p| !p.is_empty()).collect();
    if parts.len() != 3 {
        return Err(ImportError::BadValue(what.to_string()));
    }
    Ok(ColorTriple { r: number(parts[0], what)?, g: number(parts[1], what)?, b: number(parts[2], what)? })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn t(r: f32, g: f32, b: f32) -> ColorTriple {
        ColorTriple { r, g, b }
    }

    #[test]
    fn parses_cc_and_ccc_and_cdl() {
        let cc = r#"<?xml version="1.0" encoding="UTF-8"?>
<ColorCorrection id="shot_010">
  <SOPNode><Slope>1.1 1.0 0.9</Slope><Offset>0.01 0 -0.02</Offset><Power>0.95 1 1.05</Power></SOPNode>
  <SatNode><Saturation>0.85</Saturation></SatNode>
</ColorCorrection>"#;
        let a = parse(cc.as_bytes(), "cc").unwrap();
        assert_eq!(a.len(), 1);
        assert_eq!(a[0].id, "shot_010");
        assert_eq!(a[0].slope, t(1.1, 1.0, 0.9));
        assert_eq!(a[0].offset, t(0.01, 0.0, -0.02));
        assert_eq!(a[0].power, t(0.95, 1.0, 1.05));
        assert_eq!(a[0].saturation, 0.85);
        let p = a[0].primaries();
        assert!(p.gain == a[0].slope && p.offset == a[0].offset && p.gamma == a[0].power && p.saturation == 0.85);
        assert_eq!(p.lift, t(0.0, 0.0, 0.0));

        let ccc = r#"<ColorCorrectionCollection xmlns="urn:ASC:CDL:v1.01">
  <ColorCorrection id="a"><SOPNode><Slope>2 2 2</Slope></SOPNode></ColorCorrection>
  <ColorCorrection id="b"><SATNode><Saturation>0.5</Saturation></SATNode></ColorCorrection>
</ColorCorrectionCollection>"#;
        let b = parse(ccc.as_bytes(), "ccc").unwrap();
        assert_eq!(b.iter().map(|d| d.id.as_str()).collect::<Vec<_>>(), ["a", "b"]);
        assert!(b[0].slope == t(2.0, 2.0, 2.0) && b[0].offset == t(0.0, 0.0, 0.0) && b[0].saturation == 1.0);
        assert!(b[1].slope == t(1.0, 1.0, 1.0) && b[1].saturation == 0.5);

        let cdl = r#"<ColorDecisionList xmlns="urn:ASC:CDL:v1.01"><ColorDecision>
  <ColorCorrection id="x"><SOPNode><Slope>1 1 1</Slope><Offset>0.1 0.1 0.1</Offset><Power>1 1 1</Power></SOPNode></ColorCorrection>
</ColorDecision></ColorDecisionList>"#;
        let d = parse(cdl.as_bytes(), "cdl").unwrap();
        assert!(d.len() == 1 && d[0].offset == t(0.1, 0.1, 0.1));
    }

    #[test]
    fn parses_edl_comments() {
        let edl = "TITLE: TEST
001  A001C003 V     C        01:00:00:00 01:00:02:00 00:00:00:00 00:00:02:00
* FROM CLIP NAME: A001C003.MOV
*ASC_SOP (1.2 1.0 0.8)(0.0 0.01 -0.01)(1.0 1.0 1.0)
*ASC_SAT 0.9
002  A001C004 V     C        01:00:05:00 01:00:06:00 00:00:02:00 00:00:03:00
*ASC_SAT 1.2
003  A001C005 V     C        01:00:07:00 01:00:08:00 00:00:03:00 00:00:04:00";
        let e = parse(edl.as_bytes(), "edl").unwrap();
        assert_eq!(e.len(), 2);
        assert_eq!(e[0].id, "A001C003.MOV");
        assert_eq!(e[0].slope, t(1.2, 1.0, 0.8));
        assert_eq!(e[0].offset, t(0.0, 0.01, -0.01));
        assert_eq!(e[0].saturation, 0.9);
        assert!(e[1].id == "002" && e[1].saturation == 1.2 && e[1].slope == t(1.0, 1.0, 1.0));
    }

    #[test]
    fn imported_decisions_are_clamped_to_the_step_ranges() {
        let mut d = ColorDecision::new("x");
        d.slope = t(1e30, -2.0, 1.5);
        d.offset = t(-5.0, 1e30, 0.2);
        d.power = t(0.0, -1.0, 1e30);
        d.saturation = 1e30;
        let p = d.primaries();
        assert_eq!(p.gain, t(StepPrimaries::GAIN_RANGE.1, 0.0, 1.5));
        assert_eq!(p.offset, t(-1.0, 1.0, 0.2));
        let (lo, hi) = StepPrimaries::GAMMA_RANGE;
        assert_eq!(p.gamma, t(lo, lo, hi), "power 0 or below takes the smallest exponent");
        assert_eq!(p.saturation, StepPrimaries::SATURATION_RANGE.1);
        d.saturation = -1.0;
        assert_eq!(d.primaries().saturation, 0.0);
        let cc = r#"<ColorCorrection id="h"><SOPNode><Slope>1e30 1 1</Slope><Power>0 1 1</Power></SOPNode></ColorCorrection>"#;
        let h = parse(cc.as_bytes(), "cc").unwrap()[0].primaries();
        assert!(h.gain.r == 4.0 && h.gamma.r == 0.1);
    }

    #[test]
    fn rejects_files_without_decisions() {
        assert_eq!(parse(b"<a/>", "cdl"), Err(ImportError::NoDecisions));
        let bad = "<ColorCorrection><SOPNode><Slope>1 x 1</Slope></SOPNode></ColorCorrection>";
        assert_eq!(parse(bad.as_bytes(), "cc"), Err(ImportError::BadValue("Slope".into())));
    }

    #[test]
    fn unnamed_corrections_are_numbered_and_entities_decode() {
        let ccc = r#"<c:Collection><ColorCorrection><Slope>1 1 1</Slope></ColorCorrection>
<c:ColorCorrection id='a&amp;b'><c:Slope>1 2 3</c:Slope></c:ColorCorrection></c:Collection>"#;
        let d = parse(ccc.as_bytes(), "CCC").unwrap();
        assert_eq!(d.iter().map(|x| x.id.as_str()).collect::<Vec<_>>(), ["1", "a&b"]);
        assert_eq!(d[1].slope, t(1.0, 2.0, 3.0));
    }
}
