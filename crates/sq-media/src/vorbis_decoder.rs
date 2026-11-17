//! Port of `SQMedia/Sources/SQMedia/WebM/VorbisDecoder.swift`.
//!
//! Vorbis I decoder (Xiph's public specification, <https://xiph.org/vorbis/doc/Vorbis_I_spec.html>), written for this project
//! from the spec text. Floor type 1 and residue types 0, 1 and 2 (everything libvorbis encoders write). One instance decodes one
//! stream, packet after packet (not thread safe). The IMDCT's DCT-IV (vDSP in Swift) is a small radix-2 FFT here.

use std::collections::HashMap;
use std::fmt;

/// Why a stream could not be set up (Swift: `VorbisDecoder.Failure`).
#[derive(Debug, Clone, PartialEq)]
pub enum Failure {
    BadHeader,
    Unsupported(String),
    BadPacket,
}

impl fmt::Display for Failure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Failure::BadHeader => write!(f, "bad Vorbis header"),
            Failure::Unsupported(what) => write!(f, "unsupported Vorbis feature: {what}"),
            Failure::BadPacket => write!(f, "bad Vorbis packet"),
        }
    }
}

impl std::error::Error for Failure {}

/// Huffman trie: node i has children child[2i], child[2i+1]; value > 0 = node index, value <= 0 = leaf -(entry).
#[derive(Default)]
struct Codebook {
    dimensions: usize,
    entries: usize,
    trie: Vec<i32>,
    /// entries * dimensions decoded vector values (lookup types 1 and 2), empty without lookup.
    vectors: Vec<f32>,
    /// The trie walked for every `fast_bits`-bit pattern (first bit read = lowest bit), see `fast_table`.
    fast_bits: usize,
    fast: Vec<u32>,
}

impl Codebook {
    fn has_lookup(&self) -> bool {
        !self.vectors.is_empty()
    }
}

// Fast-table entry: bits 0-5 = bits consumed, 6-7 = kind, 8-31 = entry (leaf) or trie node (continue).
const FAST_LEAF: u32 = 0;
const FAST_INVALID: u32 = 1;
const FAST_CONTINUE: u32 = 2;
const MAX_FAST_BITS: usize = 10;

#[derive(Default)]
struct Floor1 {
    partition_class: Vec<usize>,
    class_dimensions: Vec<usize>,
    class_subclasses: Vec<usize>,
    masterbooks: Vec<i64>,
    subclass_books: Vec<Vec<i64>>,
    multiplier: i64,
    range_bits: usize,
    x: Vec<i64>,
    sorted_order: Vec<usize>,
    low_neighbor: Vec<usize>,
    high_neighbor: Vec<usize>,
}

struct Residue {
    kind: usize,
    begin: usize,
    end: usize,
    partition_size: usize,
    classifications: usize,
    classbook: usize,
    books: Vec<[i64; 8]>,
}

#[derive(Default)]
struct Mapping {
    coupling_magnitude: Vec<usize>,
    coupling_angle: Vec<usize>,
    mux: Vec<usize>,
    submap_floor: Vec<usize>,
    submap_residue: Vec<usize>,
}

struct Mode {
    blockflag: bool,
    mapping: usize,
}

/// LSB-first bit reader. Reading past the end sets `eop`, leaves `pos` at the end and returns the bits that were there
/// (missing high bits zero), as the spec's end-of-packet rule wants.
struct Bits<'a> {
    d: &'a [u8],
    total_bits: usize,
    pos: usize,
    eop: bool,
}

impl<'a> Bits<'a> {
    fn new(d: &'a [u8]) -> Self {
        Bits { d, total_bits: d.len() * 8, pos: 0, eop: false }
    }

    /// The next `n` (<= 57) bits without consuming them; zero beyond the end.
    fn peek(&self, n: usize) -> usize {
        let byte = self.pos >> 3;
        let mut w: u64 = 0;
        for (i, b) in self.d.iter().skip(byte).take(8).enumerate() {
            w |= u64::from(*b) << (8 * i);
        }
        ((w >> (self.pos & 7)) & ((1u64 << n) - 1)) as usize
    }

    fn read(&mut self, n: usize) -> usize {
        if n == 0 {
            return 0;
        }
        let v = self.peek(n);
        if self.pos + n > self.total_bits {
            self.eop = true;
            self.pos = self.pos.max(self.total_bits);
            return v;
        }
        self.pos += n;
        v
    }

    fn bit(&mut self) -> usize {
        let byte = self.pos >> 3;
        if byte >= self.d.len() {
            self.eop = true;
            return 0;
        }
        let b = usize::from(self.d[byte] >> (self.pos & 7)) & 1;
        self.pos += 1;
        b
    }
}

fn ilog(x: usize) -> usize {
    if x == 0 { 0 } else { (usize::BITS - x.leading_zeros()) as usize }
}

/// DCT-IV of size `m` (`X[k] = sum x[j] cos(pi/m (j + 1/2)(k + 1/2))`, no scaling) through a complex FFT of size m/2.
struct Dct4 {
    m: usize,
    pre: Vec<(f64, f64)>,
    post: Vec<(f64, f64)>,
    fft_twiddle: Vec<(f64, f64)>,
}

impl Dct4 {
    fn new(m: usize) -> Self {
        let half = m / 2;
        let angle = |a: f64| (a.cos(), a.sin());
        Dct4 {
            m,
            pre: (0..half).map(|n| angle(-std::f64::consts::PI * (n as f64 + 0.25) / m as f64)).collect(),
            post: (0..half).map(|k| angle(-std::f64::consts::PI * k as f64 / m as f64)).collect(),
            fft_twiddle: (0..half / 2).map(|k| angle(-2.0 * std::f64::consts::PI * k as f64 / half as f64)).collect(),
        }
    }

