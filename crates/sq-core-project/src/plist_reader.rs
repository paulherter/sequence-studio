// SPDX-License-Identifier: GPL-3.0-or-later
//! A property-list reader for Final Cut Pro `.commandset` files: the XML form and the binary form (`bplist00`), the two
//! forms `PropertyListSerialization` reads in the Swift app. Values the command-set reader never looks at become `Other`.

use crate::foreign_keymap::PlistValue;
use std::collections::BTreeMap;

/// Parses a property list; `None` when the bytes are neither form.
pub fn parse_plist(data: &[u8]) -> Option<PlistValue> {
    if data.starts_with(b"bplist00") {
        Binary { data }.root()
    } else {
        Xml::new(std::str::from_utf8(data).ok()?).root()
    }
}

// MARK: XML

struct Xml<'a> {
    s: &'a str,
    pos: usize,
}

enum Tag<'a> {
    Open(&'a str),
    Close(&'a str),
    Empty(&'a str),
}

impl<'a> Xml<'a> {
    fn new(s: &'a str) -> Self {
        Xml { s, pos: 0 }
    }

    fn root(mut self) -> Option<PlistValue> {
        loop {
            match self.next_tag()? {
                Tag::Open("plist") => return self.value(),
                Tag::Open(_) | Tag::Close(_) | Tag::Empty(_) => {}
            }
        }
    }

    /// The next `<...>` tag, skipping declarations, comments and doctype.
    fn next_tag(&mut self) -> Option<Tag<'a>> {
        loop {
            let start = self.pos + self.s[self.pos..].find('<')?;
            let rest = &self.s[start..];
            if rest.starts_with("<!--") {
                self.pos = start + rest.find("-->")? + 3;
                continue;
            }
            let end = start + Self::tag_end(rest)?;
            self.pos = end + 1;
            let inner = &self.s[start + 1..end];
            if inner.starts_with('?') || inner.starts_with('!') {
                continue;
            }
            if let Some(name) = inner.strip_prefix('/') {
                return Some(Tag::Close(name.trim()));
            }
            let (body, empty) = inner.strip_suffix('/').map_or((inner, false), |b| (b, true));
            let name = body.split_whitespace().next().unwrap_or("");
            return Some(if empty { Tag::Empty(name) } else { Tag::Open(name) });
        }
    }

    /// Index of the `>` closing the tag that starts the text (a doctype may hold `[ ... ]`).
    fn tag_end(rest: &str) -> Option<usize> {
        if rest.starts_with("<!DOCTYPE")
            && let Some(open) = rest.find('[')
            && rest.find('>').is_some_and(|g| g > open)
        {
            return Some(rest.find("]>")? + 1);
        }
        rest.find('>')
    }

    /// The text up to the next `<`, entities decoded.
    fn text(&mut self) -> String {
        let end = self.s[self.pos..].find('<').map_or(self.s.len(), |i| self.pos + i);
        let raw = &self.s[self.pos..end];
        self.pos = end;
        decode_entities(raw)
    }

    fn close(&mut self, name: &str) -> Option<()> {
        matches!(self.next_tag()?, Tag::Close(n) if n == name).then_some(())
    }

    /// One value: its opening tag is the next tag.
    fn value(&mut self) -> Option<PlistValue> {
        match self.next_tag()? {
            Tag::Open("dict") => {
                let mut map = BTreeMap::new();
                loop {
                    match self.next_tag()? {
                        Tag::Close("dict") => return Some(PlistValue::Dict(map)),
                        Tag::Open("key") => {
                            let key = self.text();
                            self.close("key")?;
                            map.insert(key, self.value()?);
                        }
                        _ => return None,
                    }
                }
            }
            Tag::Empty("dict") => Some(PlistValue::Dict(BTreeMap::new())),
            Tag::Open("array") => {
                let mut items = Vec::new();
                loop {
                    let save = self.pos;
                    if matches!(self.next_tag()?, Tag::Close("array")) {
                        return Some(PlistValue::Array(items));
                    }
                    self.pos = save;
                    items.push(self.value()?);
                }
            }
            Tag::Empty("array") => Some(PlistValue::Array(Vec::new())),
            Tag::Open("string") => {
                let t = self.text();
                self.close("string")?;
                Some(PlistValue::String(t))
            }
            Tag::Empty("string") => Some(PlistValue::String(String::new())),
            Tag::Open("integer") => {
                let t = self.text();
                self.close("integer")?;
                t.trim().parse().ok().map(PlistValue::Int)
            }
            Tag::Open(name @ ("real" | "date" | "data")) => {
                self.text();
                self.close(name)?;
                Some(PlistValue::Other)
            }
            Tag::Empty("true" | "false" | "data" | "real" | "date") => Some(PlistValue::Other),
            _ => None,
        }
    }
}

fn decode_entities(raw: &str) -> String {
    if !raw.contains('&') {
        return raw.to_string();
    }
    let mut out = String::with_capacity(raw.len());
    let mut rest = raw;
    while let Some(i) = rest.find('&') {
        out.push_str(&rest[..i]);
        rest = &rest[i..];
        let Some(semi) = rest.find(';') else { break };
        let decoded = match &rest[1..semi] {
            "amp" => Some('&'),
            "lt" => Some('<'),
            "gt" => Some('>'),
            "quot" => Some('"'),
            "apos" => Some('\''),
            e => e
                .strip_prefix("#x")
                .and_then(|h| u32::from_str_radix(h, 16).ok())
                .or_else(|| e.strip_prefix('#').and_then(|d| d.parse().ok()))
                .and_then(char::from_u32),
        };
        match decoded {
            Some(c) => out.push(c),
            None => out.push_str(&rest[..=semi]),
        }
        rest = &rest[semi + 1..];
    }
    out.push_str(rest);
    out
}

// MARK: Binary

struct Binary<'a> {
    data: &'a [u8],
}

