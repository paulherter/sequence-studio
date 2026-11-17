// SPDX-License-Identifier: GPL-3.0-or-later
//! `dump [--limit N] <file>`: canonical, deterministic text dump of what the container layer makes of a file.
//! The Swift dumper (parity/swift-dump/main.swift) prints the identical format; parity/run.sh diffs the two.
//!
//! Format, one record per line, all strings escaped (see `esc`):
//!   SIZE <input bytes>
//!   CONTAINER zip|gzip|plain          zip = starts with "PK\x03\x04"; gzip = >= 18 bytes starting 1f 8b; else plain
//! zip:
//!   ENTRIES <count> | ERROR corruptArchive
//!   ENTRY <i> name=<esc> method=<n> csize=<n> usize=<n> local=<n> enc=<0|1>
//!   DATA <i> ok <length> <fnv1a-64 hex> | DATA <i> error corruptArchive
//!   LOOKUP "project.prgraphic" found <i> | none
//! gzip / plain:
//!   INFLATE ok <size> <fnv1a-64 hex> | INFLATE error corruptArchive      (plain: size = input size)
//!   XML nil                          the fast reader declined (the Swift code would fall back to XMLParser)
//!   XML error notPremiereProject     root element is not PremiereData
//!   XML ok objects=<unique ids> binaries=<n>
//!   BINARY <esc key> <length in bytes> <fnv1a-64 hex>     (sorted by key bytes)
//!   NODE <depth> <esc name> text=<esc> attrs=<k>=<v>,...   (depth first, attributes sorted by key bytes)
#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    reason = "test-support CLI for the parity harness: a panic is the correct failure mode and the output is checked by diff"
)]

use sq_prproj_reader::container::{ImportError, Node, ObjectTable};
use sq_prproj_reader::{inflate, zip};
use std::fmt::Write;

fn fnv(b: &[u8]) -> u64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for &c in b {
        h = (h ^ c as u64).wrapping_mul(0x100_0000_01b3);
    }
    h
}

/// Quoted; every scalar outside 0x20...0x7E, and `\` and `"`, becomes \u{hex}.
fn esc(s: &str) -> String {
    let mut o = String::with_capacity(s.len() + 2);
    o.push('"');
    for c in s.chars() {
        if (' '..='~').contains(&c) && c != '\\' && c != '"' {
            o.push(c);
        } else {
            let _ = write!(o, "\\u{{{:x}}}", c as u32);
        }
    }
    o.push('"');
    o
}

fn dump_node(out: &mut String, root: &Node) {
    let mut stack = vec![(root, 0usize)];
    while let Some((n, d)) = stack.pop() {
        let attrs: Vec<String> = n.attributes.iter().map(|(k, v)| format!("{}={}", esc(k), esc(v))).collect();
        let _ = writeln!(out, "NODE {} {} text={} attrs={}", d, esc(&n.name), esc(&n.text), attrs.join(","));
        for c in n.children.iter().rev() {
            stack.push((c, d + 1));
        }
    }
}

fn dump_xml(out: &mut String, bytes: &[u8]) {
    match ObjectTable::new(bytes) {
        Err(ImportError::NotPremiereProject) => out.push_str("XML error notPremiereProject\n"),
        Err(_) => out.push_str("XML nil\n"),
        Ok(t) => {
            let _ = writeln!(out, "XML ok objects={} binaries={}", t.object_count(), t.binaries.len());
            let mut keys: Vec<&String> = t.binaries.keys().collect();
            keys.sort_by(|a, b| a.as_bytes().cmp(b.as_bytes()));
            for k in keys {
                let v = &t.binaries[k];
                let _ = writeln!(out, "BINARY {} {} {:016x}", esc(k), v.len(), fnv(v.as_bytes()));
            }
            dump_node(out, &t.root);
        }
    }
}

pub fn dump(data: &[u8], limit: usize) -> String {
    let mut out = String::new();
    let _ = writeln!(out, "SIZE {}", data.len());
    if data.starts_with(b"PK\x03\x04") {
        out.push_str("CONTAINER zip\n");
        match zip::Zip::new(data) {
            Err(_) => out.push_str("ERROR corruptArchive\n"),
            Ok(z) => {
                let _ = writeln!(out, "ENTRIES {}", z.entries.len());
                for (i, e) in z.entries.iter().enumerate() {
                    let _ = writeln!(
                        out,
                        "ENTRY {} name={} method={} csize={} usize={} local={} enc={}",
                        i,
                        esc(&e.name),
                        e.method,
                        e.compressed_size,
                        e.uncompressed_size,
                        e.local_offset,
                        e.encrypted as u8
                    );
                    match z.data(e) {
                        Ok(d) => {
                            let _ = writeln!(out, "DATA {} ok {} {:016x}", i, d.len(), fnv(&d));
                        }
                        Err(_) => {
                            let _ = writeln!(out, "DATA {} error corruptArchive", i);
                        }
                    }
                }
                match z.entry("project.prgraphic") {
                    Some(e) => {
                        let _ = writeln!(
                            out,
                            "LOOKUP \"project.prgraphic\" found {}",
                            z.entries.iter().position(|x| x == e).unwrap()
                        );
                    }
                    None => out.push_str("LOOKUP \"project.prgraphic\" none\n"),
                }
            }
        }
        return out;
    }
    let gz = data.len() >= 18 && data[0] == 0x1f && data[1] == 0x8b;
    out.push_str(if gz { "CONTAINER gzip\n" } else { "CONTAINER plain\n" });
    match inflate::gzip_inflate(data, limit) {
        Err(_) => out.push_str("INFLATE error corruptArchive\n"),
        Ok(x) => {
            let _ = writeln!(out, "INFLATE ok {} {:016x}", x.len(), fnv(&x));
            dump_xml(&mut out, &x);
        }
    }
    out
}

fn main() {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    let mut limit = inflate::MAX_PROJECT_SIZE;
    if args.len() >= 2 && args[0] == "--limit" {
        limit = args[1].parse().expect("limit");
        args.drain(..2);
    }
    let Some(path) = args.first() else {
        eprintln!("usage: dump [--limit N] <file>");
        std::process::exit(2);
    };
    let data = std::fs::read(path).expect("read");
    // Deeply nested files: the parser is iterative, but give the thread room anyway.
    let h = std::thread::Builder::new().stack_size(256 << 20).spawn(move || dump(&data, limit)).unwrap();
    print!("{}", h.join().unwrap());
}
