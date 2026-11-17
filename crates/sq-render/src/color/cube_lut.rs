// Swift: CubeLUT.swift, CubeLUT+3DL.swift, CubeLUT+VLT.swift
//! Adobe `.cube` LUTs (1D or 3D), plus Autodesk `.3dl` and Panasonic `.vlt` readers that produce the same table.
//! Red varies fastest in `table`.

use std::fmt;

use serde::{Deserialize, Serialize};

use super::vec::Vec3;

/// Why a LUT file was rejected.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CubeLutError {
    /// No `LUT_1D_SIZE` / `LUT_3D_SIZE` keyword.
    MissingSize,
    /// The size is outside 2...256 (3D) or 2...65536 (1D).
    SizeOutOfRange {
        /// 1-based line (0 = no line).
        line: usize,
        /// The size read.
        size: i64,
    },
    /// The table has the wrong number of rows.
    WrongEntryCount {
        /// Rows the size asks for.
        expected: usize,
        /// Rows found.
        found: usize,
    },
    /// A token is not a finite number.
    BadNumber {
        /// 1-based line.
        line: usize,
        /// The token.
        token: String,
    },
    /// A line has the wrong number of fields.
    MalformedLine {
        /// 1-based line.
        line: usize,
    },
    /// An upper-case keyword that is not known.
    UnknownKeyword {
        /// 1-based line.
        line: usize,
        /// The keyword.
        keyword: String,
    },
    /// Both a 1D and a 3D size.
    ConflictingSizes {
        /// 1-based line.
        line: usize,
    },
    /// The domain max is not above the domain min on every channel.
    InvalidDomain {
        /// 1-based line of the last domain keyword.
        line: usize,
    },
    /// Not a Swift case: `CubeLut::new` got a size below 2 or a table of the wrong length (a trap in Swift).
    InvalidTable {
        /// Size given.
        size: usize,
        /// Table length given.
        entries: usize,
    },
}

impl fmt::Display for CubeLutError {
    /// A sentence for the status bar: what is wrong with the file and where.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            CubeLutError::MissingSize => write!(f, "it has no LUT_1D_SIZE or LUT_3D_SIZE line"),
            CubeLutError::SizeOutOfRange { line: 0, size } => write!(f, "the LUT size {size} is out of range"),
            CubeLutError::SizeOutOfRange { line, size } => {
                write!(f, "line {line}: the LUT size {size} is out of range")
            }
            CubeLutError::WrongEntryCount { expected, found } => {
                write!(f, "it has {found} table rows, but its size asks for {expected}")
            }
            CubeLutError::BadNumber { line, token } => write!(f, "line {line}: \"{token}\" is not a number"),
            CubeLutError::MalformedLine { line } => write!(f, "line {line} is not a valid LUT line"),
            CubeLutError::UnknownKeyword { line, keyword } => write!(f, "line {line}: unknown keyword {keyword}"),
            CubeLutError::ConflictingSizes { line } => write!(f, "line {line}: it has both a 1D and a 3D size"),
            CubeLutError::InvalidDomain { line } => {
                write!(f, "line {line}: the domain max is not above the domain min")
            }
            CubeLutError::InvalidTable { size, entries } => {
                write!(f, "a table of {entries} rows does not fit the size {size}")
            }
        }
    }
}

impl std::error::Error for CubeLutError {}

/// 1D or 3D table.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CubeKind {
    /// One curve per channel.
    Lut1D,
    /// Cube.
    Lut3D,
}

/// How a 3D table is read between its points. Tetrahedral is the default (less banding); trilinear matches other tools.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum LutInterpolation {
    /// Tetrahedral.
    #[default]
    Tetrahedral,
    /// Trilinear.
    Trilinear,
}

/// A parsed LUT.
#[derive(Clone, Debug, PartialEq)]
pub struct CubeLut {
    /// TITLE line.
    pub title: String,
    /// 1D or 3D.
    pub kind: CubeKind,
    /// Points per axis (1D: table length).
    pub size: usize,
    /// Input domain minimum.
    pub domain_min: Vec3,
    /// Input domain maximum.
    pub domain_max: Vec3,
    /// Entries, red fastest.
    pub table: Vec<Vec3>,
    /// `LUT_IN_VIDEO_RANGE` header flag (applied in `lookup`).
    pub in_video_range: bool,
    /// `LUT_OUT_VIDEO_RANGE` header flag (applied in `lookup`).
    pub out_video_range: bool,
    /// How a 3D table is read (not part of the file: the user picks it).
    pub interpolation: LutInterpolation,
}

