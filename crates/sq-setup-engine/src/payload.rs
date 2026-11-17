//! The file format of `SequenceStudio-Setup-<version>.exe`: the stub program, then the packed files, then an index and a
//! fixed trailer.
//!
//! ```text
//! [stub exe][file 1 deflate][file 2 deflate]...[index][trailer, 96 bytes]
//! index   = count u32, then per file: path length u16, path (UTF-8, '/'), raw size u64, packed size u64, offset u64
//! trailer = payload start u64, index offset u64, index length u64, sha256 (32), version text (32, NUL padded), "SQSETUP1"
//! ```
//! The hash covers everything between the stub and the trailer. All numbers are little endian. The uninstaller copy is the
//! stub alone ([`copy_stub`]), so it carries no payload.

use crate::error::{ErrorCode, SetupError};
use crate::job::Job;
use crate::version::Version;
use miniz_oxide::deflate::core::{CompressorOxide, create_comp_flags_from_zip_params};
use miniz_oxide::deflate::stream::deflate;
use miniz_oxide::inflate::stream::{InflateState, inflate};
use miniz_oxide::{DataFormat, MZError, MZFlush, MZStatus};
use sq_core_time::sha256_digest::Sha256;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Component, Path, PathBuf};

const MAGIC: &[u8; 8] = b"SQSETUP1";
const TRAILER_LEN: u64 = 96;
const VERSION_FIELD: usize = 32;
/// Chunk size of every read, deflate and inflate step: a 60 MB DLL never sits in memory whole.
const CHUNK: usize = 256 * 1024;

/// One packed file.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PayloadFile {
    /// Relative path, UTF-8, `/` separated.
    pub path: String,
    /// Size of the file as written to disk.
    pub size: u64,
    /// Size of the deflate stream inside the payload.
    pub packed: u64,
    offset: u64,
}

/// How an unpack ended.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum UnpackEnd {
    Done,
    /// The progress callback said stop; the destination was removed again.
    Canceled,
}

/// The payload of an opened setup exe.
#[derive(Clone, Debug)]
pub struct Payload {
    pub version: Version,
    pub files: Vec<PayloadFile>,
    exe: PathBuf,
    payload_start: u64,
    trailer_start: u64,
    sha256: [u8; 32],
}

fn damaged(step: &str, why: &str) -> SetupError {
    SetupError::new(ErrorCode::PayloadDamaged, step, why)
}

fn io_err(step: &str, path: &Path, e: &std::io::Error) -> SetupError {
    SetupError::from_io(&Job::Install, step, path, e)
}

/// A name from the index must stay inside the destination.
fn safe_relative(name: &str) -> Option<PathBuf> {
    if name.is_empty() || name.contains('\\') || name.contains(':') || name.starts_with('/') {
        return None;
    }
    let mut out = PathBuf::new();
    for part in name.split('/') {
        let p = Path::new(part);
        if part.is_empty()
            || !matches!(p.components().next(), Some(Component::Normal(_)))
            || p.components().count() != 1
        {
            return None;
        }
        out.push(part);
    }
    Some(out)
}

fn walk(dir: &Path, prefix: &str, out: &mut Vec<(String, PathBuf)>) -> std::io::Result<()> {
    let mut entries: Vec<_> = std::fs::read_dir(dir)?.collect::<Result<_, _>>()?;
    entries.sort_by_key(|e| e.file_name());
    for entry in entries {
        let name = entry.file_name().to_string_lossy().into_owned();
        let rel = if prefix.is_empty() { name } else { format!("{prefix}/{}", name) };
        if entry.file_type()?.is_dir() {
            walk(&entry.path(), &rel, out)?;
        } else {
            out.push((rel, entry.path()));
        }
    }
    Ok(())
}

/// Writes `stub + payload + trailer` to `out` from every file under `stage_dir` (sorted, so the same folder always gives
/// the same bytes). An empty folder is refused.
pub fn pack(stub: &[u8], stage_dir: &Path, version: &Version, out: &Path) -> Result<(), SetupError> {
    let mut entries = Vec::new();
    walk(stage_dir, "", &mut entries).map_err(|e| io_err("reading the stage folder", stage_dir, &e))?;
    entries.sort_by(|a, b| a.0.cmp(&b.0));
    pack_entries(stub, &entries, version, out)
}

