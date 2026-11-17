// SPDX-License-Identifier: GPL-3.0-or-later
//! Port of `PRNode`, `PRObjectTable` (fast path only; the Foundation `XMLParser` fallback is not ported) and the error kinds.

use std::collections::{BTreeMap, HashMap};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ImportError {
    NotPremiereProject,
    CorruptArchive,
    Xml(String),
}

impl std::fmt::Display for ImportError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ImportError::NotPremiereProject => f.write_str("This is not a Premiere Pro project file."),
            ImportError::CorruptArchive => f.write_str("The project file is damaged."),
            ImportError::Xml(why) => write!(f, "The project file could not be read: {why}."),
        }
    }
}

impl From<crate::inflate::Corrupt> for ImportError {
    fn from(_: crate::inflate::Corrupt) -> Self {
        ImportError::CorruptArchive
    }
}

/// One XML element: name, attributes (ordered by UTF-8 bytes), trimmed text and children.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Node {
    pub name: String,
    pub attributes: BTreeMap<String, String>,
    pub text: String,
    pub children: Vec<Node>,
}

impl Node {
    /// First child by name; `path` may go deeper with "/".
    pub fn child(&self, path: &str) -> Option<&Node> {
        let mut n = self;
        for part in path.split('/').filter(|p| !p.is_empty()) {
            n = n.children.iter().find(|c| c.name == part)?;
        }
        Some(n)
    }

    pub fn object_id(&self) -> Option<&str> {
        self.attributes.get("ObjectID").or_else(|| self.attributes.get("ObjectUID")).map(String::as_str)
    }

    pub fn reference(&self) -> Option<&str> {
        self.attributes.get("ObjectRef").or_else(|| self.attributes.get("ObjectURef")).map(String::as_str)
    }
}

impl Drop for Node {
    // Deeply nested files must not overflow the stack when the tree is freed.
    fn drop(&mut self) {
        let mut stack = std::mem::take(&mut self.children);
        while let Some(mut n) = stack.pop() {
            stack.append(&mut n.children);
        }
    }
}

/// The flat top-level object list of a project, by ObjectID / ObjectUID.
pub struct ObjectTable {
    pub root: Node,
    index: HashMap<String, usize>,
    pub binaries: HashMap<String, String>,
}

impl ObjectTable {
    pub fn new(xml: &[u8]) -> Result<ObjectTable, ImportError> {
        // Swift falls back to Foundation's XMLParser when the fast reader declines. Here the one decline that real files hit,
        // a text that is not UTF-8 (UTF-16 with a byte-order mark, a declared ISO-8859-1), is converted and read again.
        // shortcut: a DTD or an undeclared odd encoding still fails with "fast reader declined"; upgrade by adding a full XML
        // parser crate (quick-xml, MIT) as the fallback if a real project needs it.
        let fast = crate::fastxml::parse(xml)
            .or_else(|| transcoded_to_utf8(xml).and_then(|utf8| crate::fastxml::parse(&utf8)))
            .ok_or_else(|| ImportError::Xml("fast reader declined".into()))?;
        if fast.root.name != "PremiereData" {
            return Err(ImportError::NotPremiereProject);
        }
        let mut index = HashMap::new();
        for (i, c) in fast.root.children.iter().enumerate() {
            if let Some(id) = c.object_id() {
                index.insert(id.to_string(), i);
            }
        }
        Ok(ObjectTable { root: fast.root, index, binaries: fast.binaries })
    }

    pub fn get(&self, id: &str) -> Option<&Node> {
        self.index.get(id).map(|&i| &self.root.children[i])
    }

    pub fn object_count(&self) -> usize {
        self.index.len()
    }

    pub fn deref(&self, node: Option<&Node>) -> Option<&Node> {
        node.and_then(|n| n.reference()).and_then(|r| self.get(r))
    }
}

/// `xml` as UTF-8 when it is UTF-16 (byte-order mark), UTF-8 with a mark, or declares ISO-8859-1 / Windows-1252; the
/// declaration is dropped so the fast reader accepts it. `None` for anything else.
fn transcoded_to_utf8(xml: &[u8]) -> Option<Vec<u8>> {
    let text: String = if let Some(rest) = xml.strip_prefix(&[0xFF, 0xFE]) {
        let units: Vec<u16> = rest.as_chunks::<2>().0.iter().map(|b| u16::from_le_bytes(*b)).collect();
        String::from_utf16(&units).ok()?
    } else if let Some(rest) = xml.strip_prefix(&[0xFE, 0xFF]) {
        let units: Vec<u16> = rest.as_chunks::<2>().0.iter().map(|b| u16::from_be_bytes(*b)).collect();
        String::from_utf16(&units).ok()?
    } else if let Some(rest) = xml.strip_prefix(&[0xEF, 0xBB, 0xBF]) {
        return Some(rest.to_vec());
    } else {
        let head = String::from_utf8_lossy(&xml[..xml.len().min(200)]).to_ascii_lowercase();
        if !(head.starts_with("<?xml") && (head.contains("iso-8859-1") || head.contains("windows-1252"))) {
            return None;
        }
        // Latin-1 code points equal the first 256 Unicode scalars (Windows-1252's 0x80-0x9F differ; none appear in project files).
        xml.iter().map(|&b| char::from(b)).collect()
    };
    let body = match text.strip_prefix("<?xml") {
        Some(rest) => &rest[rest.find("?>")? + 2..],
        None => &text,
    };
    Some(body.trim_start().as_bytes().to_vec())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn builds_table_and_derefs() {
        let xml = b"<?xml version=\"1.0\" encoding=\"UTF-8\" ?><PremiereData Version=\"3\"><A ObjectID=\"1\"><X>t</X></A><B ObjectUID=\"u\"><R ObjectRef=\"1\"/></B></PremiereData>";
        let t = ObjectTable::new(xml).unwrap();
        assert_eq!(t.object_count(), 2);
        let b = t.get("u").unwrap();
        assert_eq!(t.deref(b.child("R")).unwrap().child("X").unwrap().text, "t");
    }

    #[test]
    fn reads_utf16_and_latin1_projects_through_the_fallback() {
        let xml = "<?xml version=\"1.0\" encoding=\"UTF-16\"?><PremiereData><A ObjectID=\"1\"><X>t\u{e9}</X></A></PremiereData>";
        let mut le = vec![0xFF, 0xFE];
        le.extend(xml.encode_utf16().flat_map(u16::to_le_bytes));
        let mut be = vec![0xFE, 0xFF];
        be.extend(xml.encode_utf16().flat_map(u16::to_be_bytes));
        let latin = b"<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?><PremiereData><A ObjectID=\"1\"><X>t\xe9</X></A></PremiereData>";
        for bytes in [le.as_slice(), be.as_slice(), latin.as_slice()] {
            let t = ObjectTable::new(bytes).unwrap();
            assert_eq!(t.get("1").unwrap().child("X").unwrap().text, "t\u{e9}");
        }
    }

    #[test]
    fn rejects_other_roots_and_garbage() {
        assert_eq!(ObjectTable::new(b"<Other/>").err(), Some(ImportError::NotPremiereProject));
        assert!(matches!(ObjectTable::new(b"<a><b></a>").err(), Some(ImportError::Xml(_))));
    }
}