    fn fft(&self, buf: &mut [(f64, f64)]) {
        let n = buf.len();
        let bits = n.trailing_zeros();
        for i in 0..n {
            let j = if bits == 0 { 0 } else { i.reverse_bits() >> (usize::BITS - bits) };
            if j > i {
                buf.swap(i, j);
            }
        }
        let mut len = 2;
        while len <= n {
            let stride = n / len;
            for start in (0..n).step_by(len) {
                for k in 0..len / 2 {
                    let (wr, wi) = self.fft_twiddle[k * stride];
                    let (ar, ai) = buf[start + k];
                    let (br, bi) = buf[start + k + len / 2];
                    let (tr, ti) = (br * wr - bi * wi, br * wi + bi * wr);
                    buf[start + k] = (ar + tr, ai + ti);
                    buf[start + k + len / 2] = (ar - tr, ai - ti);
                }
            }
            len *= 2;
        }
    }

    fn transform(&self, x: &[f32]) -> Vec<f32> {
        let m = self.m;
        let half = m / 2;
        let mut c: Vec<(f64, f64)> = (0..half)
            .map(|n| {
                let (re, im) = (f64::from(x[2 * n]), f64::from(x[m - 1 - 2 * n]));
                let (wr, wi) = self.pre[n];
                (re * wr - im * wi, re * wi + im * wr)
            })
            .collect();
        self.fft(&mut c);
        let mut out = vec![0f32; m];
        for k in 0..half {
            let (wr, wi) = self.post[k];
            let (re, im) = (c[k].0 * wr - c[k].1 * wi, c[k].0 * wi + c[k].1 * wr);
            out[2 * k] = re as f32;
            out[m - 1 - 2 * k] = (-im) as f32;
        }
        out
    }
}

/// Vorbis I decoder for one stream.
pub struct VorbisDecoder {
    channels: usize,
    sample_rate: usize,
    codebooks: Vec<Codebook>,
    floors: Vec<Floor1>,
    residues: Vec<Residue>,
    mappings: Vec<Mapping>,
    modes: Vec<Mode>,
    blocksize: [usize; 2],
    tail: Vec<Vec<f32>>,
    prev_n: usize,
    started: bool,
    windows: HashMap<usize, Vec<f32>>,
    dct: HashMap<usize, Dct4>,
}

fn floor_table() -> Vec<f32> {
    (0..256).map(|i| 10f64.powf(f64::from(i - 255) * 0.546875 / 20.0) as f32).collect()
}

impl VorbisDecoder {
    /// `codec_private` is the Matroska CodecPrivate: Xiph-laced identification, comment and setup headers.
    pub fn new(codec_private: &[u8]) -> Result<Self, Failure> {
        let b = codec_private;
        if b.len() <= 3 || b[0] != 2 {
            return Err(Failure::BadHeader);
        }
        let mut pos = 1;
        let mut sizes = [0usize; 2];
        for size in &mut sizes {
            let mut s = 0;
            while pos < b.len() {
                let x = usize::from(b[pos]);
                pos += 1;
                s += x;
                if x != 255 {
                    break;
                }
            }
            *size = s;
        }
        if pos + sizes[0] + sizes[1] >= b.len() {
            return Err(Failure::BadHeader);
        }
        let ident = &b[pos..pos + sizes[0]];
        let setup = &b[pos + sizes[0] + sizes[1]..];
        let mut d = VorbisDecoder {
            channels: 0,
            sample_rate: 0,
            codebooks: Vec::new(),
            floors: Vec::new(),
            residues: Vec::new(),
            mappings: Vec::new(),
            modes: Vec::new(),
            blocksize: [0, 0],
            tail: Vec::new(),
            prev_n: 0,
            started: false,
            windows: HashMap::new(),
            dct: HashMap::new(),
        };
        d.parse_identification(ident)?;
        d.parse_setup(setup)?;
        d.tail = vec![Vec::new(); d.channels];
        Ok(d)
    }

    /// Channel count of the stream.
    pub fn channels(&self) -> usize {
        self.channels
    }

    /// Sample rate of the stream in Hz.
    pub fn sample_rate(&self) -> usize {
        self.sample_rate
    }

    // MARK: header parsing

    fn parse_identification(&mut self, p: &[u8]) -> Result<(), Failure> {
        if p.len() < 30 || p[0] != 1 || &p[1..7] != b"vorbis" {
            return Err(Failure::BadHeader);
        }
        let u32_at = |i: usize| {
            usize::from(p[i]) | usize::from(p[i + 1]) << 8 | usize::from(p[i + 2]) << 16 | usize::from(p[i + 3]) << 24
        };
        if u32_at(7) != 0 {
            return Err(Failure::Unsupported("version".to_string()));
        }
        self.channels = usize::from(p[11]);
        self.sample_rate = u32_at(12);
        self.blocksize = [1 << (p[28] & 15), 1 << (p[28] >> 4)];
        if self.channels == 0
            || self.sample_rate == 0
            || self.blocksize[0] < 64
            || self.blocksize[1] < self.blocksize[0]
            || self.blocksize[1] > 8192
        {
            return Err(Failure::BadHeader);
        }
        Ok(())
    }

    fn float32_unpack(x: usize) -> f32 {
        let mantissa = (x & 0x1F_FFFF) as f64;
        let sign = x & 0x8000_0000 != 0;
        let exponent = ((x & 0x7FE0_0000) >> 21) as f64;
        ((if sign { -mantissa } else { mantissa }) * 2f64.powf(exponent - 788.0)) as f32
    }