fn pack_entries(stub: &[u8], entries: &[(String, PathBuf)], version: &Version, out: &Path) -> Result<(), SetupError> {
    if entries.is_empty() {
        return Err(SetupError::new(ErrorCode::Other, "packing", "the stage folder has no files"));
    }
    let version_text = version.to_string();
    if version_text.len() > VERSION_FIELD {
        return Err(SetupError::new(ErrorCode::Other, "packing", "the version text is too long"));
    }
    let write = |e: std::io::Error| io_err("writing the setup file", out, &e);
    let mut file = std::io::BufWriter::new(File::create(out).map_err(write)?);
    file.write_all(stub).map_err(write)?;
    let payload_start = stub.len() as u64;
    let mut hash = Sha256::new();
    let mut at = payload_start;
    let mut index = Vec::new();
    index.extend_from_slice(&(entries.len() as u32).to_le_bytes());
    let mut out_buf = vec![0u8; CHUNK];
    let mut in_buf = vec![0u8; CHUNK];
    for (name, path) in entries {
        let name_len = u16::try_from(name.len()).map_err(|_| damaged("packing", "a file name is too long"))?;
        let mut src = File::open(path).map_err(|e| io_err("reading a stage file", path, &e))?;
        let mut comp = CompressorOxide::new(create_comp_flags_from_zip_params(6, -15, 0));
        let (mut raw, mut packed) = (0u64, 0u64);
        loop {
            let n = src.read(&mut in_buf).map_err(|e| io_err("reading a stage file", path, &e))?;
            raw += n as u64;
            let flush = if n == 0 { MZFlush::Finish } else { MZFlush::None };
            let mut input = &in_buf[..n];
            loop {
                let r = deflate(&mut comp, input, &mut out_buf, flush);
                input = &input[r.bytes_consumed..];
                let chunk = &out_buf[..r.bytes_written];
                hash.update(chunk);
                file.write_all(chunk).map_err(write)?;
                packed += chunk.len() as u64;
                match r.status {
                    Ok(MZStatus::StreamEnd) => break,
                    // Not finishing: the input is taken once it is all consumed; else the output buffer was full.
                    Ok(_) | Err(MZError::Buf) if flush == MZFlush::None => {
                        if input.is_empty() {
                            break;
                        }
                    }
                    Ok(_) => {}
                    Err(_) => return Err(damaged("packing", "the compressor failed")),
                }
            }
            if n == 0 {
                break;
            }
        }
        index.extend_from_slice(&name_len.to_le_bytes());
        index.extend_from_slice(name.as_bytes());
        index.extend_from_slice(&raw.to_le_bytes());
        index.extend_from_slice(&packed.to_le_bytes());
        index.extend_from_slice(&at.to_le_bytes());
        at += packed;
    }
    hash.update(&index);
    file.write_all(&index).map_err(write)?;
    let mut trailer = Vec::with_capacity(TRAILER_LEN as usize);
    trailer.extend_from_slice(&payload_start.to_le_bytes());
    trailer.extend_from_slice(&at.to_le_bytes());
    trailer.extend_from_slice(&(index.len() as u64).to_le_bytes());
    trailer.extend_from_slice(&hash.finalize());
    let mut field = [0u8; VERSION_FIELD];
    field[..version_text.len()].copy_from_slice(version_text.as_bytes());
    trailer.extend_from_slice(&field);
    trailer.extend_from_slice(MAGIC);
    file.write_all(&trailer).map_err(write)?;
    file.flush().map_err(write)
}

fn u64_at(b: &[u8], at: usize) -> u64 {
    b.get(at..at + 8).and_then(|s| <[u8; 8]>::try_from(s).ok()).map_or(0, u64::from_le_bytes)
}

/// The trailer of `exe`: `None` when the file has none (no payload).
struct Trailer {
    payload_start: u64,
    index_at: u64,
    index_len: u64,
    sha256: [u8; 32],
    version: String,
    /// Where the trailer itself starts.
    start: u64,
}

