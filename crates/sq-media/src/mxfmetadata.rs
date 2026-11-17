// Swift: MXF/MXFMetadata.swift
//! Structural metadata of an MXF file (header metadata sets of ST 377-1) resolved into tracks and descriptors.
//!
//! The Swift file returns CoreMedia color tag constants; the strings below are those constants' values.

use crate::mxfklv::{MxfBytes, MxfKlv, MxfUl};
use sq_core_model::FieldOrder;
use sq_core_time::Time;
use std::collections::HashMap;
use std::hash::{Hash, Hasher};
use std::ops::Range;

/// Start timecode of an MXF file (timecode track of the material package, else of the file package).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct MxfTimecode {
    /// Frame count of the first frame since 00:00:00:00.
    pub start_frame: i64,
    /// Frames per second rounded up (24, 25, 30, 50, 60).
    pub base: i64,
    pub drop_frame: bool,
}

impl MxfTimecode {
    /// "HH:MM:SS:FF", with ";" before the frames for drop frame.
    pub fn string(&self) -> String {
        if self.base <= 0 {
            return "00:00:00:00".to_string();
        }
        let mut f = self.start_frame.max(0);
        let b = self.base;
        if self.drop_frame && (self.base == 30 || self.base == 60) {
            let drop = b / 15; // 2 at 29.97, 4 at 59.94
            let per10 = b * 600 - 9 * drop;
            let per_min = b * 60 - drop;
            let d = f / per10;
            let m = f % per10;
            f += 9 * drop * d + if m > drop { drop * ((m - drop) / per_min) } else { 0 };
        }
        let ff = f % b;
        let s = (f / b) % 60;
        let m = (f / (b * 60)) % 60;
        let h = (f / (b * 3600)) % 24;
        let sep = if self.drop_frame { ';' } else { ':' };
        format!("{h:02}:{m:02}:{s:02}{sep}{ff:02}")
    }
}

/// Picture essence descriptor (CDCI, RGBA, MPEG video) of one track.
#[derive(Clone, Debug, Default)]
pub struct MxfPictureDescriptor {
    pub coding: Option<MxfUl>,
    pub container: Option<MxfUl>,
    pub stored_width: i64,
    pub stored_height: i64,
    pub display_width: i64,
    pub display_height: i64,
    /// 0 full frame, 1 separate fields, 2 single field, 3 mixed fields, 4 segmented frame.
    pub frame_layout: i64,
    pub(crate) aspect_num: i64,
    pub(crate) aspect_den: i64,
    pub component_depth: i64,
    pub horizontal_subsampling: i64,
    pub vertical_subsampling: i64,
    pub transfer: Option<MxfUl>,
    pub primaries: Option<MxfUl>,
    pub coding_equations: Option<MxfUl>,
    pub is_rgba: bool,
    /// 0 not written (field 1 first), 1 field 1 is the earlier field, 2 field 2 is.
    pub field_dominance: i64,
    /// First active line of field 1 and of field 2 (0 = not written).
    pub video_line_map: (i64, i64),
}

impl MxfPictureDescriptor {
    /// Display aspect ratio (numerator, denominator) when the descriptor has one.
    pub fn aspect(&self) -> Option<(i64, i64)> {
        (self.aspect_num > 0 && self.aspect_den > 0).then_some((self.aspect_num, self.aspect_den))
    }