    fn parse_setup(&mut self, p: &[u8]) -> Result<(), Failure> {
        if p.len() <= 7 || p[0] != 5 || &p[1..7] != b"vorbis" {
            return Err(Failure::BadHeader);
        }
        let mut r = Bits::new(&p[7..]);
        // codebooks
        let n_books = r.read(8) + 1;
        for _ in 0..n_books {
            let book = self.parse_codebook(&mut r)?;
            self.codebooks.push(book);
        }
        // time domain transforms (placeholders)
        let n_times = r.read(6) + 1;
        for _ in 0..n_times {
            if r.read(16) != 0 {
                return Err(Failure::BadHeader);
            }
        }
        // floors
        let n_floors = r.read(6) + 1;
        for _ in 0..n_floors {
            if r.read(16) != 1 {
                return Err(Failure::Unsupported("floor type 0".to_string()));
            }
            let floor = self.parse_floor1(&mut r)?;
            self.floors.push(floor);
        }
        // residues
        let n_res = r.read(6) + 1;
        for _ in 0..n_res {
            let kind = r.read(16);
            if kind > 2 {
                return Err(Failure::BadHeader);
            }
            let begin = r.read(24);
            let end = r.read(24);
            let partition_size = r.read(24) + 1;
            let classifications = r.read(6) + 1;
            let classbook = r.read(8);
            if classbook >= self.codebooks.len() {
                return Err(Failure::BadHeader);
            }
            let mut cascade = Vec::new();
            for _ in 0..classifications {
                let low = r.read(3);
                let high = if r.bit() == 1 { r.read(5) } else { 0 };
                cascade.push(high << 3 | low);
            }
            let mut books = Vec::new();
            for c in cascade {
                let mut row = [-1i64; 8];
                for (j, slot) in row.iter_mut().enumerate() {
                    if c & (1 << j) != 0 {
                        let book = r.read(8);
                        *slot = book as i64;
                        if book >= self.codebooks.len() {
                            return Err(Failure::BadHeader);
                        }
                    }
                }
                books.push(row);
            }
            self.residues.push(Residue { kind, begin, end, partition_size, classifications, classbook, books });
        }
        // mappings
        let n_maps = r.read(6) + 1;
        for _ in 0..n_maps {
            if r.read(16) != 0 {
                return Err(Failure::Unsupported("mapping type".to_string()));
            }
            let mut m = Mapping::default();
            let submaps = if r.bit() == 1 { r.read(4) + 1 } else { 1 };
            if r.bit() == 1 {
                let steps = r.read(8) + 1;
                let bits = ilog(self.channels - 1);
                for _ in 0..steps {
                    let mag = r.read(bits);
                    let ang = r.read(bits);
                    if mag == ang || mag >= self.channels || ang >= self.channels {
                        return Err(Failure::BadHeader);
                    }
                    m.coupling_magnitude.push(mag);
                    m.coupling_angle.push(ang);
                }
            }
            if r.read(2) != 0 {
                return Err(Failure::BadHeader);
            }
            if submaps > 1 {
                for _ in 0..self.channels {
                    let x = r.read(4);
                    if x >= submaps {
                        return Err(Failure::BadHeader);
                    }
                    m.mux.push(x);
                }
            } else {
                m.mux = vec![0; self.channels];
            }
            for _ in 0..submaps {
                r.read(8);
                let f = r.read(8);
                let rs = r.read(8);
                if f >= self.floors.len() || rs >= self.residues.len() {
                    return Err(Failure::BadHeader);
                }
                m.submap_floor.push(f);
                m.submap_residue.push(rs);
            }
            self.mappings.push(m);
        }
        // modes
        let n_modes = r.read(6) + 1;
        for _ in 0..n_modes {
            let blockflag = r.bit() == 1;
            if r.read(16) != 0 || r.read(16) != 0 {
                return Err(Failure::BadHeader);
            }
            let mapping = r.read(8);
            if mapping >= self.mappings.len() {
                return Err(Failure::BadHeader);
            }
            self.modes.push(Mode { blockflag, mapping });
        }
        if r.bit() != 1 || r.eop {
            return Err(Failure::BadHeader);
        }
        Ok(())
    }

    fn parse_codebook(&self, r: &mut Bits) -> Result<Codebook, Failure> {
        if r.read(24) != 0x56_4342 {
            return Err(Failure::BadHeader);
        }
        let mut cb = Codebook { dimensions: r.read(16), entries: r.read(24), ..Codebook::default() };
        if cb.dimensions == 0 || cb.entries == 0 {
            return Err(Failure::BadHeader);
        }
        let mut lengths = vec![0usize; cb.entries];
        if r.bit() == 1 {
            let mut current = r.read(5) + 1;
            let mut entry = 0;
            while entry < cb.entries {
                let n = r.read(ilog(cb.entries - entry));
                if entry + n > cb.entries || current > 32 {
                    return Err(Failure::BadHeader);
                }
                for l in &mut lengths[entry..entry + n] {
                    *l = current;
                }
                entry += n;
                current += 1;
                if r.eop {
                    return Err(Failure::BadHeader);
                }
            }
        } else {
            let sparse = r.bit() == 1;
            for l in &mut lengths {
                if sparse {
                    if r.bit() == 1 {
                        *l = r.read(5) + 1;
                    }
                } else {
                    *l = r.read(5) + 1;
                }
            }
        }
        cb.trie = Self::build_trie(&lengths)?;
        cb.fast_bits = 1.max(MAX_FAST_BITS.min(lengths.iter().copied().max().unwrap_or(1)));
        cb.fast = Self::fast_table(&cb.trie, cb.fast_bits);
        let lookup_type = r.read(4);
        if lookup_type == 1 || lookup_type == 2 {
            let minimum = Self::float32_unpack(r.read(32));
            let delta = Self::float32_unpack(r.read(32));
            let value_bits = r.read(4) + 1;
            let sequence = r.bit() == 1;
            let lookup_values = if lookup_type == 1 {
                // greatest integer v with v^dimensions <= entries
                let mut v = 0usize;
                loop {
                    let mut p = 1usize;
                    let mut ok = true;
                    for _ in 0..cb.dimensions {
                        p *= v + 1;
                        if p > cb.entries {
                            ok = false;
                            break;
                        }
                    }
                    if !ok {
                        break;
                    }
                    v += 1;
                }
                v
            } else {
                cb.entries * cb.dimensions
            };
            let mult: Vec<usize> = (0..lookup_values).map(|_| r.read(value_bits)).collect();
            let mut table = vec![0f32; cb.entries * cb.dimensions];
            for e in 0..cb.entries {
                let mut last = 0f32;
                let mut div = 1usize;
                for d in 0..cb.dimensions {
                    let m = if lookup_type == 1 {
                        let m = mult[(e / div) % lookup_values];
                        div = div.saturating_mul(lookup_values);
                        m
                    } else {
                        mult[e * cb.dimensions + d]
                    };
                    let v = m as f32 * delta + minimum + last;
                    table[e * cb.dimensions + d] = v;
                    if sequence {
                        last = v;
                    }
                }
            }
            cb.vectors = table;
        } else if lookup_type != 0 {
            return Err(Failure::BadHeader);
        }
        if r.eop {
            return Err(Failure::BadHeader);
        }
        Ok(cb)
    }