fn read_trailer(file: &mut File, exe: &Path) -> Result<Option<Trailer>, SetupError> {
    let read = |e: std::io::Error| io_err("reading the setup file", exe, &e);
    let len = file.metadata().map_err(read)?.len();
    if len < TRAILER_LEN {
        return Ok(None);
    }
    file.seek(SeekFrom::Start(len - TRAILER_LEN)).map_err(read)?;
    let mut t = [0u8; TRAILER_LEN as usize];
    file.read_exact(&mut t).map_err(read)?;
    if &t[88..96] != MAGIC {
        return Ok(None);
    }
    let mut sha = [0u8; 32];
    sha.copy_from_slice(&t[24..56]);
    let text = &t[56..56 + VERSION_FIELD];
    let end = text.iter().position(|b| *b == 0).unwrap_or(VERSION_FIELD);
    let version = String::from_utf8_lossy(&text[..end]).into_owned();
    Ok(Some(Trailer {
        payload_start: u64_at(&t, 0),
        index_at: u64_at(&t, 8),
        index_len: u64_at(&t, 16),
        sha256: sha,
        version,
        start: len - TRAILER_LEN,
    }))
}

/// Opens the payload of `exe`. `Ok(None)` = the exe carries none (the uninstaller copy); a trailer whose index does not
/// fit is `SQI-101`.
pub fn open(exe: &Path) -> Result<Option<Payload>, SetupError> {
    let mut file = File::open(exe).map_err(|e| io_err("opening the setup file", exe, &e))?;
    let Some(Trailer { payload_start, index_at, index_len, sha256, version: version_text, start: trailer_start }) =
        read_trailer(&mut file, exe)?
    else {
        return Ok(None);
    };
    let bad = || damaged("reading the package index", "the package index is damaged");
    if payload_start > index_at || index_at.checked_add(index_len) != Some(trailer_start) {
        return Err(bad());
    }
    let version = Version::parse(&version_text).ok_or_else(bad)?;
    let mut index = vec![0u8; usize::try_from(index_len).map_err(|_| bad())?];
    file.seek(SeekFrom::Start(index_at)).map_err(|e| io_err("reading the package index", exe, &e))?;
    file.read_exact(&mut index).map_err(|_| bad())?;
    let count = index.get(0..4).and_then(|s| <[u8; 4]>::try_from(s).ok()).map(u32::from_le_bytes).ok_or_else(bad)?;
    let mut files = Vec::new();
    let mut at = 4usize;
    for _ in 0..count {
        let name_len =
            index.get(at..at + 2).and_then(|s| <[u8; 2]>::try_from(s).ok()).map(u16::from_le_bytes).ok_or_else(bad)?
                as usize;
        let name = index.get(at + 2..at + 2 + name_len).ok_or_else(bad)?;
        let path = String::from_utf8(name.to_vec()).map_err(|_| bad())?;
        at += 2 + name_len;
        if index.len() < at + 24 || safe_relative(&path).is_none() {
            return Err(bad());
        }
        let (size, packed, offset) = (u64_at(&index, at), u64_at(&index, at + 8), u64_at(&index, at + 16));
        at += 24;
        if offset < payload_start || offset.checked_add(packed).is_none_or(|end| end > index_at) {
            return Err(bad());
        }
        files.push(PayloadFile { path, size, packed, offset });
    }
    Ok(Some(Payload {
        version,
        files,
        exe: exe.to_path_buf(),
        payload_start,
        trailer_start: index_at + index_len,
        sha256,
    }))
}

/// Length of the program without its payload: the whole file when it has no trailer.
pub fn stub_len(exe: &Path) -> Result<u64, SetupError> {
    let mut file = File::open(exe).map_err(|e| io_err("opening the setup file", exe, &e))?;
    match read_trailer(&mut file, exe)? {
        Some(t) => Ok(t.payload_start),
        None => file.metadata().map(|m| m.len()).map_err(|e| io_err("opening the setup file", exe, &e)),
    }
}

/// Writes the program without its payload to `dest` (the uninstaller copy).
pub fn copy_stub(exe: &Path, dest: &Path) -> Result<(), SetupError> {
    let len = stub_len(exe)?;
    let mut src = File::open(exe).map_err(|e| io_err("opening the setup file", exe, &e))?;
    let mut out = File::create(dest).map_err(|e| io_err("writing the uninstaller", dest, &e))?;
    std::io::copy(&mut (&mut src).take(len), &mut out).map_err(|e| io_err("writing the uninstaller", dest, &e))?;
    Ok(())
}

impl Payload {
    /// Sum of the raw sizes: what the files take on disk.
    pub fn total_bytes(&self) -> u64 {
        self.files.iter().map(|f| f.size).sum()
    }