    /// "4:2:2", "4:2:0", "4:4:4" from the subsampling factors; None when the descriptor does not say.
    pub fn chroma(&self) -> Option<&'static str> {
        if self.is_rgba {
            return Some("4:4:4");
        }
        match (self.horizontal_subsampling, self.vertical_subsampling) {
            (2, 2) => Some("4:2:0"),
            (2, 1) | (2, 0) => Some("4:2:2"),
            (1, 1) | (1, 0) => Some("4:4:4"),
            _ => None,
        }
    }

    pub fn is_interlaced(&self) -> bool {
        self.frame_layout == 1 || self.frame_layout == 3
    }

    /// The earlier field of interlaced pictures; None for progressive material: full frame (0), segmented frame (4,
    /// PsF: one progressive picture carried as two fields) and single field (2, nothing to pair).
    /// The line map says which field is the upper one, the rule of FFmpeg's reader: one odd and one even start line
    /// (1080i: 21 and 584, 625 lines: 23 and 336) means field 1 is the top field, two of the same parity (525-line
    /// DV: 23 and 285) means it is the bottom field. Without a line map field 1 is taken as the top field, as in
    /// every HD format. Field dominance 2 swaps the two in time.
    pub fn field_order(&self) -> Option<FieldOrder> {
        if !self.is_interlaced() {
            return None;
        }
        let (first, second) = self.video_line_map;
        let mapped = first > 0 && second > 0;
        let field_one_is_top = !mapped || (first + second) % 2 == 1;
        Some(if field_one_is_top == (self.field_dominance != 2) {
            FieldOrder::TopFirst
        } else {
            FieldOrder::BottomFirst
        })
    }

    /// Color tag of the transfer label (ST 377-1 annex, RP 224 `04 01 01 01 0k xx`).
    pub fn transfer_tag(&self) -> Option<&'static str> {
        let u = self.transfer.filter(|u| u.matches(&[0x04, 0x01, 0x01, 0x01, 0x01], 8))?;
        match u.byte(13) {
            0x01 | 0x02 | 0x04 | 0x05 => Some("ITU_R_709_2"),
            0x03 => Some("SMPTE_240M_1995"),
            0x06 => Some("Linear"),
            0x09 => Some("ITU_R_2020"),
            0x0A => Some("SMPTE_ST_2084_PQ"),
            0x0B => Some("ITU_R_2100_HLG"),
            _ => None,
        }
    }

    /// Color tag of the primaries label.
    pub fn primaries_tag(&self) -> Option<&'static str> {
        let u = self.primaries.filter(|u| u.matches(&[0x04, 0x01, 0x01, 0x01, 0x03], 8))?;
        match u.byte(13) {
            0x01 => Some("SMPTE_C"),
            0x02 => Some("EBU_3213"),
            0x03 => Some("ITU_R_709_2"),
            0x04 => Some("ITU_R_2020"),
            0x06 => Some("P3_D65"),
            _ => None,
        }
    }

    /// Color tag of the coding equations label.
    pub fn matrix_tag(&self) -> Option<&'static str> {
        let u = self.coding_equations.filter(|u| u.matches(&[0x04, 0x01, 0x01, 0x01, 0x02], 8))?;
        match u.byte(13) {
            0x01 => Some("ITU_R_601_4"),
            0x02 => Some("ITU_R_709_2"),
            0x03 => Some("SMPTE_240M_1995"),
            0x06 => Some("ITU_R_2020"),
            _ => None,
        }
    }
}

impl PartialEq for MxfPictureDescriptor {
    fn eq(&self, b: &Self) -> bool {
        self.coding == b.coding
            && self.container == b.container
            && self.stored_width == b.stored_width
            && self.stored_height == b.stored_height
            && self.frame_layout == b.frame_layout
            && self.component_depth == b.component_depth
    }
}

impl Eq for MxfPictureDescriptor {}

impl Hash for MxfPictureDescriptor {
    fn hash<H: Hasher>(&self, h: &mut H) {
        self.coding.hash(h);
        self.stored_width.hash(h);
        self.stored_height.hash(h);
    }
}

/// Sound essence descriptor (generic sound, wave, AES3) of one track.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct MxfSoundDescriptor {
    pub container: Option<MxfUl>,
    pub compression: Option<MxfUl>,
    pub sample_rate: i64,
    pub channels: i64,
    pub bits: i64,
    pub block_align: i64,
}

impl Default for MxfSoundDescriptor {
    fn default() -> Self {
        MxfSoundDescriptor {
            container: None,
            compression: None,
            sample_rate: 48_000,
            channels: 1,
            bits: 16,
            block_align: 0,
        }
    }
}