    /// Canonical Huffman code assignment of the Vorbis spec (first free codeword of the length), as a bit trie.
    fn build_trie(lengths: &[usize]) -> Result<Vec<i32>, Failure> {
        let mut trie: Vec<i32> = vec![0, 0]; // node 0 = root; children index 0 = unset
        // Spec algorithm with 32-bit left aligned "available" markers.
        let mut available = [0u32; 33];
        let Some(first) = lengths.iter().position(|&l| l > 0) else {
            return Ok(trie); // no used entries: any decode fails
        };
        fn insert(trie: &mut Vec<i32>, code: u32, length: usize, entry: usize) -> Result<(), Failure> {
            let mut node = 0usize;
            for b in 0..length {
                let bit = ((code >> (31 - b)) & 1) as usize;
                let slot = node * 2 + bit;
                if b == length - 1 {
                    if trie[slot] != 0 {
                        return Err(Failure::BadHeader);
                    }
                    trie[slot] = -(entry as i32);
                    if entry == 0 {
                        trie[slot] = i32::MIN; // leaf for entry 0 (0 and -0 collide with "unset")
                    }
                } else {
                    let mut n = trie[slot];
                    if n <= 0 {
                        if trie[slot] != 0 {
                            return Err(Failure::BadHeader);
                        }
                        n = (trie.len() / 2) as i32;
                        trie.extend_from_slice(&[0, 0]);
                        trie[slot] = n;
                    }
                    node = n as usize;
                }
            }
            Ok(())
        }
        insert(&mut trie, 0, lengths[first], first)?;
        for (l, slot) in available.iter_mut().enumerate().take(lengths[first] + 1).skip(1) {
            *slot = 1 << (32 - l);
        }
        for (i, &len) in lengths.iter().enumerate().skip(first + 1) {
            if len == 0 {
                continue;
            }
            let mut z = len;
            while z > 0 && available[z] == 0 {
                z -= 1;
            }
            if z == 0 {
                return Err(Failure::BadHeader);
            }
            let res = available[z];
            available[z] = 0;
            insert(&mut trie, res, len, i)?;
            if z != len {
                for y in (z + 1..=len).rev() {
                    available[y] = res.wrapping_add(1 << (32 - y));
                }
            }
        }
        Ok(trie)
    }

    /// For every `bits`-bit pattern: where the bit-by-bit trie walk ends (leaf, invalid code, or the node it reached after all
    /// `bits` bits) and how many bits it consumed. `scalar` then replaces up to `bits` single-bit steps by one lookup with
    /// exactly the walk's result and bit position.
    fn fast_table(trie: &[i32], k: usize) -> Vec<u32> {
        let mut table = vec![0u32; 1 << k];
        for (p, slot) in table.iter_mut().enumerate() {
            let mut node = 0usize;
            for d in 1..=k {
                let v = trie[node * 2 + ((p >> (d - 1)) & 1)];
                if v == i32::MIN {
                    *slot = FAST_LEAF << 6 | d as u32;
                    break;
                }
                if v < 0 {
                    *slot = ((-v) as u32) << 8 | FAST_LEAF << 6 | d as u32;
                    break;
                }
                if v == 0 {
                    *slot = FAST_INVALID << 6 | d as u32;
                    break;
                }
                node = v as usize;
                if d == k {
                    *slot = (node as u32) << 8 | FAST_CONTINUE << 6 | k as u32;
                }
            }
        }
        table
    }