fn is_newline(c: char) -> bool {
    matches!(c, '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}')
}

/// Lines like Swift `split(omittingEmptySubsequences: false, whereSeparator: isNewline)`: CR LF is one separator.
fn split_lines(text: &str) -> Vec<&str> {
    let mut out = Vec::new();
    let mut start = 0;
    let mut it = text.char_indices().peekable();
    while let Some((i, c)) = it.next() {
        if is_newline(c) {
            out.push(&text[start..i]);
            start = i + c.len_utf8();
            if c == '\r'
                && let Some(&(j, '\n')) = it.peek()
            {
                it.next();
                start = j + 1;
            }
        }
    }
    out.push(&text[start..]);
    out
}

fn trim_ws(s: &str) -> &str {
    s.trim_matches(|c: char| c == ' ' || c == '\t' || (c.is_whitespace() && !is_newline(c)))
}

fn fields(line: &str, extra_comma: bool) -> Vec<&str> {
    line.split(|c| c == ' ' || c == '\t' || (extra_comma && c == ',')).filter(|s| !s.is_empty()).collect()
}

fn strip_bom(text: &str) -> &str {
    text.strip_prefix('\u{FEFF}').unwrap_or(text)
}

/// Removes `#...` to the end of the line; a `#` inside a double-quoted string (TITLE) is kept.
fn strip_comment(line: &str) -> &str {
    let mut in_quote = false;
    for (i, ch) in line.char_indices() {
        if ch == '"' {
            in_quote = !in_quote;
        } else if ch == '#' && !in_quote {
            return &line[..i];
        }
    }
    line
}

fn number(t: &str, line: usize) -> Result<f32, CubeLutError> {
    match t.parse::<f32>() {
        Ok(f) if f.is_finite() => Ok(f),
        _ => Err(CubeLutError::BadNumber { line, token: t.to_string() }),
    }
}

fn triple(parts: &[&str], line: usize) -> Result<Vec3, CubeLutError> {
    if parts.len() != 3 {
        return Err(CubeLutError::MalformedLine { line });
    }
    Ok(Vec3::new(number(parts[0], line)?, number(parts[1], line)?, number(parts[2], line)?))
}

impl CubeLut {
    /// Builds a LUT; the table length must be `size` (1D) or `size^3` (3D) and `size` at least 2.
    pub fn new(
        title: &str,
        kind: CubeKind,
        size: usize,
        domain: (Vec3, Vec3),
        table: Vec<Vec3>,
        video_range: (bool, bool),
    ) -> Result<CubeLut, CubeLutError> {
        let expected = if kind == CubeKind::Lut3D { size * size * size } else { size };
        if size < 2 || table.len() != expected {
            return Err(CubeLutError::InvalidTable { size, entries: table.len() });
        }
        Ok(CubeLut {
            title: title.to_string(),
            kind,
            size,
            domain_min: domain.0,
            domain_max: domain.1,
            table,
            in_video_range: video_range.0,
            out_video_range: video_range.1,
            interpolation: LutInterpolation::Tetrahedral,
        })
    }

    /// A copy read with the given interpolation.
    pub fn with_interpolation(&self, interpolation: LutInterpolation) -> CubeLut {
        CubeLut { interpolation, ..self.clone() }
    }

    fn plain(size: usize, table: Vec<Vec3>) -> Result<CubeLut, CubeLutError> {
        CubeLut::new("", CubeKind::Lut3D, size, (Vec3::ZERO, Vec3::ONE), table, (false, false))
    }