impl MxfSoundDescriptor {
    pub fn bytes_per_sample(&self) -> i64 {
        if self.block_align > 0
            && self.channels > 0
            && self.block_align % self.channels == 0
            && (1..=4).contains(&(self.block_align / self.channels))
        {
            return self.block_align / self.channels;
        }
        1.max(4.min((self.bits + 7) / 8))
    }

    /// PCM is little endian unless the compression label says big endian (`04 02 02 01 7E`, AIFF style).
    pub fn is_big_endian(&self) -> bool {
        self.compression.is_some_and(|c| c.matches(&[0x04, 0x02, 0x02, 0x01, 0x7E], 8))
    }

    /// Uncompressed PCM: no compression label, or one of the PCM labels (`04 02 02 01 xx`).
    pub fn is_pcm(&self) -> bool {
        match self.compression {
            Some(c) if c.hi != 0 || c.lo != 0 => c.matches(&[0x04, 0x02, 0x02, 0x01], 8),
            _ => true,
        }
    }

    /// Name of a compressed sound coding for messages.
    pub fn codec_name(&self) -> &'static str {
        let Some(c) = self.compression.filter(|_| !self.is_pcm()) else { return "PCM" };
        if c.matches(&[0x04, 0x02, 0x02, 0x02, 0x03, 0x01, 0x01], 8) {
            return "A-law";
        }
        if c.matches(&[0x04, 0x02, 0x02, 0x02, 0x03, 0x02, 0x01], 8) {
            return "AC-3";
        }
        if c.matches(&[0x04, 0x02, 0x02, 0x02, 0x03, 0x02], 8) {
            return "MPEG audio";
        }
        if c.matches(&[0x04, 0x02, 0x02, 0x02, 0x04], 8) || c.matches(&[0x04, 0x02, 0x02, 0x02, 0x03, 0x03], 8) {
            return "AAC";
        }
        "compressed audio"
    }
}

/// What kind of essence a track carries.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum MxfTrackKind {
    Picture,
    Sound,
    Data,
    Other,
}

/// One essence track of the file package.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct MxfTrack {
    pub id: u32,
    /// Bytes 12...15 of this track's essence element keys.
    pub number: u32,
    pub kind: MxfTrackKind,
    pub edit_rate_num: i64,
    pub edit_rate_den: i64,
    pub origin: i64,
    /// Duration in edit units from the metadata (-1 unknown, e.g. a file still being written).
    pub duration: i64,
    pub picture: Option<MxfPictureDescriptor>,
    pub sound: Option<MxfSoundDescriptor>,
}

impl Default for MxfTrack {
    fn default() -> Self {
        MxfTrack {
            id: 0,
            number: 0,
            kind: MxfTrackKind::Other,
            edit_rate_num: 0,
            edit_rate_den: 1,
            origin: 0,
            duration: -1,
            picture: None,
            sound: None,
        }
    }
}

impl MxfTrack {
    /// Length of one edit unit.
    pub fn edit_unit(&self) -> Option<Time> {
        (self.edit_rate_num > 0 && self.edit_rate_den > 0).then(|| Time::new(self.edit_rate_den, self.edit_rate_num))
    }
}

/// A header metadata local set: 2-byte tag, 2-byte length items.
pub(crate) struct MxfSet<'a> {
    pub(crate) kind: u8,
    pub(crate) items: HashMap<u16, Range<usize>>,
    pub(crate) r: &'a MxfBytes,
}