    fn parse_floor1(&self, r: &mut Bits) -> Result<Floor1, Failure> {
        let mut f = Floor1::default();
        let partitions = r.read(5);
        for _ in 0..partitions {
            f.partition_class.push(r.read(4));
        }
        if let Some(&max_class) = f.partition_class.iter().max() {
            for _ in 0..=max_class {
                f.class_dimensions.push(r.read(3) + 1);
                let sub = r.read(2);
                f.class_subclasses.push(sub);
                f.masterbooks.push(if sub != 0 { r.read(8) as i64 } else { -1 });
                let books: Vec<i64> = (0..1usize << sub).map(|_| r.read(8) as i64 - 1).collect();
                f.subclass_books.push(books);
            }
        }
        let book_count = self.codebooks.len() as i64;
        if f.masterbooks.iter().chain(f.subclass_books.iter().flatten()).any(|&b| b >= book_count) {
            return Err(Failure::BadHeader);
        }
        f.multiplier = r.read(2) as i64 + 1;
        f.range_bits = r.read(4);
        f.x = vec![0, 1 << f.range_bits];
        for &c in &f.partition_class {
            for _ in 0..f.class_dimensions[c] {
                f.x.push(r.read(f.range_bits) as i64);
            }
        }
        if f.x.len() > 65 || r.eop {
            return Err(Failure::BadHeader);
        }
        let mut order: Vec<usize> = (0..f.x.len()).collect();
        order.sort_by_key(|&i| (f.x[i], i));
        f.sorted_order = order;
        for i in 0..f.x.len() {
            let (mut lo, mut hi, mut lo_x, mut hi_x) = (0usize, 1usize, -1i64, i64::MAX);
            if i >= 2 {
                for j in 0..i {
                    if f.x[j] < f.x[i] && f.x[j] > lo_x {
                        lo = j;
                        lo_x = f.x[j];
                    }
                    if f.x[j] > f.x[i] && f.x[j] < hi_x {
                        hi = j;
                        hi_x = f.x[j];
                    }
                }
            }
            f.low_neighbor.push(lo);
            f.high_neighbor.push(hi);
        }
        Ok(f)
    }

    // MARK: packet decoding

    /// Huffman scalar; None at end of packet.
    fn scalar(cb: &Codebook, r: &mut Bits) -> Option<usize> {
        let e = cb.fast[r.peek(cb.fast_bits)];
        let used = (e & 63) as usize;
        // The walk would have run past the end of the packet: end of packet, position at the end.
        if r.pos + used > r.total_bits {
            r.eop = true;
            r.pos = r.pos.max(r.total_bits);
            return None;
        }
        r.pos += used;
        match (e >> 6) & 3 {
            FAST_LEAF => return Some((e >> 8) as usize),
            FAST_INVALID => return None,
            _ => {}
        }
        let mut node = (e >> 8) as usize;
        loop {
            let bit = r.bit();
            if r.eop {
                return None;
            }
            let v = cb.trie[node * 2 + bit];
            if v == i32::MIN {
                return Some(0);
            }
            if v < 0 {
                return Some((-v) as usize);
            }
            if v == 0 {
                return None;
            }
            node = v as usize;
        }
    }

    fn ensure_window(&mut self, n: usize, prev: bool, next: bool) -> usize {
        let key = n << 2 | if prev { 2 } else { 0 } | usize::from(next);
        if self.windows.contains_key(&key) {
            return key;
        }
        let long = n == self.blocksize[1];
        let bs0 = self.blocksize[0];
        let (left_start, left_end, left_n) =
            if long && !prev { (n / 4 - bs0 / 4, n / 4 + bs0 / 4, bs0 / 2) } else { (0, n / 2, n / 2) };
        let (right_start, right_end, right_n) =
            if long && !next { (n * 3 / 4 - bs0 / 4, n * 3 / 4 + bs0 / 4, bs0 / 2) } else { (n / 2, n, n / 2) };
        use std::f64::consts::PI;
        let mut w = vec![0f32; n];
        for (i, slot) in w.iter_mut().enumerate() {
            *slot = if i < left_start {
                0.0
            } else if i < left_end {
                let s = (PI * ((i - left_start) as f64 + 0.5) / (2 * left_n) as f64).sin();
                (PI / 2.0 * s * s).sin() as f32
            } else if i < right_start {
                1.0
            } else if i < right_end {
                let s = (PI / 2.0 + PI * ((i - right_start) as f64 + 0.5) / (2 * right_n) as f64).sin();
                (PI / 2.0 * s * s).sin() as f32
            } else {
                0.0
            };
        }
        self.windows.insert(key, w);
        key
    }