    /// Hashes everything between the stub and the trailer; `SQI-101` when it does not match. `progress` gets 0..1.
    pub fn verify(&self, progress: &mut dyn FnMut(f64)) -> Result<(), SetupError> {
        let mut file = File::open(&self.exe).map_err(|e| io_err("verifying the package", &self.exe, &e))?;
        file.seek(SeekFrom::Start(self.payload_start)).map_err(|e| io_err("verifying the package", &self.exe, &e))?;
        let total = self.trailer_start - self.payload_start;
        let (mut left, mut hash, mut buf) = (total, Sha256::new(), vec![0u8; CHUNK]);
        while left > 0 {
            let n = usize::try_from(left).unwrap_or(CHUNK).min(CHUNK);
            file.read_exact(&mut buf[..n]).map_err(|e| io_err("verifying the package", &self.exe, &e))?;
            hash.update(&buf[..n]);
            left -= n as u64;
            progress(if total == 0 { 1.0 } else { (total - left) as f64 / total as f64 });
        }
        if hash.finalize() == self.sha256 {
            Ok(())
        } else {
            Err(damaged("verifying the package", "the package hash does not match"))
        }
    }

    /// Streams one entry's inflated bytes into `sink`; `sink` returning false stops early (`Ok(false)`).
    fn inflate_entry(
        &self,
        file: &mut File,
        entry: &PayloadFile,
        sink: &mut dyn FnMut(&[u8]) -> Result<bool, SetupError>,
    ) -> Result<bool, SetupError> {
        let step = "unpacking";
        file.seek(SeekFrom::Start(entry.offset)).map_err(|e| io_err(step, &self.exe, &e))?;
        let mut state = InflateState::new_boxed(DataFormat::Raw);
        let (mut input, mut out) = (vec![0u8; CHUNK], vec![0u8; CHUNK]);
        let (mut have, mut used, mut left, mut written) = (0usize, 0usize, entry.packed, 0u64);
        loop {
            if used == have && left > 0 {
                let n = usize::try_from(left).unwrap_or(CHUNK).min(CHUNK);
                file.read_exact(&mut input[..n]).map_err(|e| io_err(step, &self.exe, &e))?;
                (have, used, left) = (n, 0, left - n as u64);
            }
            // Never `MZFlush::Finish`: miniz_oxide's Finish on a first call inflates straight into `out` and fails when the
            // whole file is bigger than `out`, which is exactly a file of more than CHUNK bytes that packs below CHUNK.
            let r = inflate(&mut state, &input[used..have], &mut out, MZFlush::None);
            used += r.bytes_consumed;
            written += r.bytes_written as u64;
            if r.bytes_written > 0 && !sink(&out[..r.bytes_written])? {
                return Ok(false);
            }
            // A call that neither reads nor writes with the input used up is a stream that ends early.
            match r.status {
                Ok(MZStatus::StreamEnd) => break,
                Ok(_) | Err(MZError::Buf) if r.bytes_consumed > 0 || r.bytes_written > 0 => {}
                _ => return Err(damaged(step, "a packed file is damaged")),
            }
        }
        if written != entry.size {
            return Err(damaged(step, "a packed file has the wrong size"));
        }
        Ok(true)
    }

    /// Writes every file under `dest` (created when missing). `progress` gets the raw bytes written so far and returns
    /// false to cancel. A cancel or a failure removes `dest` again when this call created it, so nothing stays behind.
    pub fn unpack_to(&self, dest: &Path, progress: &mut dyn FnMut(u64) -> bool) -> Result<UnpackEnd, SetupError> {
        let created = !dest.exists();
        let result = self.unpack_inner(dest, progress);
        if created && !matches!(result, Ok(UnpackEnd::Done)) {
            let _ = std::fs::remove_dir_all(dest);
        }
        result
    }

