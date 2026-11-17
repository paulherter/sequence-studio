// Swift: CanonMetadata.swift
//! What a Canon clip says about its log curve and gamut. MP4/MOV: the maker notes Canon embeds in the movie header
//! (`moov` / `uuid` 85c0b687-820f-11e0-8111-f4ce462b6a48 / `CMT3`, a TIFF structure; tag 0x4026 holds the log
//! settings). MXF (XF-AVC): the clip's XML sidecar. Layout of the maker notes as documented by ExifTool (Canon LogInfo).

use crate::sony_metadata::SonyMetadata;
use sq_core_model::ColorSpaceID;
use std::collections::BTreeSet;
use std::fs::File;
use std::io::Read;
use std::path::Path;

/// Canon log curve.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Curve {
    Log = 1,
    Log2 = 2,
    Log3 = 3,
}

impl Curve {
    fn from_raw(v: i64) -> Option<Curve> {
        match v {
            1 => Some(Curve::Log),
            2 => Some(Curve::Log2),
            3 => Some(Curve::Log3),
            _ => None,
        }
    }
}

/// Canon gamut.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Gamut {
    BT709 = 0,
    BT2020 = 1,
    CinemaGamut = 2,
}

impl Gamut {
    fn from_raw(v: i64) -> Option<Gamut> {
        match v {
            0 => Some(Gamut::BT709),
            1 => Some(Gamut::BT2020),
            2 => Some(Gamut::CinemaGamut),
            _ => None,
        }
    }
}

/// What a Canon clip says about its log curve and gamut.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct CanonMetadata {
    pub curve: Option<Curve>,
    pub gamut: Option<Gamut>,
}

const LOG_INFO_TAG: usize = 0x4026;
/// 32-bit entries of the log settings block.
const GAMUT_INDEX: usize = 9;
const CURVE_INDEX: usize = 11;

/// The `uuid` box that carries the maker notes.
pub const BOX_UUID: [u8; 16] =
    [0x85, 0xC0, 0xB6, 0x87, 0x82, 0x0F, 0x11, 0xE0, 0x81, 0x11, 0xF4, 0xCE, 0x46, 0x2B, 0x6A, 0x48];

impl CanonMetadata {
    /// The input color space to preselect. None unless the clip names both a log curve and a gamut: a clip recorded
    /// without Canon Log, or metadata that leaves one of the two open, stays on the tagged / default space.
    pub fn color_space(&self) -> Option<ColorSpaceID> {
        use ColorSpaceID::*;
        Some(match (self.curve?, self.gamut?) {
            (Curve::Log, Gamut::CinemaGamut) => CanonLogCinemaGamut,
            (Curve::Log, Gamut::BT2020) => CanonLogBT2020,
            (Curve::Log, Gamut::BT709) => CanonLogBT709,
            (Curve::Log2, Gamut::CinemaGamut) => CanonLog2CinemaGamut,
            (Curve::Log2, Gamut::BT2020) => CanonLog2BT2020,
            (Curve::Log2, Gamut::BT709) => CanonLog2BT709,
            (Curve::Log3, Gamut::CinemaGamut) => CanonLog3CinemaGamut,
            (Curve::Log3, Gamut::BT2020) => CanonLog3BT2020,
            (Curve::Log3, Gamut::BT709) => CanonLog3BT709,
        })
    }

    // MARK: maker notes (MP4)