    /// Decodes one audio packet. Returns `channels` arrays of equal length (empty for the stream's first packet and for
    /// malformed packets).
    pub fn decode(&mut self, packet: &[u8]) -> Vec<Vec<f32>> {
        let empty = |channels: usize| vec![Vec::new(); channels];
        let mut r = Bits::new(packet);
        if r.bit() != 0 {
            return empty(self.channels);
        }
        let mode = r.read(ilog(self.modes.len() - 1));
        if mode >= self.modes.len() || r.eop {
            return empty(self.channels);
        }
        let blockflag = self.modes[mode].blockflag;
        let n = self.blocksize[usize::from(blockflag)];
        let (mut prev_flag, mut next_flag) = (true, true);
        if blockflag {
            prev_flag = r.bit() == 1;
            next_flag = r.bit() == 1;
        }
        let half = n / 2;
        let channels = self.channels;
        let map = &self.mappings[self.modes[mode].mapping];

        // floors
        let mut floor_curves: Vec<Option<Vec<f32>>> = Vec::with_capacity(channels);
        for ch in 0..channels {
            let fl = &self.floors[map.submap_floor[map.mux[ch]]];
            floor_curves.push(self.decode_floor(fl, &mut r, half));
        }
        let mut no_residue: Vec<bool> = floor_curves.iter().map(Option::is_none).collect();
        // coupling: a pair is decoded when either half is
        for (&m, &a) in map.coupling_magnitude.iter().zip(&map.coupling_angle) {
            if !(no_residue[m] && no_residue[a]) {
                no_residue[m] = false;
                no_residue[a] = false;
            }
        }
        // residue (one flat buffer, channel ch at ch * half)
        let mut spectrum = vec![0f32; half * channels];
        for (s, &res_index) in map.submap_residue.iter().enumerate() {
            let chans: Vec<usize> = (0..channels).filter(|&c| map.mux[c] == s).collect();
            if chans.is_empty() {
                continue;
            }
            let res = &self.residues[res_index];
            let skip: Vec<bool> = chans.iter().map(|&c| no_residue[c]).collect();
            let nc = chans.len();
            if res.kind == 2 {
                if !skip.contains(&false) {
                    continue;
                }
                let mut interleaved = vec![0f32; half * nc];
                self.decode_residue(res, &mut r, &mut interleaved, 1, half * nc, &[false]);
                for (k, &ch) in chans.iter().enumerate() {
                    for i in 0..half {
                        spectrum[ch * half + i] = interleaved[i * nc + k];
                    }
                }
            } else if nc == 1 {
                let dst = &mut spectrum[chans[0] * half..(chans[0] + 1) * half];
                self.decode_residue(res, &mut r, dst, 1, half, &skip);
            } else {
                let mut flat = vec![0f32; half * nc];
                self.decode_residue(res, &mut r, &mut flat, nc, half, &skip);
                for (k, &ch) in chans.iter().enumerate() {
                    spectrum[ch * half..(ch + 1) * half].copy_from_slice(&flat[k * half..(k + 1) * half]);
                }
            }
        }
        // inverse coupling, last step first
        for step in (0..map.coupling_magnitude.len()).rev() {
            let (mp, ap) = (map.coupling_magnitude[step] * half, map.coupling_angle[step] * half);
            for j in 0..half {
                let (mm, aa) = (spectrum[mp + j], spectrum[ap + j]);
                let (new_m, new_a);
                if mm > 0.0 {
                    if aa > 0.0 {
                        new_m = mm;
                        new_a = mm - aa;
                    } else {
                        new_a = mm;
                        new_m = mm + aa;
                    }
                } else if aa > 0.0 {
                    new_m = mm;
                    new_a = mm + aa;
                } else {
                    new_a = mm;
                    new_m = mm - aa;
                }
                spectrum[mp + j] = new_m;
                spectrum[ap + j] = new_a;
            }
        }
        // floor * residue, IMDCT, window
        let wkey = self.ensure_window(n, prev_flag, next_flag);
        let mut block: Vec<Vec<f32>> = vec![Vec::new(); channels];
        for ch in 0..channels {
            let Some(curve) = &floor_curves[ch] else {
                block[ch] = vec![0f32; n];
                continue;
            };
            let spec: Vec<f32> = (0..half).map(|i| spectrum[ch * half + i] * curve[i]).collect();
            let mut y = self.imdct(&spec, n);
            for (v, w) in y.iter_mut().zip(&self.windows[&wkey]) {
                *v *= w;
            }
            block[ch] = y;
        }
        // overlap-add
        if !self.started {
            self.started = true;
            self.prev_n = n;
            for (tail, blk) in self.tail.iter_mut().zip(&block) {
                *tail = blk[half..].to_vec();
            }
            return empty(channels);
        }
        let out_len = self.prev_n / 4 + n / 4;
        let shift = (n / 4) as i64 - (self.prev_n / 4) as i64;
        let mut out = Vec::with_capacity(channels);
        for (tail, bl) in self.tail.iter_mut().zip(&block) {
            let o: Vec<f32> = (0..out_len)
                .map(|t| {
                    let mut v = tail.get(t).copied().unwrap_or(0.0);
                    let k = t as i64 + shift;
                    if k >= 0 && (k as usize) < n {
                        v += bl[k as usize];
                    }
                    v
                })
                .collect();
            out.push(o);
            *tail = bl[half..].to_vec();
        }
        self.prev_n = n;
        out
    }

    /// Window size of an audio packet (None for header or malformed packets). Used to count a stream's samples without decoding.
    pub fn block_size_of(&self, packet: &[u8]) -> Option<usize> {
        let mut r = Bits::new(&packet[..packet.len().min(8)]);
        if r.bit() != 0 {
            return None;
        }
        let mode = r.read(ilog(self.modes.len() - 1));
        if mode >= self.modes.len() || r.eop {
            return None;
        }
        Some(self.blocksize[usize::from(self.modes[mode].blockflag)])
    }

    /// Forget overlap state (after a seek): the next packet is treated as the first.
    pub fn reset(&mut self) {
        self.started = false;
        self.prev_n = 0;
        for t in &mut self.tail {
            t.clear();
        }
    }

    fn decode_floor(&self, f: &Floor1, r: &mut Bits, half: usize) -> Option<Vec<f32>> {
        if r.bit() != 1 {
            return None;
        }
        let range = [256i64, 128, 86, 64][(f.multiplier - 1) as usize];
        let mut y = vec![0i64; f.x.len()];
        let y_bits = ilog((range - 1) as usize);
        y[0] = r.read(y_bits) as i64;
        y[1] = r.read(y_bits) as i64;
        let mut offset = 2;
        for &cls in &f.partition_class {
            let cdim = f.class_dimensions[cls];
            let cbits = f.class_subclasses[cls];
            let csub = (1usize << cbits) - 1;
            let mut cval = 0usize;
            if cbits > 0 {
                cval = Self::scalar(&self.codebooks[f.masterbooks[cls] as usize], r)?;
            }
            for _ in 0..cdim {
                let book = f.subclass_books[cls][cval & csub];
                cval >>= cbits;
                if book >= 0 {
                    y[offset] = Self::scalar(&self.codebooks[book as usize], r)? as i64;
                } else {
                    y[offset] = 0;
                }
                offset += 1;
            }
        }
        if r.eop {
            return None;
        }
        // amplitude value synthesis (spec 7.2.4)
        let mut final_y = y.clone();
        let mut step2 = vec![false; y.len()];
        step2[0] = true;
        step2[1] = true;
        for i in 2..y.len() {
            let (lo, hi) = (f.low_neighbor[i], f.high_neighbor[i]);
            let predicted = Self::render_point(f.x[lo], final_y[lo], f.x[hi], final_y[hi], f.x[i]);
            let val = y[i];
            let highroom = range - predicted;
            let lowroom = predicted;
            let room = if highroom < lowroom { highroom * 2 } else { lowroom * 2 };
            if val != 0 {
                step2[lo] = true;
                step2[hi] = true;
                step2[i] = true;
                if val >= room {
                    final_y[i] =
                        if highroom > lowroom { val - lowroom + predicted } else { predicted - val + highroom - 1 };
                } else {
                    final_y[i] = if val % 2 == 1 { predicted - (val + 1) / 2 } else { predicted + val / 2 };
                }
            } else {
                step2[i] = false;
                final_y[i] = predicted;
            }
        }
        // curve synthesis (spec 7.2.4 step 2)
        let mut curve = vec![0f32; half];
        let table = floor_table();
        let order = &f.sorted_order;
        let (mut lx, mut ly) = (0i64, final_y[order[0]] * f.multiplier);
        let (mut hx, mut hy) = (0i64, ly);
        for &idx in &order[1..] {
            if !step2[idx] {
                continue;
            }
            hy = final_y[idx] * f.multiplier;
            hx = f.x[idx];
            Self::render_line(lx, ly, hx, hy, &mut curve, half, &table);
            lx = hx;
            ly = hy;
        }
        if hx < half as i64 {
            Self::render_line(hx, hy, half as i64, hy, &mut curve, half, &table);
        }
        Some(curve)
    }