    fn unpack_inner(&self, dest: &Path, progress: &mut dyn FnMut(u64) -> bool) -> Result<UnpackEnd, SetupError> {
        let mut src = File::open(&self.exe).map_err(|e| io_err("unpacking", &self.exe, &e))?;
        std::fs::create_dir_all(dest).map_err(|e| io_err("creating the folder", dest, &e))?;
        let mut done = 0u64;
        for entry in &self.files {
            let rel =
                safe_relative(&entry.path).ok_or_else(|| damaged("unpacking", "a file name leaves the folder"))?;
            let target = dest.join(rel);
            if let Some(parent) = target.parent() {
                std::fs::create_dir_all(parent).map_err(|e| io_err("creating the folder", parent, &e))?;
            }
            let mut out =
                std::io::BufWriter::new(File::create(&target).map_err(|e| io_err("writing a file", &target, &e))?);
            let finished = self.inflate_entry(&mut src, entry, &mut |bytes| {
                out.write_all(bytes).map_err(|e| io_err("writing a file", &target, &e))?;
                done += bytes.len() as u64;
                Ok(progress(done))
            })?;
            out.flush().map_err(|e| io_err("writing a file", &target, &e))?;
            if !finished {
                return Ok(UnpackEnd::Canceled);
            }
        }
        Ok(UnpackEnd::Done)
    }