    /// Reads the log settings from the `CMT3` payload (TIFF header, one directory of maker note tags).
    /// None when it is not a TIFF structure or has no log settings.
    pub fn from_maker_notes(b: &[u8]) -> Option<CanonMetadata> {
        if b.len() < 8 {
            return None;
        }
        let little = if b[0] == 0x49 && b[1] == 0x49 {
            true
        } else if b[0] == 0x4D && b[1] == 0x4D {
            false
        } else {
            return None;
        };
        let u16_at = |o: usize| -> Option<usize> {
            let v = b.get(o..o.checked_add(2)?)?;
            Some(if little {
                usize::from(v[0]) | usize::from(v[1]) << 8
            } else {
                usize::from(v[0]) << 8 | usize::from(v[1])
            })
        };
        let u32_at = |o: usize| -> Option<u32> {
            let v = b.get(o..o.checked_add(4)?)?;
            let v: Vec<u32> = v.iter().map(|&x| u32::from(x)).collect();
            Some(if little {
                v[0] | v[1] << 8 | v[2] << 16 | v[3] << 24
            } else {
                v[0] << 24 | v[1] << 16 | v[2] << 8 | v[3]
            })
        };
        if u16_at(2) != Some(42) {
            return None;
        }
        let dir = u32_at(4)? as usize;
        let count = u16_at(dir)?;
        for i in 0..count {
            let e = dir + 2 + i * 12;
            let tag = u16_at(e)?;
            if tag != LOG_INFO_TAG {
                continue;
            }
            // 32-bit values (signed or unsigned long), stored at an offset; the block must reach the curve entry.
            let ty = u16_at(e + 2)?;
            if ty != 9 && ty != 4 {
                return None;
            }
            let n = u32_at(e + 4)? as usize;
            if n <= CURVE_INDEX || n >= 4096 {
                return None;
            }
            let at = u32_at(e + 8)? as usize;
            if at > b.len() {
                return None;
            }
            let g = u32_at(at + GAMUT_INDEX * 4)?;
            let c = u32_at(at + CURVE_INDEX * 4)?;
            return Some(CanonMetadata {
                curve: Curve::from_raw(i64::from(c as i32)),
                gamut: Gamut::from_raw(i64::from(g as i32)),
            });
        }
        None
    }

    // MARK: sidecar (XF-AVC MXF)

    /// Reads a Canon clip XML. Canon's schema is not public, so no exact element names are assumed: a whole element
    /// text or attribute value has to be a curve name (Canon Log, Canon Log 2, Canon Log 3) or a gamut name, and it has
    /// to sit in or under an element that is Canon's (element name or a namespace declared on it contains "canon").
    /// The word Canon somewhere in another vendor's XML does not count. Two different curves or gamuts give nothing.
    pub fn from_xml(xml: &[u8]) -> Option<CanonMetadata> {
        if xml.len() > CameraMetadata::MAX_SIDECAR_BYTES
            || !String::from_utf8_lossy(xml).to_lowercase().contains("canon")
        {
            return None;
        }
        let values = scan_values(xml)?;
        let mut curves = BTreeSet::new();
        let mut gamuts = BTreeSet::new();
        for value in values {
            let key: String = value.to_lowercase().chars().filter(|c| c.is_alphanumeric()).collect();
            if let Some(c) = curve_by_name(&key) {
                curves.insert(c);
            }
            if let Some(g) = gamut_by_name(&key) {
                gamuts.insert(g);
            }
        }
        if curves.len() != 1 {
            return None;
        }
        let gamut = if gamuts.len() == 1 { gamuts.first().copied() } else { None };
        Some(CanonMetadata { curve: curves.first().copied(), gamut })
    }
}

fn curve_by_name(key: &str) -> Option<Curve> {
    match key {
        "canonlog" | "clog" => Some(Curve::Log),
        "canonlog2" | "clog2" => Some(Curve::Log2),
        "canonlog3" | "clog3" => Some(Curve::Log3),
        _ => None,
    }
}

fn gamut_by_name(key: &str) -> Option<Gamut> {
    match key {
        "cinemagamut" | "cgamut" => Some(Gamut::CinemaGamut),
        "bt2020" | "rec2020" => Some(Gamut::BT2020),
        "bt709" | "rec709" => Some(Gamut::BT709),
        _ => None,
    }
}

