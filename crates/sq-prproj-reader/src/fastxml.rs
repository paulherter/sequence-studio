// SPDX-License-Identifier: GPL-3.0-or-later
//! Byte-level UTF-8 XML reader building the `Node` tree in one pass: port of `PRFastXML`. Returns `None` for anything it
//! does not handle (non-UTF-8 encoding, DTD, malformed input), as the Swift reader does.

use crate::container::Node;
use std::collections::{BTreeMap, HashMap};

pub struct Parsed {
    pub root: Node,
    pub binaries: HashMap<String, String>,
}

struct Fail;

pub fn parse(data: &[u8]) -> Option<Parsed> {
    let mut p = Parser { buf: data, i: 0, stack: Vec::new(), texts: Vec::new(), binaries: HashMap::new() };
    p.run().ok()
}

struct Parser<'a> {
    buf: &'a [u8],
    i: usize,
    stack: Vec<Node>,
    texts: Vec<Vec<u8>>,
    binaries: HashMap<String, String>,
}

fn is_space(c: u8) -> bool {
    c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D
}

fn is_name_end(c: u8) -> bool {
    is_space(c) || c == b'>' || c == b'/' || c == b'='
}

impl Parser<'_> {
    fn at(&self, k: usize) -> u8 {
        self.buf.get(k).copied().unwrap_or(0)
    }

    fn starts(&self, s: &[u8], k: usize) -> bool {
        self.buf.get(k..).is_some_and(|r| r.starts_with(s))
    }

    fn find(&self, s: &[u8], from: usize) -> Result<usize, Fail> {
        let hay = self.buf.get(from..).ok_or(Fail)?;
        hay.windows(s.len()).position(|w| w == s).map(|p| p + from).ok_or(Fail)
    }

    fn name(&mut self) -> Result<String, Fail> {
        let s = self.i;
        while self.i < self.buf.len() && !is_name_end(self.buf[self.i]) {
            self.i += 1;
        }
        if self.i <= s || self.i >= self.buf.len() {
            return Err(Fail);
        }
        std::str::from_utf8(&self.buf[s..self.i]).map(str::to_string).map_err(|_| Fail)
    }

    fn skip_space(&mut self) {
        while self.i < self.buf.len() && is_space(self.buf[self.i]) {
            self.i += 1;
        }
    }

    fn run(&mut self) -> Result<Parsed, Fail> {
        if self.starts(&[0xEF, 0xBB, 0xBF], 0) {
            self.i = 3;
        }
        let mut root: Option<Node> = None;
        while self.i < self.buf.len() {
            if self.buf[self.i] != b'<' {
                let s = self.i;
                while self.i < self.buf.len() && self.buf[self.i] != b'<' {
                    self.i += 1;
                }
                match self.texts.last_mut() {
                    None => {
                        if self.buf[s..self.i].iter().any(|&c| !is_space(c)) {
                            return Err(Fail);
                        }
                    }
                    Some(t) => t.extend_from_slice(&self.buf[s..self.i]),
                }
                continue;
            }
            let c = self.at(self.i + 1);
            if c == b'?' {
                let e = self.find(b"?>", self.i + 2)?;
                if self.starts(b"<?xml", self.i) && !is_utf8_declaration(&self.buf[self.i..e]) {
                    return Err(Fail);
                }
                self.i = e + 2;
            } else if c == b'!' {
                if self.starts(b"<!--", self.i) {
                    self.i = self.find(b"-->", self.i + 4)? + 3;
                } else if self.starts(b"<![CDATA[", self.i) {
                    if self.texts.is_empty() {
                        return Err(Fail);
                    }
                    let e = self.find(b"]]>", self.i + 9)?;
                    let t = self.texts.last_mut().ok_or(Fail)?;
                    for &c in &self.buf[self.i + 9..e] {
                        if c == b'&' {
                            t.extend_from_slice(b"&amp;");
                        } else {
                            t.push(c);
                        }
                    }
                    self.i = e + 3;
                } else {
                    return Err(Fail);
                }
            } else if c == b'/' {
                self.i += 2;
                let n = self.name()?;
                self.skip_space();
                if self.at(self.i) != b'>' || self.stack.last().is_none_or(|top| top.name != n) {
                    return Err(Fail);
                }
                self.i += 1;
                if let Some(done) = self.close()? {
                    root = Some(done);
                }
            } else {
                if root.is_some() {
                    return Err(Fail);
                }
                self.i += 1;
                let n = self.name()?;
                let mut attrs: BTreeMap<String, String> = BTreeMap::new();
                let mut self_closing = false;
                loop {
                    self.skip_space();
                    let ch = self.at(self.i);
                    if ch == b'>' {
                        self.i += 1;
                        break;
                    }
                    if ch == b'/' {
                        if self.at(self.i + 1) != b'>' {
                            return Err(Fail);
                        }
                        self.i += 2;
                        self_closing = true;
                        break;
                    }
                    let key = self.name()?;
                    self.skip_space();
                    if self.at(self.i) != b'=' {
                        return Err(Fail);
                    }
                    self.i += 1;
                    self.skip_space();
                    let q = self.at(self.i);
                    if q != b'"' && q != b'\'' {
                        return Err(Fail);
                    }
                    let vs = self.i + 1;
                    let mut e = vs;
                    while e < self.buf.len() && self.buf[e] != q {
                        if self.buf[e] == b'<' {
                            return Err(Fail);
                        }
                        e += 1;
                    }
                    if e >= self.buf.len() || attrs.contains_key(&key) {
                        return Err(Fail);
                    }
                    attrs.insert(key, decode(&self.buf[vs..e], true)?);
                    self.i = e + 1;
                    let nx = self.at(self.i);
                    if !(is_space(nx) || nx == b'>' || nx == b'/') {
                        return Err(Fail);
                    }
                }
                self.stack.push(Node { name: n, attributes: attrs, text: String::new(), children: Vec::new() });
                self.texts.push(Vec::new());
                if self_closing && let Some(done) = self.close()? {
                    root = Some(done);
                }
            }
        }
        match root {
            Some(root) if self.stack.is_empty() => Ok(Parsed { root, binaries: std::mem::take(&mut self.binaries) }),
            _ => Err(Fail),
        }
    }

    /// Ends the innermost element; returns it when it was the root.
    fn close(&mut self) -> Result<Option<Node>, Fail> {
        let mut node = self.stack.pop().ok_or(Fail)?;
        let raw = self.texts.pop().ok_or(Fail)?;
        let (mut a, mut e) = (0, raw.len());
        while a < e && is_space(raw[a]) {
            a += 1;
        }
        while e > a && is_space(raw[e - 1]) {
            e -= 1;
        }
        node.text = if a == e { String::new() } else { trimmed(decode(&raw[a..e], false)?) };
        if let Some(h) = node.attributes.get("BinaryHash")
            && !node.text.is_empty()
            && !self.binaries.contains_key(h)
        {
            self.binaries.insert(h.clone(), node.text.clone());
        }
        match self.stack.last_mut() {
            None => Ok(Some(node)),
            Some(parent) => {
                parent.children.push(node);
                Ok(None)
            }
        }
    }
}