    /// One packed file's content (`LICENSE`), `None` when the name is not in the payload.
    pub fn read_file(&self, path: &str) -> Result<Vec<u8>, SetupError> {
        let Some(entry) = self.files.iter().find(|f| f.path == path) else {
            return Err(damaged("reading a packed file", "the file is not in the package"));
        };
        let mut src = File::open(&self.exe).map_err(|e| io_err("reading a packed file", &self.exe, &e))?;
        let mut data = Vec::with_capacity(usize::try_from(entry.size).unwrap_or(0));
        self.inflate_entry(&mut src, entry, &mut |bytes| {
            data.extend_from_slice(bytes);
            Ok(true)
        })?;
        Ok(data)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("sq-payload-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let _ = std::fs::create_dir_all(&dir);
        dir
    }

    /// A stage folder with text, a nested file and a big pseudo-random file (several chunks).
    fn stage(dir: &Path) -> PathBuf {
        let stage = dir.join("stage");
        let _ = std::fs::create_dir_all(stage.join("Fonts"));
        let _ = std::fs::write(stage.join("LICENSE"), b"GPL text ".repeat(100));
        let _ = std::fs::write(stage.join("Fonts").join("a.ttf"), b"font");
        let mut x = 12345u32;
        let big: Vec<u8> = (0..700_000)
            .map(|i| {
                x = x.wrapping_mul(1664525).wrapping_add(1013904223);
                if i % 3 == 0 { (x >> 24) as u8 } else { 7 }
            })
            .collect();
        let _ = std::fs::write(stage.join("big.dll"), big);
        stage
    }

    fn packed(dir: &Path) -> PathBuf {
        let exe = dir.join("Setup.exe");
        assert!(pack(b"STUB-PROGRAM", &stage(dir), &Version::new(0, 2, 1), &exe).is_ok());
        exe
    }

    #[test]
    fn pack_open_verify_unpack_round_trip() {
        let dir = temp("round");
        let exe = packed(&dir);
        let payload = open(&exe).ok().flatten().expect("payload");
        assert_eq!(payload.version, Version::new(0, 2, 1));
        let names: Vec<_> = payload.files.iter().map(|f| f.path.as_str()).collect();
        assert_eq!(names, ["Fonts/a.ttf", "LICENSE", "big.dll"]);
        assert_eq!(payload.total_bytes(), 4 + 900 + 700_000);
        let mut last = 0.0;
        assert!(payload.verify(&mut |f| last = f).is_ok());
        assert!((last - 1.0).abs() < 1e-9);
        let out = dir.join("out");
        let mut seen = 0;
        assert_eq!(
            payload
                .unpack_to(&out, &mut |b| {
                    seen = b;
                    true
                })
                .ok(),
            Some(UnpackEnd::Done)
        );
        assert_eq!(seen, payload.total_bytes());
        assert_eq!(std::fs::read(out.join("Fonts").join("a.ttf")).ok(), Some(b"font".to_vec()));
        assert_eq!(std::fs::read(out.join("big.dll")).ok(), std::fs::read(dir.join("stage").join("big.dll")).ok());
        assert_eq!(payload.read_file("LICENSE").ok(), Some(b"GPL text ".repeat(100)));
        assert!(payload.read_file("nope").is_err());
    }

    /// `len` deterministic bytes: `entropy_bits` of noise per byte (8 = incompressible, 0 = one long run).
    fn noise(len: usize, entropy_bits: u32, seed: u32) -> Vec<u8> {
        let mut x = seed;
        (0..len)
            .map(|_| {
                x = x.wrapping_mul(1664525).wrapping_add(1013904223);
                if entropy_bits == 0 { 7 } else { ((x >> 24) as u8) & (u8::MAX >> (8 - entropy_bits)) }
            })
            .collect()
    }

    /// Packs every `(name, bytes)` into one setup file, then unpacks it and reads every file back: all must match.
    fn round_trip(label: &str, files: &[(String, Vec<u8>)]) -> Payload {
        let dir = temp(label);
        let stage = dir.join("stage");
        for (name, bytes) in files {
            let target = stage.join(name);
            let _ = std::fs::create_dir_all(target.parent().unwrap_or(&stage));
            assert!(std::fs::write(&target, bytes).is_ok());
        }
        let exe = dir.join("Setup.exe");
        assert!(pack(b"STUB", &stage, &Version::new(0, 2, 1), &exe).is_ok());
        let payload = open(&exe).ok().flatten().expect("payload");
        assert!(payload.verify(&mut |_| {}).is_ok());
        let out = dir.join("out");
        assert_eq!(payload.unpack_to(&out, &mut |_| true).map_err(|e| e.to_string()), Ok(UnpackEnd::Done), "{label}");
        for (name, bytes) in files {
            assert!(std::fs::read(out.join(name)).is_ok_and(|b| b == *bytes), "{label}: {name} differs after unpack");
            assert!(payload.read_file(name).is_ok_and(|b| b == *bytes), "{label}: {name} differs through read_file");
        }
        payload
    }

    /// The release bug: a file of more than one chunk that packs to less than one chunk (a 300 KB DLL, a font) made
    /// miniz_oxide fail its first `Finish` call, so the whole setup was "damaged". Every size around the chunk and the
    /// packed-size boundaries, with every kind of data, must come back byte for byte.
    #[test]
    fn files_around_every_chunk_boundary_round_trip_whatever_they_pack_to() {
        let mut files = Vec::new();
        let sizes =
            [0, 1, CHUNK - 1, CHUNK, CHUNK + 1, 2 * CHUNK - 1, 2 * CHUNK, 2 * CHUNK + 1, 300_000, 420_000, 560_000];
        for (bits, kind) in [(8, "random"), (0, "run"), (3, "mild"), (6, "dense")] {
            for (i, size) in sizes.iter().enumerate() {
                files.push((format!("{kind}-{size}.bin"), noise(*size, bits, 99 + i as u32)));
            }
        }
        let payload = round_trip("boundaries", &files);
        let chunk = CHUNK as u64;
        assert!(
            payload.files.iter().any(|f| f.size > chunk && f.packed < chunk),
            "the set must contain the release case: raw above one chunk, packed below it"
        );
        assert!(payload.files.iter().any(|f| f.size > chunk && f.packed >= chunk), "and a big file that stays big");
    }

    /// The real files of the release that failed (the bundled fonts, 300-560 KB each), alone and all together.
    #[test]
    fn the_bundled_fonts_survive_a_round_trip() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../Packages/SQText/Sources/SQText/Resources/Fonts");
        let mut found = Vec::new();
        let _ = walk(&root, "", &mut found);
        let fonts: Vec<(String, Vec<u8>)> = found
            .iter()
            .filter(|(name, _)| name.ends_with(".ttf") || name.ends_with(".otf"))
            .filter_map(|(name, path)| Some((name.replace('/', "_"), std::fs::read(path).ok()?)))
            .collect();
        if fonts.is_empty() {
            return; // a source tree without the font folder (the published snapshot has no tests that need it)
        }
        for (name, bytes) in &fonts {
            round_trip("font-alone", &[(name.clone(), bytes.clone())]);
        }
        round_trip("fonts-together", &fonts);
    }

    #[test]
    fn a_stream_that_ends_early_is_sqi_101_and_not_a_hang() {
        let dir = temp("cut");
        let stage = dir.join("stage");
        let _ = std::fs::create_dir_all(&stage);
        let _ = std::fs::write(stage.join("a.bin"), noise(500_000, 8, 5));
        let exe = dir.join("Setup.exe");
        assert!(pack(b"S", &stage, &Version::new(1, 0, 0), &exe).is_ok());
        let mut bytes = std::fs::read(&exe).unwrap_or_default();
        // The index: count (4), name length (2), "a.bin" (5), then raw size, packed size, offset. Halve the packed size.
        let index_at = usize::try_from(u64_at(&bytes, bytes.len() - 96 + 8)).unwrap_or(0);
        let packed_at = index_at + 4 + 2 + 5 + 8;
        let packed = u64_at(&bytes, packed_at);
        bytes[packed_at..packed_at + 8].copy_from_slice(&(packed / 2).to_le_bytes());
        let _ = std::fs::write(&exe, bytes);
        let payload = open(&exe).ok().flatten().expect("payload");
        let err = payload.unpack_to(&dir.join("out"), &mut |_| true).expect_err("a cut stream");
        assert_eq!(err.code, ErrorCode::PayloadDamaged);
        assert_eq!(payload.read_file("a.bin").err().map(|e| e.code), Some(ErrorCode::PayloadDamaged));
    }