impl<'a> MxfSet<'a> {
    pub(crate) fn new(r: &'a MxfBytes, k: &MxfKlv, kind: u8) -> MxfSet<'a> {
        let mut items: HashMap<u16, Range<usize>> = HashMap::new();
        let mut p = k.value_offset;
        let end = k.end().min(r.count());
        while p + 4 <= end {
            let (Some(tag), Some(len)) = (r.u16(p), r.u16(p + 2)) else { break };
            let v = p + 4;
            if v + usize::from(len) > end {
                break;
            }
            items.insert(tag, v..v + usize::from(len));
            p = v + usize::from(len);
        }
        MxfSet { kind, items, r }
    }

    pub(crate) fn uint(&self, tag: u16) -> Option<u64> {
        let i = self.items.get(&tag).filter(|i| (1..=8).contains(&i.len()))?;
        self.r.uint(i.start, i.len())
    }

    pub(crate) fn int(&self, tag: u16) -> Option<i64> {
        self.uint(tag).filter(|&v| v <= u64::from(i32::MAX as u32) * 4).map(|v| v as i64)
    }

    pub(crate) fn int64(&self, tag: u16) -> Option<i64> {
        let i = self.items.get(&tag).filter(|i| i.len() == 8)?;
        self.r.u64(i.start).map(|v| v as i64)
    }

    pub(crate) fn ul(&self, tag: u16) -> Option<MxfUl> {
        let i = self.items.get(&tag).filter(|i| i.len() == 16)?;
        self.r.ul(i.start)
    }

    /// Two signed 32-bit integers (numerator, denominator).
    pub(crate) fn rational(&self, tag: u16) -> Option<(i64, i64)> {
        let i = self.items.get(&tag).filter(|i| i.len() == 8)?;
        let (n, d) = (self.r.u32(i.start)?, self.r.u32(i.start + 4)?);
        Some((i64::from(n as i32), i64::from(d as i32)))
    }

    /// A batch or array of 16-byte references (count, item length, items).
    pub(crate) fn refs(&self, tag: u16) -> Vec<MxfUl> {
        let Some(i) = self.items.get(&tag).filter(|i| i.len() >= 8) else { return vec![] };
        let (Some(n), Some(len)) = (self.r.u32(i.start), self.r.u32(i.start + 4)) else { return vec![] };
        if len < 16 {
            return vec![];
        }
        let fit = (i.len() - 8) / len as usize;
        (0..(n as usize).min(fit)).filter_map(|k| self.r.ul(i.start + 8 + k * len as usize)).collect()
    }
}

/// The structural metadata the engine needs, resolved from the header metadata sets.
#[derive(Clone, Debug, Default)]
pub(crate) struct MxfMetadata {
    pub(crate) tracks: Vec<MxfTrack>,
    pub(crate) timecode: Option<MxfTimecode>,
}

const PICTURE_KINDS: [u8; 4] = [0x27, 0x28, 0x29, 0x51];
const SOUND_KINDS: [u8; 3] = [0x42, 0x47, 0x48];

impl MxfMetadata {
    /// Parses the sets in `region` (primer pack and sets of one partition).
    pub(crate) fn parse(r: &MxfBytes, region: Range<usize>) -> MxfMetadata {
        let mut sets: HashMap<MxfUl, MxfSet> = HashMap::new();
        let mut order: Vec<MxfUl> = Vec::new();
        let mut p = region.start;
        let end = region.end.min(r.count());
        let mut guard_count = 0;
        while p < end && guard_count < 200_000 {
            let Some(k) = r.klv(p) else { break };
            guard_count += 1;
            if let Some(kind) = k.key.metadata_set_kind() {
                let s = MxfSet::new(r, &k, kind);
                if let Some(uid) = s.ul(0x3C0A)
                    && !sets.contains_key(&uid)
                {
                    sets.insert(uid, s);
                    order.push(uid);
                }
            }
            if k.end() <= p || k.end() > r.count() {
                break;
            }
            p = k.end();
        }
        resolve(&sets, &order)
    }
}

fn file_descriptors<'a>(sets: &'a HashMap<MxfUl, MxfSet>, package: &MxfSet) -> Vec<&'a MxfSet<'a>> {
    let Some(d) = package.ul(0x4701).and_then(|u| sets.get(&u)) else { return vec![] };
    let list: Vec<&MxfSet> =
        if d.kind == 0x44 { d.refs(0x3F01).iter().filter_map(|u| sets.get(u)).collect() } else { vec![d] };
    list.into_iter().filter(|s| PICTURE_KINDS.contains(&s.kind) || SOUND_KINDS.contains(&s.kind)).collect()
}