/// `<?xml ... encoding="UTF-8"?>`: UTF-8 (or no encoding named) is all this reader handles.
fn is_utf8_declaration(decl: &[u8]) -> bool {
    let s = String::from_utf8_lossy(decl).to_lowercase();
    let Some(r) = s.find("encoding") else { return true };
    let rest = s[r + "encoding".len()..].trim_start_matches([' ', '=', '"', '\'']);
    rest.starts_with("utf-8") || rest.starts_with("utf8")
}

/// Unicode white space and newlines as Foundation's `CharacterSet.whitespacesAndNewlines` (Zs, Zl, Zp, U+0009-U+000D, U+0085).
fn is_ws(c: char) -> bool {
    matches!(c as u32,
        0x09..=0x0D | 0x20 | 0x85 | 0xA0 | 0x1680 | 0x2000..=0x200B | 0x2028 | 0x2029 | 0x202F | 0x205F | 0x3000)
}

fn trimmed(s: String) -> String {
    let t = s.trim_matches(is_ws);
    if t.len() == s.len() { s } else { t.to_string() }
}

/// Character data / attribute value to String: CR LF and CR become LF, entities and character references are resolved, in
/// attributes literal tab / CR / LF become spaces. Invalid UTF-8 or an unknown entity fails.
fn decode(b: &[u8], attribute: bool) -> Result<String, Fail> {
    if !b.iter().any(|&c| c == b'&' || c == 0x0D || (attribute && (c == 0x09 || c == 0x0A))) {
        return std::str::from_utf8(b).map(str::to_string).map_err(|_| Fail);
    }
    let mut out: Vec<u8> = Vec::with_capacity(b.len());
    let mut k = 0;
    while k < b.len() {
        let c = b[k];
        if c == 0x0D {
            out.push(if attribute { 0x20 } else { 0x0A });
            k += if k + 1 < b.len() && b[k + 1] == 0x0A { 2 } else { 1 };
            continue;
        }
        if attribute && (c == 0x09 || c == 0x0A) {
            out.push(0x20);
            k += 1;
            continue;
        }
        if c != b'&' {
            out.push(c);
            k += 1;
            continue;
        }
        let mut e = k + 1;
        while e < b.len() && b[e] != b';' && e - k < 12 {
            e += 1;
        }
        if e >= b.len() || b[e] != b';' {
            return Err(Fail);
        }
        let r = String::from_utf8_lossy(&b[k + 1..e]);
        match &*r {
            "amp" => out.push(b'&'),
            "lt" => out.push(b'<'),
            "gt" => out.push(b'>'),
            "quot" => out.push(b'"'),
            "apos" => out.push(b'\''),
            other => {
                let Some(num) = other.strip_prefix('#') else { return Err(Fail) };
                let (digits, radix) = match num.strip_prefix('x') {
                    Some(h) => (h, 16),
                    None => (num, 10),
                };
                // Swift `UInt32(_:radix:)` accepts one leading '+' (a leading '-' only parses "-0", which is rejected below).
                let digits = digits.strip_prefix('+').unwrap_or(digits);
                if digits.is_empty() || !digits.chars().all(|c| c.is_digit(radix)) {
                    return Err(Fail);
                }
                let v = u32::from_str_radix(digits, radix).map_err(|_| Fail)?;
                let ch = char::from_u32(v).ok_or(Fail)?;
                if v == 0 || !(v == 0x9 || v == 0xA || v == 0xD || v >= 0x20) {
                    return Err(Fail);
                }
                let mut buf = [0u8; 4];
                out.extend_from_slice(ch.encode_utf8(&mut buf).as_bytes());
            }
        }
        k = e + 1;
    }
    String::from_utf8(out).map_err(|_| Fail)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(s: &str) -> Option<Parsed> {
        parse(s.as_bytes())
    }

    #[test]
    fn tree_text_and_attributes() {
        let r =
            p("<?xml version=\"1.0\" encoding=\"UTF-8\"?><a x=\"1&amp;2\ty\"> hi <b/><c>&#65;<![CDATA[<&>]]></c></a>")
                .unwrap();
        assert_eq!(r.root.attributes["x"], "1&2 y");
        assert_eq!(r.root.text, "hi");
        assert_eq!(r.root.children[1].text, "A<&>");
    }

    #[test]
    fn declines_what_it_does_not_handle() {
        assert!(p("<?xml version=\"1.0\" encoding=\"UTF-16\"?><a/>").is_none());
        assert!(p("<!DOCTYPE a><a/>").is_none());
        assert!(p("<a><b></a>").is_none());
        assert!(p("<a/><b/>").is_none());
        assert!(p("<a x=\"1\" x=\"2\"/>").is_none());
        assert!(p("<a>&bogus;</a>").is_none());
        assert!(p("text<a/>").is_none());
    }

    #[test]
    fn binaries_keep_first_non_empty() {
        let r = p("<r><a BinaryHash=\"h\"> </a><b BinaryHash=\"h\">v1</b><c BinaryHash=\"h\">v2</c></r>").unwrap();
        assert_eq!(r.binaries["h"], "v1");
    }
}