    /// `.cube` text; text without a `LUT_1D_SIZE` / `LUT_3D_SIZE` keyword is tried as Autodesk `.3dl` first.
    pub fn parse(text: &str) -> Result<CubeLut, CubeLutError> {
        let head: String = text.chars().take(200).collect::<String>().to_lowercase();
        if head.contains("panasonic vlt")
            && let Ok(l) = Self::parse_vlt(text)
        {
            return Ok(l);
        }
        if !text.contains("LUT_3D_SIZE")
            && !text.contains("LUT_1D_SIZE")
            && let Ok(l) = Self::parse_3dl(text)
        {
            return Ok(l);
        }
        let mut title = String::new();
        let (mut size1d, mut size3d): (Option<i64>, Option<i64>) = (None, None);
        let (mut dmin, mut dmax) = (Vec3::ZERO, Vec3::ONE);
        let mut table: Vec<Vec3> = Vec::new();
        let (mut in_video, mut out_video) = (false, false);
        let mut domain_line = 0;
        for (i, raw) in split_lines(strip_bom(text)).into_iter().enumerate() {
            let n = i + 1;
            let line = trim_ws(strip_comment(raw));
            if line.is_empty() {
                continue;
            }
            let parts = fields(line, false);
            let key = parts[0];
            match key {
                "TITLE" => {
                    title = trim_ws(line.get(5..).unwrap_or("")).to_string();
                    if title.chars().count() >= 2 && title.starts_with('"') && title.ends_with('"') {
                        title = title[1..title.len() - 1].to_string();
                    }
                }
                "LUT_3D_SIZE" | "LUT_1D_SIZE" => {
                    if parts.len() != 2 {
                        return Err(CubeLutError::MalformedLine { line: n });
                    }
                    let Ok(s) = parts[1].parse::<i64>() else {
                        return Err(CubeLutError::BadNumber { line: n, token: parts[1].to_string() });
                    };
                    let is3d = key == "LUT_3D_SIZE";
                    if size1d.is_some() && is3d
                        || size3d.is_some() && !is3d
                        || (if is3d { size3d } else { size1d }).is_some()
                    {
                        return Err(CubeLutError::ConflictingSizes { line: n });
                    }
                    let ok = if is3d { (2..=256).contains(&s) } else { (2..=65536).contains(&s) };
                    if !ok {
                        return Err(CubeLutError::SizeOutOfRange { line: n, size: s });
                    }
                    if is3d {
                        size3d = Some(s);
                    } else {
                        size1d = Some(s);
                    }
                }
                "DOMAIN_MIN" => {
                    dmin = triple(&parts[1..], n)?;
                    domain_line = n;
                }
                "DOMAIN_MAX" => {
                    dmax = triple(&parts[1..], n)?;
                    domain_line = n;
                }
                "LUT_1D_INPUT_RANGE" | "LUT_3D_INPUT_RANGE" => {
                    if parts.len() != 3 {
                        return Err(CubeLutError::MalformedLine { line: n });
                    }
                    let (lo, hi) = (number(parts[1], n)?, number(parts[2], n)?);
                    dmin = Vec3::splat(lo);
                    dmax = Vec3::splat(hi);
                    domain_line = n;
                }
                "LUT_IN_VIDEO_RANGE" => in_video = true,
                "LUT_OUT_VIDEO_RANGE" => out_video = true,
                _ => {
                    let is_keyword = key.chars().next().is_some_and(char::is_uppercase)
                        && key.chars().all(|c| (c.is_ascii() && c.is_uppercase()) || c == '_' || c.is_numeric());
                    if is_keyword {
                        return Err(CubeLutError::UnknownKeyword { line: n, keyword: key.to_string() });
                    }
                    table.push(triple(&parts, n)?);
                }
            }
        }
        if !(dmax.x > dmin.x && dmax.y > dmin.y && dmax.z > dmin.z) {
            return Err(CubeLutError::InvalidDomain { line: domain_line });
        }
        let (kind, size) = match (size3d, size1d) {
            (Some(s), _) => (CubeKind::Lut3D, s as usize),
            (None, Some(s)) => (CubeKind::Lut1D, s as usize),
            _ => return Err(CubeLutError::MissingSize),
        };
        let expected = if kind == CubeKind::Lut3D { size * size * size } else { size };
        if table.len() != expected {
            return Err(CubeLutError::WrongEntryCount { expected, found: table.len() });
        }
        CubeLut::new(&title, kind, size, (dmin, dmax), table, (in_video, out_video))
    }