fn track_sets<'a>(sets: &'a HashMap<MxfUl, MxfSet>, package: Option<&MxfSet>) -> Vec<&'a MxfSet<'a>> {
    let Some(package) = package else { return vec![] };
    package.refs(0x4403).iter().filter_map(|u| sets.get(u)).filter(|s| s.kind == 0x3B).collect()
}

fn components<'a>(sets: &'a HashMap<MxfUl, MxfSet>, track: &MxfSet) -> (Option<&'a MxfSet<'a>>, Vec<&'a MxfSet<'a>>) {
    let Some(s) = track.ul(0x4803).and_then(|u| sets.get(&u)) else { return (None, vec![]) };
    if s.kind == 0x0F {
        return (Some(s), s.refs(0x1001).iter().filter_map(|u| sets.get(u)).collect());
    }
    (None, vec![s])
}

fn resolve(sets: &HashMap<MxfUl, MxfSet>, order: &[MxfUl]) -> MxfMetadata {
    let all: Vec<&MxfSet> = order.iter().filter_map(|u| sets.get(u)).collect();
    let source_packages: Vec<&MxfSet> = all.iter().copied().filter(|s| s.kind == 0x37).collect();
    let file_package = source_packages
        .iter()
        .copied()
        .find(|s| !file_descriptors(sets, s).is_empty())
        .or_else(|| source_packages.first().copied());
    let mut descriptors = file_package.map(|p| file_descriptors(sets, p)).unwrap_or_default();
    if descriptors.is_empty() {
        descriptors =
            all.iter().copied().filter(|s| PICTURE_KINDS.contains(&s.kind) || SOUND_KINDS.contains(&s.kind)).collect();
    }

    let mut track_set_list = track_sets(sets, file_package);
    if track_set_list.is_empty() && file_package.is_none() {
        track_set_list = all.iter().copied().filter(|s| s.kind == 0x3B).collect();
    }

    let mut out = MxfMetadata::default();
    let mut unlinked: Vec<&MxfSet> = descriptors.iter().copied().filter(|d| d.int(0x3006).is_none()).collect();
    for t in track_set_list {
        let mut track = MxfTrack {
            id: t.uint(0x4801).unwrap_or(0) as u32,
            number: t.uint(0x4804).unwrap_or(0) as u32,
            ..MxfTrack::default()
        };
        if let Some((n, d)) = t.rational(0x4B01)
            && n > 0
            && d > 0
        {
            track.edit_rate_num = n;
            track.edit_rate_den = d;
        }
        track.origin = t.int64(0x4B02).unwrap_or(0);
        let (seq, _) = components(sets, t);
        if let Some(d) = seq.and_then(|s| s.int64(0x0202)) {
            track.duration = d;
        }

        let mut desc: Option<&MxfSet> =
            descriptors.iter().copied().find(|d| d.int(0x3006).map(|v| v as u32) == Some(track.id) && track.id != 0);
        let item = (track.number >> 24) as u8;
        let number_kind = match item {
            0x05 | 0x15 => MxfTrackKind::Picture,
            0x06 | 0x16 => MxfTrackKind::Sound,
            0x07 | 0x17 => MxfTrackKind::Data,
            _ => MxfTrackKind::Other,
        };
        let mut definition_kind = MxfTrackKind::Other;
        if let Some(dd) = seq.and_then(|s| s.ul(0x0201))
            && dd.matches(&[0x01, 0x03, 0x02, 0x02], 8)
        {
            definition_kind = match dd.byte(12) {
                1 => MxfTrackKind::Picture,
                2 => MxfTrackKind::Sound,
                3 => MxfTrackKind::Data,
                _ => MxfTrackKind::Other,
            };
        }
        let guess = if number_kind != MxfTrackKind::Other { number_kind } else { definition_kind };
        if desc.is_none() && (guess == MxfTrackKind::Picture || guess == MxfTrackKind::Sound) {
            // No LinkedTrackID: descriptors without one are taken in order, by kind.
            let kinds: &[u8] = if guess == MxfTrackKind::Picture { &PICTURE_KINDS } else { &SOUND_KINDS };
            if let Some(i) = unlinked.iter().position(|d| kinds.contains(&d.kind)) {
                desc = Some(unlinked.remove(i));
            }
        }
        if let Some(d) = desc.filter(|d| PICTURE_KINDS.contains(&d.kind)) {
            track.kind = MxfTrackKind::Picture;
            track.picture = Some(picture(d));
        } else if let Some(d) = desc.filter(|d| SOUND_KINDS.contains(&d.kind)) {
            track.kind = MxfTrackKind::Sound;
            track.sound = Some(sound(d));
        } else {
            track.kind = guess;
        }
        if matches!(track.kind, MxfTrackKind::Picture | MxfTrackKind::Sound | MxfTrackKind::Data) {
            out.tracks.push(track.clone());
        }
        if track.edit_rate_num == 0
            && let Some(d) = desc
            && let Some((n, den)) = d.rational(0x3001)
            && n > 0
            && den > 0
            && track.kind == MxfTrackKind::Picture
            && let Some(last) = out.tracks.last_mut()
        {
            last.edit_rate_num = n;
            last.edit_rate_den = den;
        }
    }

    // Timecode: the material package's timecode track is what editors show; the file package's is the fallback.
    let material = all.iter().copied().find(|s| s.kind == 0x36);
    for package in [material, file_package] {
        if out.timecode.is_some() {
            continue;
        }
        for t in track_sets(sets, package) {
            let Some(tc) = components(sets, t).1.into_iter().find(|p| p.kind == 0x14) else { continue };
            let (Some(start), Some(base)) = (tc.int64(0x1501), tc.int(0x1502)) else { continue };
            if base <= 0 || base > 1000 {
                continue;
            }
            out.timecode =
                Some(MxfTimecode { start_frame: start, base, drop_frame: tc.uint(0x1503).unwrap_or(0) != 0 });
            break;
        }
    }
    out
}