/// Walks the XML like the Swift `XMLParser` delegate: collects the attribute values (except namespace declarations) and the
/// text of every element that is Canon's or sits under one. None when the document is not well formed.
// shortcut: a small scanner (elements, attributes, text, entities; comments, processing instructions and CDATA are
// skipped, DTDs are not expanded); upgrade when a camera sidecar needs more of XML.
fn scan_values(xml: &[u8]) -> Option<Vec<String>> {
    let s = std::str::from_utf8(xml).ok()?;
    let mut values: Vec<String> = Vec::new();
    let mut text = String::new();
    // One entry per open element: it or an ancestor is Canon's.
    let mut scope: Vec<bool> = Vec::new();
    let mut names: Vec<&str> = Vec::new();
    let mut roots = 0;
    let mut rest = s;
    while !rest.is_empty() {
        let Some(lt) = rest.find('<') else {
            if scope.is_empty() && !rest.trim().is_empty() {
                return None;
            }
            if !scope.is_empty() {
                return None; // unclosed element
            }
            break;
        };
        let (chars, tail) = rest.split_at(lt);
        if !chars.is_empty() {
            if scope.is_empty() {
                if !chars.trim().is_empty() {
                    return None;
                }
            } else if text.chars().count() < 256 {
                text.push_str(&unescape(chars)?);
            }
        }
        rest = tail;
        if let Some(r) = rest.strip_prefix("<!--") {
            rest = &r[r.find("-->")? + 3..];
        } else if let Some(r) = rest.strip_prefix("<![CDATA[") {
            rest = &r[r.find("]]>")? + 3..];
        } else if let Some(r) = rest.strip_prefix("<?") {
            rest = &r[r.find("?>")? + 2..];
        } else if let Some(r) = rest.strip_prefix("<!") {
            rest = &r[r.find('>')? + 1..];
        } else if let Some(r) = rest.strip_prefix("</") {
            let gt = r.find('>')?;
            let name = r[..gt].trim_end();
            if names.pop()? != name {
                return None;
            }
            if scope.pop() == Some(true) && !text.is_empty() {
                values.push(std::mem::take(&mut text));
            }
            text.clear();
            rest = &r[gt + 1..];
        } else {
            let r = &rest[1..];
            let gt = tag_end(r)?;
            let mut body = &r[..gt];
            let empty = body.ends_with('/');
            if empty {
                body = &body[..body.len() - 1];
            }
            let (name, attrs) = parse_tag(body)?;
            if names.is_empty() {
                roots += 1;
                if roots > 1 {
                    return None;
                }
            }
            text.clear();
            let namespaces = attrs.iter().filter(|(k, _)| k == "xmlns" || k.starts_with("xmlns:"));
            let own = name.to_lowercase().contains("canon")
                || namespaces.clone().any(|(_, v)| v.to_lowercase().contains("canon"));
            let parent = scope.last() == Some(&true);
            let in_scope = own || parent;
            if in_scope {
                values.extend(
                    attrs.iter().filter(|(k, _)| k != "xmlns" && !k.starts_with("xmlns:")).map(|(_, v)| v.clone()),
                );
            }
            if empty {
                // start followed by end
                if in_scope && !text.is_empty() {
                    values.push(std::mem::take(&mut text));
                }
                text.clear();
            } else {
                scope.push(in_scope);
                names.push(name);
            }
            rest = &r[gt + 1..];
        }
    }
    (names.is_empty() && roots == 1).then_some(values)
}

/// Index of the `>` that closes a start tag, skipping quoted attribute values.
fn tag_end(s: &str) -> Option<usize> {
    let mut quote: Option<char> = None;
    for (i, c) in s.char_indices() {
        match (quote, c) {
            (Some(q), c) if c == q => quote = None,
            (None, '"' | '\'') => quote = Some(c),
            (None, '>') => return Some(i),
            _ => {}
        }
    }
    None
}

/// Element name and attributes (entity-decoded values) of a start tag body.
fn parse_tag(body: &str) -> Option<(&str, Vec<(String, String)>)> {
    let body = body.trim_end();
    let name_end = body.find(char::is_whitespace).unwrap_or(body.len());
    let name = &body[..name_end];
    if name.is_empty() {
        return None;
    }
    let mut rest = body[name_end..].trim_start();
    let mut attrs = Vec::new();
    while !rest.is_empty() {
        let eq = rest.find('=')?;
        let key = rest[..eq].trim();
        let after = rest[eq + 1..].trim_start();
        let q = after.chars().next().filter(|c| *c == '"' || *c == '\'')?;
        let close = after[1..].find(q)?;
        attrs.push((key.to_string(), unescape(&after[1..1 + close])?));
        rest = after[close + 2..].trim_start();
    }
    Some((name, attrs))
}

/// Replaces the predefined and numeric character references; None for an unknown or broken reference.
fn unescape(s: &str) -> Option<String> {
    if !s.contains('&') {
        return Some(s.to_string());
    }
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(amp) = rest.find('&') {
        out.push_str(&rest[..amp]);
        let r = &rest[amp + 1..];
        let semi = r.find(';')?;
        let ent = &r[..semi];
        match ent {
            "lt" => out.push('<'),
            "gt" => out.push('>'),
            "amp" => out.push('&'),
            "quot" => out.push('"'),
            "apos" => out.push('\''),
            _ => {
                let num = ent.strip_prefix('#')?;
                let code = match num.strip_prefix(['x', 'X']) {
                    Some(h) => u32::from_str_radix(h, 16).ok()?,
                    None => num.parse().ok()?,
                };
                out.push(char::from_u32(code)?);
            }
        }
        rest = &r[semi + 1..];
    }
    out.push_str(rest);
    Some(out)
}