impl Binary<'_> {
    fn uint(&self, at: usize, size: usize) -> Option<u64> {
        let bytes = self.data.get(at..at.checked_add(size)?)?;
        Some(bytes.iter().fold(0u64, |acc, b| (acc << 8) | u64::from(*b)))
    }

    fn root(&self) -> Option<PlistValue> {
        let t = self.data.len().checked_sub(32)?;
        let offset_size = usize::from(*self.data.get(t + 6)?);
        let ref_size = usize::from(*self.data.get(t + 7)?);
        let count = usize::try_from(self.uint(t + 8, 8)?).ok()?;
        let top = usize::try_from(self.uint(t + 16, 8)?).ok()?;
        let table = usize::try_from(self.uint(t + 24, 8)?).ok()?;
        let ctx = Table { b: self, offset_size, ref_size, count, table };
        ctx.object(top, 0)
    }
}

struct Table<'a, 'b> {
    b: &'a Binary<'b>,
    offset_size: usize,
    ref_size: usize,
    count: usize,
    table: usize,
}

impl Table<'_, '_> {
    fn object(&self, index: usize, depth: usize) -> Option<PlistValue> {
        if index >= self.count || depth > 64 {
            return None;
        }
        let at = usize::try_from(self.b.uint(self.table + index * self.offset_size, self.offset_size)?).ok()?;
        let marker = *self.b.data.get(at)?;
        let (kind, low) = (marker >> 4, usize::from(marker & 0x0F));
        // Length of the sized kinds and where their content starts.
        let sized = |this: &Self| -> Option<(usize, usize)> {
            if low != 0x0F {
                return Some((low, at + 1));
            }
            let int_marker = *this.b.data.get(at + 1)?;
            let width = 1usize << (int_marker & 0x0F);
            Some((usize::try_from(this.b.uint(at + 2, width)?).ok()?, at + 2 + width))
        };
        match kind {
            0x0 => Some(PlistValue::Other),
            0x1 => {
                let width = 1usize << low;
                let raw = self.b.uint(at + 1, width.min(8))?;
                // Eight-byte integers are signed (the cast keeps the bits); shorter ones are unsigned and fit.
                Some(PlistValue::Int(raw as i64))
            }
            0x2 | 0x3 | 0x8 => Some(PlistValue::Other),
            0x4 => Some(PlistValue::Other),
            0x5 => {
                let (n, start) = sized(self)?;
                let bytes = self.b.data.get(start..start.checked_add(n)?)?;
                Some(PlistValue::String(String::from_utf8_lossy(bytes).into_owned()))
            }
            0x6 => {
                let (n, start) = sized(self)?;
                let bytes = self.b.data.get(start..start.checked_add(n.checked_mul(2)?)?)?;
                let units: Vec<u16> = bytes.as_chunks::<2>().0.iter().map(|c| u16::from_be_bytes(*c)).collect();
                Some(PlistValue::String(String::from_utf16_lossy(&units)))
            }
            0xA => {
                let (n, start) = sized(self)?;
                let mut items = Vec::with_capacity(n.min(1024));
                for i in 0..n {
                    let r = usize::try_from(self.b.uint(start + i * self.ref_size, self.ref_size)?).ok()?;
                    items.push(self.object(r, depth + 1)?);
                }
                Some(PlistValue::Array(items))
            }
            0xD => {
                let (n, start) = sized(self)?;
                let mut map = BTreeMap::new();
                for i in 0..n {
                    let k = usize::try_from(self.b.uint(start + i * self.ref_size, self.ref_size)?).ok()?;
                    let v = usize::try_from(self.b.uint(start + (n + i) * self.ref_size, self.ref_size)?).ok()?;
                    let PlistValue::String(key) = self.object(k, depth + 1)? else { return None };
                    map.insert(key, self.object(v, depth + 1)?);
                }
                Some(PlistValue::Dict(map))
            }
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const XML: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Name</key><string>A &amp; B</string>
  <!-- comment -->
  <key>Count</key><integer>-3</integer>
  <key>On</key><true/>
  <key>Rate</key><real>1.5</real>
  <key>List</key><array><string>x</string><string/><dict/></array>
  <key>Nested</key><dict><key>k</key><string>&#65;&#x42;</string></dict>
</dict>
</plist>"#;

    #[test]
    fn reads_the_xml_form() {
        let Some(PlistValue::Dict(d)) = parse_plist(XML.as_bytes()) else { panic!("not a dict") };
        assert_eq!(d["Name"], PlistValue::String("A & B".into()));
        assert_eq!(d["Count"], PlistValue::Int(-3));
        assert_eq!(d["On"], PlistValue::Other);
        assert_eq!(d["Rate"], PlistValue::Other);
        assert_eq!(
            d["List"],
            PlistValue::Array(vec![
                PlistValue::String("x".into()),
                PlistValue::String(String::new()),
                PlistValue::Dict(BTreeMap::new())
            ])
        );
        let PlistValue::Dict(n) = &d["Nested"] else { panic!() };
        assert_eq!(n["k"], PlistValue::String("AB".into()));
    }

    #[test]
    fn reads_the_binary_form() {
        // {"a": "hi", "n": [7]} written by hand: objects 0 dict, 1 "a", 2 "n", 3 "hi", 4 array, 5 int 7.
        let mut d: Vec<u8> = b"bplist00".to_vec();
        let mut offs = Vec::new();
        let mut push = |d: &mut Vec<u8>, bytes: &[u8]| {
            offs.push(d.len() as u8);
            d.extend_from_slice(bytes);
        };
        push(&mut d, &[0xD2, 1, 2, 3, 4]);
        push(&mut d, &[0x51, b'a']);
        push(&mut d, &[0x51, b'n']);
        push(&mut d, &[0x52, b'h', b'i']);
        push(&mut d, &[0xA1, 5]);
        push(&mut d, &[0x10, 7]);
        let table = d.len();
        d.extend_from_slice(&offs);
        d.extend_from_slice(&[0, 0, 0, 0, 0, 0, 1, 1]);
        d.extend_from_slice(&6u64.to_be_bytes());
        d.extend_from_slice(&0u64.to_be_bytes());
        d.extend_from_slice(&(table as u64).to_be_bytes());
        let Some(PlistValue::Dict(m)) = parse_plist(&d) else { panic!("not a dict") };
        assert_eq!(m["a"], PlistValue::String("hi".into()));
        assert_eq!(m["n"], PlistValue::Array(vec![PlistValue::Int(7)]));
    }

    #[test]
    fn rejects_other_bytes() {
        assert_eq!(parse_plist(b"id := Ctrl+A"), None);
        assert_eq!(parse_plist(b"bplist00"), None);
        assert_eq!(parse_plist(&[0xFF, 0xFE]), None);
    }
}