fn picture(s: &MxfSet) -> MxfPictureDescriptor {
    let mut d = MxfPictureDescriptor {
        coding: s.ul(0x3201),
        container: s.ul(0x3004),
        stored_height: s.int(0x3202).unwrap_or(0),
        stored_width: s.int(0x3203).unwrap_or(0),
        ..MxfPictureDescriptor::default()
    };
    d.display_height = s.int(0x3208).or(s.int(0x3204)).unwrap_or(d.stored_height);
    d.display_width = s.int(0x3209).or(s.int(0x3205)).unwrap_or(d.stored_width);
    d.frame_layout = s.int(0x320C).unwrap_or(0);
    d.field_dominance = s.int(0x3212).unwrap_or(0);
    // Array of 32-bit integers: count, item length, items.
    if let Some(m) = s.items.get(&0x320D).filter(|m| m.len() >= 16)
        && s.r.u32(m.start) == Some(2)
        && s.r.u32(m.start + 4) == Some(4)
        && let (Some(a), Some(b)) = (s.r.u32(m.start + 8), s.r.u32(m.start + 12))
        && a < 10_000
        && b < 10_000
    {
        d.video_line_map = (i64::from(a), i64::from(b));
    }
    if let Some((n, den)) = s.rational(0x320E) {
        d.aspect_num = n;
        d.aspect_den = den;
    }
    d.transfer = s.ul(0x3210);
    d.primaries = s.ul(0x3219);
    d.coding_equations = s.ul(0x321A);
    d.component_depth = s.int(0x3301).unwrap_or(0);
    d.horizontal_subsampling = s.int(0x3302).unwrap_or(0);
    d.vertical_subsampling = s.int(0x3308).unwrap_or(0);
    d.is_rgba = s.kind == 0x29;
    d
}