    #[test]
    fn packing_is_deterministic_and_an_empty_folder_is_refused() {
        let dir = temp("det");
        let (a, b) = (dir.join("a.exe"), dir.join("b.exe"));
        let st = stage(&dir);
        assert!(pack(b"S", &st, &Version::new(1, 0, 0), &a).is_ok());
        assert!(pack(b"S", &st, &Version::new(1, 0, 0), &b).is_ok());
        assert_eq!(std::fs::read(&a).ok(), std::fs::read(&b).ok());
        let empty = dir.join("empty");
        let _ = std::fs::create_dir_all(&empty);
        assert!(pack(b"S", &empty, &Version::new(1, 0, 0), &dir.join("c.exe")).is_err());
    }

    #[test]
    fn a_flipped_byte_is_sqi_101() {
        let dir = temp("flip");
        let exe = packed(&dir);
        let mut bytes = std::fs::read(&exe).unwrap_or_default();
        bytes[100] ^= 0x40;
        let _ = std::fs::write(&exe, bytes);
        let payload = open(&exe).ok().flatten().expect("payload");
        let err = payload.verify(&mut |_| {}).expect_err("hash must fail");
        assert_eq!(err.code, ErrorCode::PayloadDamaged);
    }

    #[test]
    fn a_broken_index_is_sqi_101_and_a_plain_exe_has_no_payload() {
        let dir = temp("index");
        let exe = packed(&dir);
        let mut bytes = std::fs::read(&exe).unwrap_or_default();
        let at = bytes.len() - 96 + 8;
        bytes[at] = 1;
        let _ = std::fs::write(&exe, bytes);
        assert_eq!(open(&exe).err().map(|e| e.code), Some(ErrorCode::PayloadDamaged));
        let plain = dir.join("plain.exe");
        let _ = std::fs::write(
            &plain,
            b"just a program, long enough to hold a trailer-sized tail ........................................",
        );
        assert!(matches!(open(&plain), Ok(None)));
    }

    #[test]
    fn names_that_leave_the_folder_are_refused() {
        let dir = temp("names");
        let src = dir.join("f.txt");
        let _ = std::fs::write(&src, b"x");
        for bad in ["../evil.txt", "/abs.txt", "C:/x.txt", "a/../b", "a\\b", ""] {
            let exe = dir.join("evil.exe");
            assert!(pack_entries(b"S", &[(bad.to_string(), src.clone())], &Version::new(1, 0, 0), &exe).is_ok());
            assert_eq!(open(&exe).err().map(|e| e.code), Some(ErrorCode::PayloadDamaged), "{bad}");
        }
        assert!(safe_relative("Fonts/a.ttf").is_some());
    }

    #[test]
    fn a_cancel_mid_unpack_leaves_nothing() {
        let dir = temp("cancel");
        let exe = packed(&dir);
        let payload = open(&exe).ok().flatten().expect("payload");
        let out = dir.join("out");
        assert_eq!(payload.unpack_to(&out, &mut |b| b < 5000).ok(), Some(UnpackEnd::Canceled));
        assert!(!out.exists());
    }

    #[test]
    fn the_stub_copy_has_no_payload() {
        let dir = temp("stub");
        let exe = packed(&dir);
        assert_eq!(stub_len(&exe).ok(), Some(12));
        let copy = dir.join("Uninstall.exe");
        assert!(copy_stub(&exe, &copy).is_ok());
        assert_eq!(std::fs::read(&copy).ok(), Some(b"STUB-PROGRAM".to_vec()));
        assert!(matches!(open(&copy), Ok(None)));
        assert_eq!(stub_len(&copy).ok(), Some(12));
    }
}