    /// Autodesk / Lustre `.3dl`: an optional first line with the input mesh points (N integers, N = cube size), then
    /// N^3 rows of three integers, the red index outermost and blue changing fastest. The output depth (10, 12 or 16
    /// bit) is taken from the largest value; fractional files already in 0...1 stay as they are. Header lines that start
    /// with a letter are skipped. The result is the same 3D table a `.cube` gives (red fastest, domain 0...1).
    pub fn parse_3dl(text: &str) -> Result<CubeLut, CubeLutError> {
        let mut mesh_size: Option<usize> = None;
        let mut rows: Vec<Vec3> = Vec::new();
        let (mut fractional, mut non_integer, mut first_is_mesh_candidate) = (false, false, false);
        for (i, raw) in split_lines(strip_bom(text)).into_iter().enumerate() {
            let line = trim_ws(strip_comment(raw));
            if line.is_empty() {
                continue;
            }
            let parts = fields(line, true);
            if parts.first().is_some_and(|p| p.chars().next().is_some_and(char::is_alphabetic)) {
                continue;
            }
            let mut values: Vec<f32> = Vec::new();
            for p in &parts {
                let f = number(p, i + 1)?;
                if p.contains('.') {
                    fractional = true;
                }
                if f != f.round_ties_even() {
                    non_integer = true;
                }
                values.push(f);
            }
            if values.len() == 3 {
                if rows.is_empty() && mesh_size.is_none() {
                    // A size-3 cube's mesh line has three values too: ascending integers, decided once the rows are counted.
                    first_is_mesh_candidate = !line.contains('.') && values[0] < values[1] && values[1] < values[2];
                }
                rows.push(Vec3::new(values[0], values[1], values[2]));
            } else if rows.is_empty() && mesh_size.is_none() && values.len() >= 2 {
                mesh_size = Some(values.len());
            } else {
                return Err(CubeLutError::MalformedLine { line: i + 1 });
            }
        }
        if mesh_size.is_none() && first_is_mesh_candidate && rows.len() == 28 {
            rows.remove(0);
            mesh_size = Some(3);
        }
        let size = mesh_size.unwrap_or_else(|| (rows.len() as f64).powf(1.0 / 3.0).round() as usize);
        if !(2..=256).contains(&size) {
            return Err(CubeLutError::SizeOutOfRange { line: 0, size: size as i64 });
        }
        let expected = size * size * size;
        if rows.len() != expected {
            return Err(CubeLutError::WrongEntryCount { expected, found: rows.len() });
        }
        let peak = rows.iter().fold(0f32, |m, r| m.max(r.max_elem()));
        let depth: f32 = if non_integer || (fractional && peak <= 1.0) {
            1.0
        } else if peak <= 1023.0 {
            1023.0
        } else if peak <= 4095.0 {
            4095.0
        } else {
            65535.0
        };
        let mut table = vec![Vec3::ZERO; expected];
        for r in 0..size {
            for g in 0..size {
                for b in 0..size {
                    table[r + size * (g + size * b)] = rows[(r * size + g) * size + b] / depth;
                }
            }
        }
        Self::plain(size, table)
    }

    /// Panasonic VariCam `.vlt`: comment lines, a `LUT_3D_SIZE N` line, then N^3 rows `R G B` with integers 0...4095, red
    /// changing fastest. Same table as a `.cube` (domain 0...1).
    /// shortcut: layout taken from a summary of the public manual (as in Swift); re-check the 4095 scale and the
    /// red-fastest order against a real camera file if a look comes out wrong.
    pub fn parse_vlt(text: &str) -> Result<CubeLut, CubeLutError> {
        let mut size: Option<usize> = None;
        let mut rows: Vec<Vec3> = Vec::new();
        for (i, raw) in split_lines(strip_bom(text)).into_iter().enumerate() {
            let line = trim_ws(strip_comment(raw));
            if line.is_empty() {
                continue;
            }
            let parts = fields(line, false);
            if parts[0] == "LUT_3D_SIZE" {
                let s = if parts.len() == 2 { parts[1].parse::<i64>().ok() } else { None };
                let Some(s) = s else { return Err(CubeLutError::MalformedLine { line: i + 1 }) };
                if !(2..=256).contains(&s) {
                    return Err(CubeLutError::SizeOutOfRange { line: i + 1, size: s });
                }
                size = Some(s as usize);
                continue;
            }
            if parts.len() != 3 {
                return Err(CubeLutError::MalformedLine { line: i + 1 });
            }
            let mut v = Vec3::ZERO;
            for k in 0..3 {
                v[k] = number(parts[k], i + 1)? / 4095.0;
            }
            rows.push(v);
        }
        let size = size.ok_or(CubeLutError::MissingSize)?;
        if rows.len() != size * size * size {
            return Err(CubeLutError::WrongEntryCount { expected: size * size * size, found: rows.len() });
        }
        Self::plain(size, rows)
    }