    fn render_point(x0: i64, y0: i64, x1: i64, y1: i64, x: i64) -> i64 {
        let dy = y1 - y0;
        let adx = x1 - x0;
        let ady = dy.abs();
        let err = ady * (x - x0);
        let off = err / adx;
        if dy < 0 { y0 - off } else { y0 + off }
    }

    /// Bresenham-style line of the spec (7.2.4 render_line), writing `floor[x]` through the inverse dB table.
    fn render_line(x0: i64, y0: i64, x1: i64, y1: i64, out: &mut [f32], limit: usize, table: &[f32]) {
        let dy = y1 - y0;
        let adx = x1 - x0;
        if adx <= 0 {
            return;
        }
        let ady = dy.abs();
        let base = dy / adx;
        let (mut x, mut y, mut err) = (x0, y0, 0i64);
        let sy = if dy < 0 { base - 1 } else { base + 1 };
        let ady2 = ady - base.abs() * adx;
        let limit = limit as i64;
        let at = |y: i64| table[y.clamp(0, 255) as usize];
        if x < limit {
            out[x as usize] = at(y);
        }
        x += 1;
        let end = x1.min(limit); // points at or beyond `limit` are not written
        while x < end {
            err += ady2;
            if err >= adx {
                err -= adx;
                y += sy;
            } else {
                y += base;
            }
            out[x as usize] = at(y);
            x += 1;
        }
    }

    /// `vectors`: `count` vectors of `length` floats, back to back.
    fn decode_residue(
        &self,
        res: &Residue,
        r: &mut Bits,
        vectors: &mut [f32],
        count: usize,
        length: usize,
        skip: &[bool],
    ) {
        let limit_begin = res.begin.min(length);
        let limit_end = res.end.min(length);
        if limit_end <= limit_begin {
            return;
        }
        let to_read = limit_end - limit_begin;
        let partitions = to_read / res.partition_size;
        if partitions == 0 {
            return;
        }
        let classbook = &self.codebooks[res.classbook];
        let class_words = classbook.dimensions;
        let row_length = partitions + class_words;
        let mut classes = vec![0usize; row_length * count]; // row j = vector j's partition classes
        let partition_size = res.partition_size;
        for pass in 0..8 {
            let mut p = 0;
            while p < partitions {
                if pass == 0 {
                    for j in (0..count).filter(|&j| !skip[j]) {
                        let Some(mut temp) = Self::scalar(classbook, r) else { return };
                        for i in (0..class_words).rev() {
                            classes[j * row_length + i + p] = temp % res.classifications;
                            temp /= res.classifications;
                        }
                    }
                }
                let mut i = 0;
                while i < class_words && p < partitions {
                    for j in (0..count).filter(|&j| !skip[j]) {
                        let book = res.books[classes[j * row_length + p]][pass];
                        if book < 0 {
                            continue;
                        }
                        let cb = &self.codebooks[book as usize];
                        if !cb.has_lookup() {
                            continue;
                        }
                        let dst = &mut vectors[j * length + limit_begin + p * partition_size..];
                        let dim = cb.dimensions;
                        if res.kind == 0 {
                            let step = partition_size / dim;
                            for s in 0..step {
                                let Some(e) = Self::scalar(cb, r) else { return };
                                let v = &cb.vectors[e * dim..];
                                for k in 0..dim {
                                    dst[s + k * step] += v[k];
                                }
                            }
                        } else {
                            let mut s = 0;
                            while s < partition_size {
                                let Some(e) = Self::scalar(cb, r) else { return };
                                let v = &cb.vectors[e * dim..];
                                for k in 0..dim.min(partition_size - s) {
                                    dst[s + k] += v[k];
                                }
                                s += dim;
                            }
                        }
                    }
                    p += 1;
                    i += 1;
                }
            }
        }
    }

    // MARK: IMDCT

