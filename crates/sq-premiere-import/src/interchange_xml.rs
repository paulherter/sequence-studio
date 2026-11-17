// SPDX-License-Identifier: GPL-3.0-or-later
//! Swift: InterchangeXML.swift. A small element tree for the XML interchange readers (FCP7 XML, FCPXML) and the
//! `file://` URL to path conversion.

use crate::interchange_model::InterchangeError;
use crate::prdocument::is_swift_whitespace;
use sq_prproj_reader::{Node, fastxml};

/// Foundation's `.whitespacesAndNewlines`: Unicode white space plus U+200B.
pub(crate) fn is_blank_or_newline(c: char) -> bool {
    c.is_whitespace() || c == '\u{200B}'
}

/// `trimmingCharacters(in: .whitespaces)`.
pub(crate) fn trim_blanks(s: &str) -> &str {
    s.trim_matches(is_swift_whitespace)
}

/// `NSString.lastPathComponent`: the part after the last `/`, ignoring trailing slashes.
pub(crate) fn last_path_component(p: &str) -> String {
    let t = p.trim_end_matches('/');
    if t.is_empty() {
        return p.chars().take(1).collect();
    }
    t.rsplit('/').next().unwrap_or(t).to_string()
}

/// Element lookups of the Swift `IXNode` (the tree itself is `sq_prproj_reader::Node`).
pub trait IxNodeExt {
    /// Direct children called `name`.
    fn kids(&self, name: &str) -> Vec<&Node>;
    /// Text of the first child called `name`.
    fn kid_text(&self, name: &str) -> Option<&str>;
    /// Integer text (blanks trimmed) of the first child called `name`.
    fn kid_int(&self, name: &str) -> Option<i64>;
    /// Every descendant called `name`, in document order.
    fn descendants_named(&self, name: &str) -> Vec<&Node>;
}

impl IxNodeExt for Node {
    fn kids(&self, name: &str) -> Vec<&Node> {
        self.children.iter().filter(|c| c.name == name).collect()
    }

    fn kid_text(&self, name: &str) -> Option<&str> {
        self.child(name).map(|c| c.text.as_str())
    }

    fn kid_int(&self, name: &str) -> Option<i64> {
        self.kid_text(name).and_then(|t| trim_blanks(t).parse().ok())
    }

    fn descendants_named(&self, name: &str) -> Vec<&Node> {
        let mut out = Vec::new();
        for c in &self.children {
            if c.name == name {
                out.push(c);
            }
            out.extend(c.descendants_named(name));
        }
        out
    }
}

/// Parses XML into the element tree. A plain `<!DOCTYPE name>` (what FCP7 XML and FCPXML start with) is dropped first, the
/// fast reader declines any DTD.
pub(crate) fn parse(data: &[u8]) -> Result<Node, InterchangeError> {
    let stripped = strip_simple_doctype(data);
    fastxml::parse(&stripped).map(|p| p.root).ok_or_else(|| InterchangeError::Malformed("no root element".to_string()))
}

fn strip_simple_doctype(data: &[u8]) -> Vec<u8> {
    const TAG: &[u8] = b"<!DOCTYPE";
    let Some(at) = data.windows(TAG.len()).position(|w| w == TAG) else { return data.to_vec() };
    let Some(len) = data[at..].iter().position(|&b| b == b'>') else { return data.to_vec() };
    if data[at..at + len].contains(&b'[') {
        return data.to_vec();
    }
    [&data[..at], &data[at + len + 1..]].concat()
}

/// A POSIX or Windows path from a `file://` URL string (percent-decoded; `localhost` host dropped; `/C:/x` -> `C:\x`).
pub(crate) fn path_from_url(s: &str) -> String {
    let t = s.trim_matches(is_blank_or_newline);
    if !t.to_lowercase().starts_with("file:") {
        return t.to_string();
    }
    let mut t: &str = t.get(5..).unwrap_or("");
    if t.starts_with("//") && !t.starts_with("///") {
        t = &t[2..];
        if let Some(i) = t.find('/') {
            t = &t[i..];
        }
    } else if t.starts_with("//") {
        t = &t[2..];
    }
    let decoded = percent_decode(t).unwrap_or_else(|| t.to_string());
    let chars: Vec<char> = decoded.chars().collect();
    if chars.len() > 2 && chars[0] == '/' && chars[2] == ':' {
        return decoded[1..].replace('/', "\\");
    }
    decoded
}

/// `removingPercentEncoding`: `None` on a bad escape or when the bytes are not UTF-8.
fn percent_decode(s: &str) -> Option<String> {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' {
            let hex = s.get(i + 1..i + 3)?;
            out.push(u8::from_str_radix(hex, 16).ok()?);
            i += 3;
        } else {
            out.push(b[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn urls_become_paths() {
        assert_eq!(path_from_url("file://localhost/Volumes/A%20B/c.mov"), "/Volumes/A B/c.mov");
        assert_eq!(path_from_url("file:///Users/x/a.mov"), "/Users/x/a.mov");
        assert_eq!(path_from_url("file://localhost/C:/Media/a.mov"), "C:\\Media\\a.mov");
        assert_eq!(path_from_url("  plain.mov "), "plain.mov");
        assert_eq!(path_from_url("file:///bad%zz"), "/bad%zz");
    }

    #[test]
    fn doctype_is_dropped_and_tree_reads() {
        let n = parse(b"<?xml version=\"1.0\"?>\n<!DOCTYPE xmeml>\n<xmeml><a><b>1</b><b> 2 </b></a></xmeml>");
        let n = n.unwrap_or_default();
        assert_eq!(n.name, "xmeml");
        assert_eq!(n.descendants_named("b").len(), 2);
        assert_eq!(n.child("a").and_then(|a| a.kid_int("b")), Some(1));
        assert!(parse(b"<a><b></a>").is_err());
    }
}