    /// Input clamped to the domain; 3D tetrahedral (or trilinear), 1D linear per channel.
    /// `LUT_IN_VIDEO_RANGE` / `LUT_OUT_VIDEO_RANGE` use the 10-bit convention (black 64, white 940, of 1023):
    /// in: `x = x*876/1023 + 64/1023` before the domain mapping; out: `y = (y - 64/1023)*1023/876`.
    pub fn lookup(&self, rgb: Vec3) -> Vec3 {
        let mut x = rgb;
        if self.in_video_range {
            x = x * 876.0 / 1023.0 + Vec3::splat(64.0 / 1023.0);
        }
        let t = ((x - self.domain_min) / (self.domain_max - self.domain_min)).clamp(Vec3::ZERO, Vec3::ONE);
        let scale = (self.size - 1) as f32;
        let mut out = if self.kind == CubeKind::Lut1D {
            self.linear_1d(t * scale)
        } else if self.interpolation == LutInterpolation::Trilinear {
            self.trilinear(t * scale)
        } else {
            self.tetrahedral(t * scale)
        };
        if self.out_video_range {
            out = (out - Vec3::splat(64.0 / 1023.0)) * 1023.0 / 876.0;
        }
        out
    }

    fn linear_1d(&self, p: Vec3) -> Vec3 {
        let mut out = Vec3::ZERO;
        for ch in 0..3 {
            let i0 = (p[ch] as usize).min(self.size - 2);
            let f = p[ch] - i0 as f32;
            out[ch] = self.table[i0][ch] + (self.table[i0 + 1][ch] - self.table[i0][ch]) * f;
        }
        out
    }

    /// Cell index and fractions of a point in table units.
    fn cell(&self, p: Vec3) -> (usize, [f32; 3]) {
        let n = self.size;
        let ir = (p.x as usize).min(n - 2);
        let ig = (p.y as usize).min(n - 2);
        let ib = (p.z as usize).min(n - 2);
        (ir + n * (ig + n * ib), [p.x - ir as f32, p.y - ig as f32, p.z - ib as f32])
    }

    fn trilinear(&self, p: Vec3) -> Vec3 {
        let n = self.size;
        let (base, [fr, fg, fb]) = self.cell(p);
        let c = |r: usize, g: usize, b: usize| self.table[base + r + g * n + b * n * n];
        let x00 = c(0, 0, 0) + (c(1, 0, 0) - c(0, 0, 0)) * fr;
        let x10 = c(0, 1, 0) + (c(1, 1, 0) - c(0, 1, 0)) * fr;
        let x01 = c(0, 0, 1) + (c(1, 0, 1) - c(0, 0, 1)) * fr;
        let x11 = c(0, 1, 1) + (c(1, 1, 1) - c(0, 1, 1)) * fr;
        let y0 = x00 + (x10 - x00) * fg;
        let y1 = x01 + (x11 - x01) * fg;
        y0 + (y1 - y0) * fb
    }

    fn tetrahedral(&self, p: Vec3) -> Vec3 {
        let n = self.size;
        let (base, [fr, fg, fb]) = self.cell(p);
        let c = |r: usize, g: usize, b: usize| self.table[base + r + g * n + b * n * n];
        let (c000, c111) = (c(0, 0, 0), c(1, 1, 1));
        if fr >= fg {
            if fg >= fb {
                c000 + fr * (c(1, 0, 0) - c000) + fg * (c(1, 1, 0) - c(1, 0, 0)) + fb * (c111 - c(1, 1, 0))
            } else if fr >= fb {
                c000 + fr * (c(1, 0, 0) - c000) + fb * (c(1, 0, 1) - c(1, 0, 0)) + fg * (c111 - c(1, 0, 1))
            } else {
                c000 + fb * (c(0, 0, 1) - c000) + fr * (c(1, 0, 1) - c(0, 0, 1)) + fg * (c111 - c(1, 0, 1))
            }
        } else if fb >= fg {
            c000 + fb * (c(0, 0, 1) - c000) + fg * (c(0, 1, 1) - c(0, 0, 1)) + fr * (c111 - c(0, 1, 1))
        } else if fb >= fr {
            c000 + fg * (c(0, 1, 0) - c000) + fb * (c(0, 1, 1) - c(0, 1, 0)) + fr * (c111 - c(0, 1, 1))
        } else {
            c000 + fg * (c(0, 1, 0) - c000) + fr * (c(1, 1, 0) - c(0, 1, 0)) + fb * (c111 - c(1, 1, 0))
        }
    }
}