fn sound(s: &MxfSet) -> MxfSoundDescriptor {
    let mut d =
        MxfSoundDescriptor { container: s.ul(0x3004), compression: s.ul(0x3D06), ..MxfSoundDescriptor::default() };
    if let Some((n, den)) = s.rational(0x3D03)
        && n > 0
        && den > 0
        && n / den >= 1000
        && n / den <= 768_000
    {
        d.sample_rate = n / den;
    }
    if let Some(c) = s.int(0x3D07).filter(|c| (1..=64).contains(c)) {
        d.channels = c;
    }
    if let Some(b) = s.int(0x3D01).filter(|b| (8..=32).contains(b)) {
        d.bits = b;
    }
    if let Some(a) = s.int(0x3D0A).filter(|a| (1..=256).contains(a)) {
        d.block_align = a;
    }
    d
}

/// Video coding of an MXF picture track.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum MxfVideoCodec {
    H264,
    /// ProRes; None when the label does not name the flavor (the frame header decides). The payload is the FourCC.
    Prores(Option<u32>),
    /// Known coding without a decoder path here; the name is shown to the user.
    Unsupported(String),
}

impl MxfVideoCodec {
    /// From the descriptor's picture essence coding label, else the essence container label. None: neither says.
    pub fn identify(coding: Option<MxfUl>, container: Option<MxfUl>) -> Option<MxfVideoCodec> {
        use MxfVideoCodec::*;
        let unsupported = |s: &str| Some(Unsupported(s.to_string()));
        if let Some(c) = coding.filter(|c| c.hi != 0 || c.lo != 0) {
            if c.matches(&[0x04, 0x01, 0x02, 0x02], 8) {
                match (c.byte(12), c.byte(13)) {
                    (0x01, 0x30..=0x3F) => return Some(H264),
                    (0x01, 0x20..=0x2F) => return unsupported("MPEG-4 Part 2"),
                    (0x01, 0x01..=0x1F) => return unsupported("MPEG-2 (XDCAM / IMX)"),
                    (0x02, _) => return unsupported("DV"),
                    (0x03, 0x01) => return unsupported("JPEG 2000"),
                    (0x03, 0x02) => return unsupported("DNxHD / DNxHR"),
                    (0x03, 0x06) => {
                        let flavor = match c.byte(14) {
                            1 => Some("apco"),
                            2 => Some("apcs"),
                            3 => Some("apcn"),
                            4 => Some("apch"),
                            5 => Some("ap4h"),
                            6 => Some("ap4x"),
                            _ => None,
                        };
                        return Some(Prores(flavor.map(Self::code)));
                    }
                    (0x04, _) => return unsupported("VC-1"),
                    (0x71, _) => return unsupported("DNxHD / DNxHR"),
                    _ => {}
                }
            }
            if c.matches(&[0x04, 0x01, 0x02, 0x01], 8) {
                return unsupported("uncompressed video");
            }
            if c.matches(&[0x0E, 0x04, 0x02, 0x01, 0x02, 0x04], 8) {
                return unsupported("DNxHD / DNxHR");
            }
            if c.matches(&[0x0E, 0x04, 0x02, 0x01, 0x02, 0x11], 8) {
                return Some(Prores(None));
            }
        }
        if let Some(k) = container.filter(|k| k.matches(&[0x0D, 0x01, 0x03, 0x01, 0x02], 8)) {
            match k.byte(13) {
                0x0F | 0x10 => return Some(H264),
                0x1C => return Some(Prores(None)),
                0x01 => return unsupported("MPEG-2 (IMX)"),
                0x02 => return unsupported("DV"),
                0x05 => return unsupported("uncompressed video"),
                0x0C => return unsupported("JPEG 2000"),
                0x11 => return unsupported("DNxHD / DNxHR"),
                0x0A => return unsupported("VC-1"),
                _ => {} // 0x04 MPEG elementary stream: MPEG-2 or H.264, the stream decides
            }
        }
        None
    }

    /// FourCC of a four-letter code, first letter in the high byte.
    pub(crate) fn code(s: &str) -> u32 {
        s.bytes().fold(0, |a, b| a << 8 | u32::from(b))
    }
}