    /// y[k] = sum_j X[j] cos(pi/M (k + 1/2 + M/2)(j + 1/2)), M = n/2, via a DCT-IV.
    fn imdct(&mut self, x: &[f32], n: usize) -> Vec<f32> {
        let m = n / 2;
        let z = self.dct.entry(m).or_insert_with(|| Dct4::new(m)).transform(x);
        let mut y = vec![0f32; n];
        let h = m / 2;
        y[..h].copy_from_slice(&z[h..2 * h]);
        for k in h..3 * h {
            y[k] = -z[3 * h - 1 - k];
        }
        for k in 3 * h..n {
            y[k] = -z[k - 3 * h];
        }
        y
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Reference O(n^2) transform.
    fn imdct_direct(x: &[f32], n: usize) -> Vec<f32> {
        let m = n / 2;
        (0..n)
            .map(|k| {
                let mut s = 0.0f64;
                for (j, xj) in x.iter().enumerate().take(m) {
                    s += f64::from(*xj)
                        * (std::f64::consts::PI / m as f64 * (k as f64 + 0.5 + m as f64 / 2.0) * (j as f64 + 0.5))
                            .cos();
                }
                s as f32
            })
            .collect()
    }

    fn unhex(s: &str) -> Vec<u8> {
        (0..s.len() / 2).map(|i| u8::from_str_radix(&s[2 * i..2 * i + 2], 16).unwrap_or(0)).collect()
    }

    #[test]
    fn imdct_matches_direct_formula() {
        let mut d = VorbisDecoder::new(&setup_from_golden().0).unwrap_or_else(|e| panic!("{e}"));
        for n in [64usize, 256, 1024] {
            let spec: Vec<f32> = (0..n / 2).map(|i| (i as f64 * 0.7).sin() as f32).collect();
            let a = imdct_direct(&spec, n);
            let b = d.imdct(&spec, n);
            assert_eq!(b.len(), n);
            let worst = a.iter().zip(&b).map(|(x, y)| (x - y).abs()).fold(0f32, f32::max);
            assert!(worst < 1e-3, "n={n} worst={worst}");
        }
    }

    fn setup_from_golden() -> (Vec<u8>, Vec<String>) {
        let text =
            std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/../../oracle/sq-media/golden/vorbis.tsv"))
                .unwrap_or_default();
        let setup = text.lines().find_map(|l| l.strip_prefix("setup\t")).map(unhex).unwrap_or_default();
        (setup, text.lines().map(str::to_string).collect())
    }

    #[test]
    fn header_errors() {
        assert_eq!(VorbisDecoder::new(&[]).err(), Some(Failure::BadHeader));
        assert_eq!(VorbisDecoder::new(&[1, 2, 3, 4, 5]).err(), Some(Failure::BadHeader));
        let (setup, _) = setup_from_golden();
        let mut broken = setup.clone();
        broken[5] = 3; // identification header type
        assert_eq!(VorbisDecoder::new(&broken).err(), Some(Failure::BadHeader));
        assert!(VorbisDecoder::new(&setup[..setup.len() - 5]).is_err());
    }

    #[test]
    fn ilog_and_bits() {
        assert_eq!([ilog(0), ilog(1), ilog(2), ilog(7), ilog(8)], [0, 1, 2, 3, 4]);
        let mut r = Bits::new(&[0b1010_0101, 0xFF]);
        assert_eq!(r.read(3), 0b101);
        assert_eq!(r.read(8), 0b1111_0100);
        assert!(!r.eop);
        assert_eq!(r.read(16), 0b0000_0001_1111);
        assert!(r.eop);
        assert_eq!(r.pos, 16);
    }

    /// The Swift decoder (`oracle/sq-media/run.sh`) and this one decode the same synthetic stream to the same samples.
    #[test]
    fn decodes_like_the_swift_decoder() {
        let (setup, lines) = setup_from_golden();
        assert!(!setup.is_empty(), "golden missing");
        let mut d = VorbisDecoder::new(&setup).unwrap_or_else(|e| panic!("{e}"));
        let info: Vec<&str> =
            lines.iter().find(|l| l.starts_with("info\t")).map(|l| l.split('\t').collect()).unwrap_or_default();
        assert_eq!((d.channels().to_string(), d.sample_rate().to_string()), (info[1].to_string(), info[2].to_string()));
        let (mut packet, mut decoded) = (Vec::new(), Vec::new());
        let mut checked = 0;
        for line in &lines {
            let cols: Vec<&str> = line.split('\t').collect();
            match cols[0] {
                "packet" => {
                    packet = unhex(cols[1]);
                    decoded = d.decode(&packet);
                }
                "blocksize" => {
                    assert_eq!(d.block_size_of(&packet).map(|n| n.to_string()).unwrap_or("nil".into()), cols[1])
                }
                "out" => {
                    let ch: usize = cols[1].parse().unwrap_or(usize::MAX);
                    assert_eq!(decoded[ch].len().to_string(), cols[2]);
                    let want: Vec<f32> = cols[3].split(' ').filter_map(|v| v.parse().ok()).collect();
                    for (k, w) in want.iter().enumerate() {
                        let got = decoded[ch][k * 5];
                        assert!((got - w).abs() <= 1e-5 + 1e-4 * w.abs(), "ch {ch} sample {}: {got} vs {w}", k * 5);
                        checked += 1;
                    }
                }
                _ => {}
            }
        }
        assert!(checked > 1000, "only {checked} samples compared");
    }

    #[test]
    fn reset_makes_the_next_packet_a_first_packet() {
        let (setup, lines) = setup_from_golden();
        let mut d = VorbisDecoder::new(&setup).unwrap_or_else(|e| panic!("{e}"));
        let packets: Vec<Vec<u8>> = lines.iter().filter_map(|l| l.strip_prefix("packet\t")).map(unhex).collect();
        assert!(d.decode(&packets[0]).iter().all(Vec::is_empty));
        assert!(!d.decode(&packets[1])[0].is_empty());
        d.reset();
        assert!(d.decode(&packets[1]).iter().all(Vec::is_empty));
        assert!(d.decode(&[1, 2, 3]).iter().all(Vec::is_empty)); // audio flag bit set: header packet
    }
}