/// Camera metadata that decides the detected color space, read once per import.
pub struct CameraMetadata;

impl CameraMetadata {
    /// Largest sidecar that is read. Best-effort: any error reads as "no metadata".
    pub const MAX_SIDECAR_BYTES: usize = 1_048_576;

    /// A sidecar's bytes, None when it is larger than `MAX_SIDECAR_BYTES` or unreadable. Never loads more than the limit
    /// plus one byte: a huge file that only happens to be named like the clip's sidecar costs nothing.
    pub fn sidecar_data(path: &Path) -> Option<Vec<u8>> {
        let fh = File::open(path).ok()?;
        let mut data = Vec::new();
        fh.take(Self::MAX_SIDECAR_BYTES as u64 + 1).read_to_end(&mut data).ok()?;
        (data.len() <= Self::MAX_SIDECAR_BYTES).then_some(data)
    }

    /// Sony sidecar first, then one walk over the MP4 boxes for Sony's embedded XML or Canon's maker notes, then (MXF,
    /// `boxes` false) a Canon XML sidecar named like the clip. Best-effort: any error reads as "no metadata".
    pub fn read_for_clip(url: &Path, boxes: bool) -> (Option<SonyMetadata>, Option<CanonMetadata>) {
        if let Some(sidecar) = SonyMetadata::sidecar_url(url) {
            return (Self::sidecar_data(&sidecar).and_then(|d| SonyMetadata::from_xml(&d).ok()), None);
        }
        if boxes {
            let Ok(found) = SonyMetadata::embedded_boxes(url) else { return (None, None) };
            return (
                found.xml.and_then(|x| SonyMetadata::from_xml(&x).ok()),
                found.canon_maker_notes.and_then(|n| CanonMetadata::from_maker_notes(&n)),
            );
        }
        let dir = url.parent().unwrap_or(Path::new(""));
        let wanted = format!("{}.xml", url.file_stem().map(|s| s.to_string_lossy()).unwrap_or_default()).to_lowercase();
        let Some(name) = SonyMetadata::listing(dir).get(&wanted).cloned() else { return (None, None) };
        (None, Self::sidecar_data(&dir.join(name)).and_then(|d| CanonMetadata::from_xml(&d)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ColorSpaceID::*;

    fn le16(v: u16, little: bool) -> Vec<u8> {
        if little { v.to_le_bytes().to_vec() } else { v.to_be_bytes().to_vec() }
    }
    fn e32(v: u32, little: bool) -> Vec<u8> {
        if little { v.to_le_bytes().to_vec() } else { v.to_be_bytes().to_vec() }
    }

    /// Canon maker notes as in `CMT3`: TIFF header, a directory with a filler tag and the log settings (tag 0x4026).
    fn maker_notes(curve: i32, gamut: i32, little: bool, ty: u16, entries: usize, with_log_info: bool) -> Vec<u8> {
        let mut values = vec![0i32; entries.max(12)];
        values[0] = (entries * 4) as i32;
        values[9] = gamut;
        values[11] = curve;
        let mut d = if little { vec![0x49, 0x49] } else { vec![0x4D, 0x4D] };
        d.extend(le16(42, little));
        d.extend(e32(8, little));
        let tags = if with_log_info { 2 } else { 1 };
        let data_at = (8 + 2 + tags * 12 + 4) as u32;
        d.extend(le16(tags as u16, little));
        d.extend([le16(0x0010, little), le16(4, little), e32(1, little), e32(0x8000_0453, little)].concat()); // model id, inline
        if with_log_info {
            d.extend(
                [le16(0x4026, little), le16(ty, little), e32(entries as u32, little), e32(data_at, little)].concat(),
            );
        }
        d.extend(e32(0, little));
        for v in values.iter().take(entries) {
            d.extend(e32(*v as u32, little));
        }
        d
    }

    fn notes(curve: i32, gamut: i32) -> Vec<u8> {
        maker_notes(curve, gamut, true, 9, 12, true)
    }

    fn space(b: &[u8]) -> Option<ColorSpaceID> {
        CanonMetadata::from_maker_notes(b).and_then(|m| m.color_space())
    }

    #[test]
    fn every_curve_and_gamut_from_the_maker_notes() {
        let expected = [
            [CanonLogBT709, CanonLogBT2020, CanonLogCinemaGamut],
            [CanonLog2BT709, CanonLog2BT2020, CanonLog2CinemaGamut],
            [CanonLog3BT709, CanonLog3BT2020, CanonLog3CinemaGamut],
        ];
        for curve in 1..=3 {
            for gamut in 0..=2 {
                for little in [true, false] {
                    let m = maker_notes(curve, gamut, little, 9, 12, true);
                    assert_eq!(
                        space(&m),
                        Some(expected[curve as usize - 1][gamut as usize]),
                        "curve {curve} gamut {gamut}"
                    );
                }
            }
        }
        assert_eq!(space(&maker_notes(3, 2, true, 4, 12, true)), Some(CanonLog3CinemaGamut));
    }

    #[test]
    fn nothing_when_log_is_off_or_a_value_is_open() {
        assert_eq!(space(&notes(0, 2)), None); // Canon Log off
        assert_eq!(space(&notes(0x7fff_ffff, 2)), None); // undefined
        assert_eq!(space(&notes(3, 0x7fff_ffff)), None); // gamut undefined
        assert_eq!(space(&notes(4, 2)), None); // unknown curve
        assert_eq!(space(&notes(3, 3)), None); // unknown gamut
        assert_eq!(space(&notes(-1, -1)), None);
    }

    #[test]
    fn damaged_maker_notes_give_nothing() {
        let good = notes(3, 2);
        assert_eq!(CanonMetadata::from_maker_notes(&[]), None);
        assert_eq!(CanonMetadata::from_maker_notes(b"not a tiff header"), None);
        assert_eq!(CanonMetadata::from_maker_notes(&maker_notes(3, 2, true, 9, 12, false)), None);
        assert_eq!(
            CanonMetadata::from_maker_notes(&maker_notes(3, 2, true, 9, 10, true)),
            None,
            "block ends before the curve"
        );
        assert_eq!(CanonMetadata::from_maker_notes(&maker_notes(3, 2, true, 3, 12, true)), None, "not 32-bit values");
        for cut in 0..good.len() {
            let _ = CanonMetadata::from_maker_notes(&good[..cut]); // never panics
        }
        assert_eq!(CanonMetadata::from_maker_notes(&good[..good.len() - 4]), None);
        let mut far = good.clone();
        far[4..8].copy_from_slice(&[0xFF, 0xFF, 0xFF, 0x7F]); // directory offset out of range
        assert_eq!(CanonMetadata::from_maker_notes(&far), None);
    }

    #[test]
    fn the_clip_choice_still_wins_input_only() {
        let detected = CanonMetadata { curve: Some(Curve::Log2), gamut: Some(Gamut::CinemaGamut) }.color_space();
        assert_eq!(detected, Some(CanonLog2CinemaGamut));
        assert_eq!(CanonMetadata { curve: Some(Curve::Log3), gamut: None }.color_space(), None);
        assert_eq!(CanonMetadata { curve: None, gamut: Some(Gamut::CinemaGamut) }.color_space(), None);
    }

    // MARK: sidecar

    fn xml(body: &str, root: &str) -> Vec<u8> {
        let name = root.split(' ').next().unwrap_or(root);
        format!("<?xml version=\"1.0\"?><{root}><Device manufacturer=\"Canon\" model=\"EOS C70\"/>{body}</{name}>")
            .into_bytes()
    }

    const CANON_ROOT: &str = "ClipInfo xmlns=\"http://www.canon.com/ns/VideoClip\"";

    fn xml_space(d: &[u8]) -> Option<ColorSpaceID> {
        CanonMetadata::from_xml(d).and_then(|m| m.color_space())
    }

    #[test]
    fn sidecar_values_must_sit_under_a_canon_element() {
        let values = "<Gamma>Canon Log 3</Gamma><ColorSpace>Cinema Gamut</ColorSpace>";
        // Canon by namespace (default or prefixed) or by element name.
        assert_eq!(xml_space(&xml(values, CANON_ROOT)), Some(CanonLog3CinemaGamut));
        assert_eq!(xml_space(&xml(values, "c:Clip xmlns:c=\"urn:schemas-canon:clip\"")), Some(CanonLog3CinemaGamut));
        assert_eq!(xml_space(&xml(&format!("<Wrap>{values}</Wrap>"), "CanonClipMetadata")), Some(CanonLog3CinemaGamut));
        // Another vendor's or an unrelated XML that only mentions Canon: nothing.
        assert_eq!(CanonMetadata::from_xml(&xml(values, "ClipInfo")), None);
        let other = "NonRealTimeMeta xmlns=\"urn:schemas-professionalDisc:nonRealTimeMeta:ver.2.20\"";
        assert_eq!(CanonMetadata::from_xml(&xml(values, other)), None);
        let notes = "<Notes><Text>shot on canon</Text><Curve>Canon Log 3</Curve><Space>Rec709</Space></Notes>";
        assert_eq!(CanonMetadata::from_xml(notes.as_bytes()), None);
        assert_eq!(CanonMetadata::from_xml(b"<Notes><Text>canon</Text><Space>Rec709</Space></Notes>"), None);
        // Values next to, not under, the Canon element do not count.
        assert_eq!(CanonMetadata::from_xml(format!("<Clip><CanonInfo/>{values}</Clip>").as_bytes()), None);
        let beside =
            "<Clip><CanonInfo><Gamma>Canon Log 3</Gamma></CanonInfo><ColorSpace>Cinema Gamut</ColorSpace></Clip>";
        assert_eq!(xml_space(beside.as_bytes()), None);
    }

    #[test]
    fn sidecar_values() {
        let x = |body: &str| xml(body, CANON_ROOT);
        assert_eq!(
            xml_space(&x("<Gamma>Canon Log 3</Gamma><ColorSpace>Cinema Gamut</ColorSpace>")),
            Some(CanonLog3CinemaGamut)
        );
        let attrs = "<Item name=\"Gamma\" value=\"C-Log2\"/><Item name=\"Gamut\" value=\"BT.2020\"/>";
        assert_eq!(xml_space(&x(attrs)), Some(CanonLog2BT2020));
        assert_eq!(xml_space(&x("<Gamma> Canon Log </Gamma><ColorSpace>BT.709</ColorSpace>")), Some(CanonLogBT709));
        // Curve without a gamut, two curves, two gamuts, a name inside a longer value, no Canon: nothing preselected.
        assert_eq!(xml_space(&x("<Gamma>Canon Log 3</Gamma>")), None);
        assert!(CanonMetadata::from_xml(&x("<Gamma>Canon Log 3</Gamma>")).is_some());
        assert_eq!(
            CanonMetadata::from_xml(&x(
                "<Gamma>Canon Log 3</Gamma><Look>Canon Log 2</Look><ColorSpace>Cinema Gamut</ColorSpace>"
            )),
            None
        );
        assert_eq!(
            xml_space(&x("<Gamma>Canon Log 3</Gamma><ColorSpace>Cinema Gamut</ColorSpace><View>BT.709</View>")),
            None
        );
        assert_eq!(
            CanonMetadata::from_xml(&x("<Note>Canon Log 3 to BT.709 LUT</Note><ColorSpace>Cinema Gamut</ColorSpace>")),
            None
        );
        assert_eq!(CanonMetadata::from_xml(&x("<Gamma>Wide DR</Gamma><ColorSpace>BT.709</ColorSpace>")), None);
        let no_canon = b"<Clip><Gamma>C-Log3</Gamma><ColorSpace>Cinema Gamut</ColorSpace></Clip>";
        assert_eq!(CanonMetadata::from_xml(no_canon), None);
        assert_eq!(CanonMetadata::from_xml(b"<Canon><Gamma>"), None);
    }

    #[test]
    fn oversized_sidecar_is_never_loaded() {
        let dir = std::env::temp_dir().join(format!("canon-{}", std::process::id()));
        assert!(std::fs::create_dir_all(&dir).is_ok());
        let side = dir.join("A001.XML");
        let values = "<Gamma>Canon Log 3</Gamma><ColorSpace>Cinema Gamut</ColorSpace>";
        let padding = format!("<!--{}-->", "x".repeat(CameraMetadata::MAX_SIDECAR_BYTES));
        assert!(std::fs::write(&side, xml(values, CANON_ROOT)).is_ok());
        assert!(CameraMetadata::sidecar_data(&side).is_some());
        assert!(std::fs::write(&side, xml(&format!("{values}{padding}"), CANON_ROOT)).is_ok());
        assert_eq!(CameraMetadata::sidecar_data(&side), None);
        assert_eq!(CameraMetadata::sidecar_data(&dir.join("missing.xml")), None);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
