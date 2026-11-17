// Swift: AudioChannelMap.swift (the type and its `new`/`fitting` live in sq-core-model)
//! F7.10: which channels of a media file feed a clip's two sides (source settings > Audio Channels). A setting of the
//! media item: every clip of it, playback, scrubbing, export and the waveform read the file through it.
//!
//! Levels: channels that go to both sides alike are summed at -3 dB each (equal power, so two microphones in the
//! center do not come out 6 dB hot); a single channel, and channels routed to one side only, stay at unity.

use sq_core_model::{AudioChannelMap, AudioTrackInfo, MediaInfo, Project};
use sq_core_time::Id;
use std::collections::BTreeMap;

/// How the two sides of a map relate.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum AudioChannelLayout {
    /// One channel on both sides.
    Mono,
    /// One channel per side.
    Stereo,
    /// Two channels, both in the center.
    DualMono,
    /// Anything else.
    Custom,
}

fn extension_of(path: &str) -> String {
    // NSString.pathExtension: the text after the last "." of the last path component, none for a leading dot only.
    let name = path.rsplit('/').next().unwrap_or("");
    match name.rfind('.') {
        Some(i) if i > 0 => name[i + 1..].to_lowercase(),
        _ => String::new(),
    }
}

fn is_matroska(ext: &str) -> bool {
    ["webm", "mkv", "mka"].contains(&ext)
}

/// Logic Swift keeps in `extension AudioChannelMap`.
pub trait AudioChannelMapExt: Sized {
    /// One channel on both sides.
    fn mono(channel: i64) -> Option<Self>;
    /// One channel per side.
    fn stereo(l: i64, r: i64) -> Option<Self>;
    /// Two channels, both in the center (two microphones on one clip).
    fn dual_mono(a: i64, b: i64) -> Option<Self>;
    /// The layout class of the map.
    fn layout(&self) -> AudioChannelLayout;
    /// Both sides get the same signal: the clip is a mono source (pan law, one waveform lane).
    fn is_centered(&self) -> bool;
    /// Gain of each summed channel (see the module note on levels).
    fn gain(&self) -> f32;
    /// Highest channel the map reads.
    fn highest_channel(&self) -> i64;
    /// What the file's own layout plays, as a map; `None` when that is not known from the probe info. An MXF's channels
    /// 1 + 2 sit in the center (its mono tracks are microphones); any other file with one or two channels plays them as
    /// they are. More channels are the reader's own mix, which no map names.
    fn file_layout(audio: &AudioTrackInfo, path: &str) -> Option<Self>;
    /// What is stored when `self` is chosen for a file: the fitted map, or `None` when it does not fit (see `fitting`)
    /// or names exactly what the file's layout plays anyway (a choice that changes nothing is no choice).
    fn stored(&self, audio: &AudioTrackInfo, path: &str) -> Option<Self>;
    /// "Mono: 3", "Stereo: 1 + 2", "Dual Mono: 1 + 2" (channels counted from 1, as cameras label them).
    fn label(&self) -> String;
}

impl AudioChannelMapExt for AudioChannelMap {
    fn mono(channel: i64) -> Option<Self> {
        AudioChannelMap::new(&[channel], &[channel])
    }

    fn stereo(l: i64, r: i64) -> Option<Self> {
        if l == r { None } else { AudioChannelMap::new(&[l], &[r]) }
    }

    fn dual_mono(a: i64, b: i64) -> Option<Self> {
        if a == b { None } else { AudioChannelMap::new(&[a, b], &[a, b]) }
    }

    fn layout(&self) -> AudioChannelLayout {
        let (left, right) = (self.left(), self.right());
        if left == right {
            return match left.len() {
                1 => AudioChannelLayout::Mono,
                2 => AudioChannelLayout::DualMono,
                _ => AudioChannelLayout::Custom,
            };
        }
        if left.len() == 1 && right.len() == 1 { AudioChannelLayout::Stereo } else { AudioChannelLayout::Custom }
    }

    fn is_centered(&self) -> bool {
        self.left() == self.right()
    }

    fn gain(&self) -> f32 {
        if self.is_centered() && self.left().len() > 1 { 0.5_f32.sqrt() } else { 1.0 }
    }

    fn highest_channel(&self) -> i64 {
        let last = |c: &[i64]| c.last().copied().unwrap_or(0);
        last(self.left()).max(last(self.right()))
    }

    fn file_layout(audio: &AudioTrackInfo, path: &str) -> Option<Self> {
        let ext = extension_of(path);
        let mut audio = audio.clone();
        audio.channels = audio.first_track_channels.unwrap_or(audio.channels); // the file's own layout is its first track
        audio.channels = audio.mappable_channels(path);
        if ext == "mxf" {
            if audio.codec != "PCM" {
                return None; // probed by another reader: layout unknown
            }
            return if audio.channels > 1 {
                Self::dual_mono(0, 1)
            } else if audio.channels == 1 {
                Self::mono(0)
            } else {
                None
            };
        }
        // "PCM" is how the MXF and the WebM reader name their sound: outside a WebM it may be an MXF under another name.
        if audio.codec == "PCM" && !is_matroska(&ext) {
            return None;
        }
        match audio.channels {
            2 => Self::stereo(0, 1),
            1 => Self::mono(0),
            _ => None,
        }
    }

    fn stored(&self, audio: &AudioTrackInfo, path: &str) -> Option<Self> {
        let fitted = self.fitting(audio.mappable_channels(path))?;
        if Some(&fitted) == Self::file_layout(audio, path).as_ref() { None } else { Some(fitted) }
    }

    fn label(&self) -> String {
        let list = |c: &[i64]| {
            if c.is_empty() {
                "none".to_string()
            } else {
                c.iter().map(|x| (x + 1).to_string()).collect::<Vec<_>>().join(" + ")
            }
        };
        match self.layout() {
            AudioChannelLayout::Mono => format!("Mono: {}", list(self.left())),
            AudioChannelLayout::Stereo => {
                let both: Vec<i64> = self.left().iter().chain(self.right()).copied().collect();
                format!("Stereo: {}", list(&both))
            }
            AudioChannelLayout::DualMono => format!("Dual Mono: {}", list(self.left())),
            AudioChannelLayout::Custom if self.is_centered() => format!("Center: {}", list(self.left())),
            AudioChannelLayout::Custom => format!("Left: {}, Right: {}", list(self.left()), list(self.right())),
        }
    }
}

/// `extension AudioTrackInfo` of AudioChannelMap.swift.
pub trait AudioTrackInfoExt {
    /// Channels a map may address: the file's, but a WebM / Matroska file is read by our own decoder that delivers two
    /// (a 5.1 mix is not offered, so no map names a channel the reader cannot deliver).
    fn mappable_channels(&self, path: &str) -> i64;
}

impl AudioTrackInfoExt for AudioTrackInfo {
    fn mappable_channels(&self, path: &str) -> i64 {
        if is_matroska(&extension_of(path)) { self.channels.min(2) } else { self.channels }
    }
}

/// `extension Project` of AudioChannelMap.swift.
pub trait ProjectChannelMapExt {
    /// The channel map chosen for `id`; `None` = the file's own layout (also for unknown media).
    fn audio_channel_map(&self, id: Id) -> Option<AudioChannelMap>;
    /// Source settings > Audio Channels: which file channels `id` plays from now on, for every clip of it (a setting of
    /// the media item; subclips share their file's setting). `None` = the file's layout, which is also what a map that
    /// names that layout is stored as. Channels the file lacks are dropped. Returns whether anything changed; false for
    /// unknown media, media without (probed) audio and a map that does not fit the file (`fitting`).
    fn set_audio_channel_map(&mut self, map: Option<&AudioChannelMap>, id: Id) -> bool;
    /// After media was pointed at other files (relink): a chosen map is fitted to the probed sound of the new file, and
    /// cleared when it does not fit, so the label and the file version say what is heard. The item's sound info becomes
    /// the new file's. Media without a chosen map takes the new file's sound info too (channel counts and the first
    /// track's count follow the file); the rest of its info is left alone. Returns whether anything changed.
    fn fit_audio_channel_maps(&mut self, probed: &BTreeMap<Id, MediaInfo>) -> bool;
}

impl ProjectChannelMapExt for Project {
    fn audio_channel_map(&self, id: Id) -> Option<AudioChannelMap> {
        self.media(id)?.info.as_ref()?.audio.as_ref()?.channel_map.clone()
    }

    fn set_audio_channel_map(&mut self, map: Option<&AudioChannelMap>, id: Id) -> bool {
        let Some(item) = self.media(id) else { return false };
        let file = item.subclip.as_ref().map_or(id, |s| s.parent);
        let mut changed = false;
        for m in self.media.iter_mut().filter(|m| m.id == file || m.subclip.as_ref().is_some_and(|s| s.parent == file))
        {
            let path = m.path.clone();
            let Some(a) = m.info.as_mut().and_then(|i| i.audio.as_mut()) else { continue };
            let value = match map {
                Some(map) => {
                    if map.fitting(a.mappable_channels(&path)).is_none() {
                        continue;
                    }
                    map.stored(a, &path)
                }
                None => None,
            };
            if value == a.channel_map {
                continue;
            }
            a.channel_map = value;
            changed = true;
        }
        changed
    }

    fn fit_audio_channel_maps(&mut self, probed: &BTreeMap<Id, MediaInfo>) -> bool {
        let mut changed = false;
        for m in self.media.iter_mut() {
            let path = m.path.clone();
            let Some(item_info) = m.info.as_mut() else { continue };
            let Some(info) = probed.get(&m.id) else { continue };
            let before = item_info.audio.clone();
            let Some(map) = before.as_ref().and_then(|a| a.channel_map.clone()) else {
                if before != info.audio {
                    item_info.audio = info.audio.clone();
                    changed = true;
                }
                continue;
            };
            if let Some(mut a) = info.audio.clone() {
                a.channel_map = map.stored(&a, &path);
                item_info.audio = Some(a);
            } else if let Some(a) = item_info.audio.as_mut() {
                a.channel_map = None;
            }
            if item_info.audio != before {
                changed = true;
            }
        }
        changed
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{MediaFingerprint, MediaRef, Subclip};
    use sq_core_time::{Time, TimeRange};

    type Map = AudioChannelMap;

    fn t(n: i64) -> Time {
        Time::new(n, 1)
    }

    fn audio(channels: i64, codec: &str) -> AudioTrackInfo {
        AudioTrackInfo {
            sample_rate: 48_000,
            channels,
            codec: codec.to_string(),
            channel_map: None,
            first_track_channels: None,
        }
    }

    fn media_info(audio: Option<AudioTrackInfo>) -> MediaInfo {
        let json = serde_json::json!({"duration": {"value": 10, "timescale": 1}});
        let mut i: MediaInfo = serde_json::from_value(json).unwrap_or_else(|e| panic!("{e}"));
        i.audio = audio;
        i
    }

    fn project_with(path: &str, a: AudioTrackInfo) -> (Project, Id) {
        let mut r = MediaRef::new(Id::from_u128(1), "a", path, MediaFingerprint::new(1));
        r.duration = Some(t(10));
        r.info = Some(media_info(Some(a)));
        (Project::new(Id::from_u128(100), "P", vec![r], vec![]), Id::from_u128(1))
    }

    fn mxf(channels: i64, map: Option<Map>) -> (Project, Id) {
        let mut a = audio(channels, "PCM");
        a.channel_map = map;
        project_with("/a.mxf", a)
    }

    fn plain(channels: i64, path: &str, codec: &str) -> (Project, Id) {
        project_with(path, audio(channels, codec))
    }

    #[test]
    fn maps_are_normalized_and_validated() {
        assert!(Map::new(&[], &[]).is_none());
        assert!(Map::new(&[-1], &[0]).is_none());
        assert!(Map::new(&(0..17).collect::<Vec<_>>(), &[0]).is_none());
        let m = Map::new(&[3, 1, 3], &[2]);
        assert!(m.as_ref().map(|m| (m.left().to_vec(), m.right().to_vec())) == Some((vec![1, 3], vec![2])));
        assert!(Map::stereo(1, 1).is_none() && Map::dual_mono(2, 2).is_none());
    }

    #[test]
    fn presets_layouts_and_levels() {
        let mono = Map::mono(2).unwrap_or_else(|| panic!("mono"));
        assert!(mono.layout() == AudioChannelLayout::Mono && mono.is_centered() && mono.gain() == 1.0);
        assert_eq!(mono.label(), "Mono: 3");
        let stereo = Map::stereo(0, 1).unwrap_or_else(|| panic!("stereo"));
        assert!(stereo.layout() == AudioChannelLayout::Stereo && !stereo.is_centered() && stereo.gain() == 1.0);
        assert_eq!(stereo.label(), "Stereo: 1 + 2");
        let dual = Map::dual_mono(2, 3).unwrap_or_else(|| panic!("dual"));
        assert!(dual.layout() == AudioChannelLayout::DualMono && dual.is_centered());
        assert_eq!(dual.label(), "Dual Mono: 3 + 4");
        assert!((dual.gain() - 0.5_f32.sqrt()).abs() < 1e-6); // -3 dB each
        let wide = Map::new(&[0, 2], &[1, 3]).unwrap_or_else(|| panic!("wide"));
        assert!(wide.layout() == AudioChannelLayout::Custom && wide.gain() == 1.0 && wide.highest_channel() == 3);
        // One side only is a valid map (a channel on the left, nothing on the right).
        assert_eq!(Map::new(&[0], &[]).map(|m| m.layout()), Some(AudioChannelLayout::Custom));
    }

    #[test]
    fn fitting_drops_channels_the_file_lacks() {
        assert_eq!(Map::dual_mono(0, 3).and_then(|m| m.fitting(2)), Map::mono(0));
        assert_eq!(Map::stereo(2, 3).and_then(|m| m.fitting(2)), None);
        assert_eq!(Map::stereo(0, 1).and_then(|m| m.fitting(4)), Map::stereo(0, 1));
        // A side that was in use never ends up empty: the whole map is gone instead.
        assert_eq!(Map::stereo(1, 2).and_then(|m| m.fitting(2)), None);
        assert_eq!(Map::stereo(3, 0).and_then(|m| m.fitting(2)), None);
        assert_eq!(Map::new(&[1, 2], &[3]).and_then(|m| m.fitting(3)), None);
        // A side that was empty by choice stays empty.
        assert_eq!(Map::new(&[0, 3], &[]).and_then(|m| m.fitting(2)), Map::new(&[0], &[]));
    }

    #[test]
    fn a_choice_that_names_the_file_layout_is_no_choice() {
        // An ordinary stereo file: Stereo 1 + 2 is what it plays anyway. Nothing stored.
        let (mut p, id) = plain(2, "/a.mov", "aac ");
        assert!(!p.set_audio_channel_map(Map::stereo(0, 1).as_ref(), id));
        assert_eq!(p.audio_channel_map(id), None);
        // Choosing it while another map is set goes back to File Layout.
        p.set_audio_channel_map(Map::stereo(1, 0).as_ref(), id);
        assert_eq!(p.audio_channel_map(id), Map::stereo(1, 0));
        assert!(p.set_audio_channel_map(Map::stereo(0, 1).as_ref(), id));
        assert_eq!(p.audio_channel_map(id), None);
        // A real change on the same file is stored.
        p.set_audio_channel_map(Map::dual_mono(0, 1).as_ref(), id);
        assert_eq!(p.audio_channel_map(id), Map::dual_mono(0, 1));

        let (mut m, mid) = plain(1, "/a.mov", "aac ");
        assert!(!m.set_audio_channel_map(Map::mono(0).as_ref(), mid));
        assert_eq!(m.audio_channel_map(mid), None);
    }

    #[test]
    fn two_mono_tracks_keep_stereo_as_a_real_map() {
        // Two mono audio tracks: 2 channels in all, but the file plays its first track (mono). Stereo 1 + 2 differs.
        let mut a = audio(2, "lpcm");
        a.first_track_channels = Some(1);
        let (mut p, id) = project_with("/a.mov", a.clone());
        assert_eq!(Map::file_layout(&a, "/a.mov"), Map::mono(0));
        assert!(p.set_audio_channel_map(Map::stereo(0, 1).as_ref(), id));
        assert_eq!(p.audio_channel_map(id), Map::stereo(0, 1));
        let first = p.media[0].info.as_ref().and_then(|i| i.audio.as_ref()).and_then(|a| a.first_track_channels);
        assert_eq!(first, Some(1));
        // One stereo track: the equal map is still dropped.
        let (mut s, sid) = plain(2, "/a.mov", "aac ");
        assert!(!s.set_audio_channel_map(Map::stereo(0, 1).as_ref(), sid));
        assert_eq!(s.audio_channel_map(sid), None);
    }

    #[test]
    fn the_file_layout_is_decided_from_the_item_not_the_channel_count() {
        // An MXF with two mono tracks plays them in the center: Stereo 1 + 2 is a real change there.
        let (mut p, id) = mxf(2, None);
        assert!(p.set_audio_channel_map(Map::stereo(0, 1).as_ref(), id));
        assert_eq!(p.audio_channel_map(id), Map::stereo(0, 1));
        // Its own layout is Dual Mono 1 + 2, also with more tracks.
        p.set_audio_channel_map(Map::dual_mono(0, 1).as_ref(), id);
        assert_eq!(p.audio_channel_map(id), None);
        let (mut q, qid) = mxf(4, None);
        q.set_audio_channel_map(Map::dual_mono(0, 1).as_ref(), qid);
        assert_eq!(q.audio_channel_map(qid), None);
        q.set_audio_channel_map(Map::stereo(0, 1).as_ref(), qid);
        assert_eq!(q.audio_channel_map(qid), Map::stereo(0, 1));
        // Six channels are the reader's own mix: no map names it.
        let (mut s, sid) = plain(6, "/a.mov", "aac ");
        s.set_audio_channel_map(Map::stereo(0, 1).as_ref(), sid);
        assert_eq!(s.audio_channel_map(sid), Map::stereo(0, 1));
        // Layout not known (PCM outside an MXF or WebM, an .mxf probed by another reader): the map is kept.
        let (mut u, uid) = plain(2, "/a.dat", "PCM");
        u.set_audio_channel_map(Map::stereo(0, 1).as_ref(), uid);
        assert_eq!(u.audio_channel_map(uid), Map::stereo(0, 1));
        let (mut x, xid) = plain(2, "/a.MXF", "lpcm");
        x.set_audio_channel_map(Map::stereo(0, 1).as_ref(), xid);
        assert_eq!(x.audio_channel_map(xid), Map::stereo(0, 1));
        x.set_audio_channel_map(Map::dual_mono(0, 1).as_ref(), xid);
        assert_eq!(x.audio_channel_map(xid), Map::dual_mono(0, 1));
        let (mut w, wid) = plain(2, "/a.webm", "PCM");
        w.set_audio_channel_map(Map::stereo(0, 1).as_ref(), wid);
        assert_eq!(w.audio_channel_map(wid), None);
    }

    #[test]
    fn relink_fits_the_map_to_the_probed_file() {
        let info = |channels: Option<i64>| media_info(channels.map(|c| audio(c, "PCM")));
        let chan = |p: &Project, id| {
            p.media(id).and_then(|m| m.info.as_ref()).and_then(|i| i.audio.as_ref()).map(|a| a.channels)
        };

        let (mut p, id) = mxf(4, Map::mono(3));
        let probed: BTreeMap<Id, MediaInfo> = [(id, info(Some(2)))].into();
        assert!(p.fit_audio_channel_maps(&probed));
        assert_eq!(p.audio_channel_map(id), None);
        assert_eq!(chan(&p, id), Some(2)); // the menu offers the new file's channels

        let (mut q, qid) = mxf(4, Map::mono(3));
        q.fit_audio_channel_maps(&[(qid, info(Some(8)))].into());
        assert_eq!(q.audio_channel_map(qid), Map::mono(3));
        assert_eq!(chan(&q, qid), Some(8));

        let (mut n, nid) = mxf(4, Map::mono(3));
        assert_eq!(n.audio_channel_map(nid), Map::mono(3));
        assert!(n.fit_audio_channel_maps(&[(nid, info(None))].into())); // the new file has no sound
        assert_eq!(n.audio_channel_map(nid), None);
        assert!(n.fit_audio_channel_maps(&[(nid, info(Some(2)))].into())); // no map: the sound info follows the file
        assert_eq!(chan(&n, nid), Some(2));
        assert!(!n.fit_audio_channel_maps(&[(nid, info(Some(2)))].into()));
    }

    #[test]
    fn setting_the_map_changes_the_item_and_nothing_else() {
        let (mut p, id) = mxf(4, None);
        assert_eq!(p.audio_channel_map(id), None);
        assert!(p.set_audio_channel_map(Map::mono(0).as_ref(), id));
        assert_eq!(p.audio_channel_map(id), Map::mono(0));
        assert!(!p.set_audio_channel_map(Map::mono(0).as_ref(), id)); // same again: no change, no undo step
        assert!(p.set_audio_channel_map(None, id));
        assert_eq!(p.audio_channel_map(id), None);
        assert!(!p.set_audio_channel_map(None, id));
    }

    #[test]
    fn channels_the_file_lacks_are_dropped_or_refused() {
        let (mut p, id) = mxf(2, None);
        assert!(!p.set_audio_channel_map(Map::stereo(2, 3).as_ref(), id)); // none of them exists
        assert_eq!(p.audio_channel_map(id), None);
        assert!(p.set_audio_channel_map(Map::dual_mono(1, 5).as_ref(), id));
        assert_eq!(p.audio_channel_map(id), Map::mono(1));
        assert!(!p.set_audio_channel_map(Map::mono(0).as_ref(), Id::from_u128(77)));
    }

    #[test]
    fn a_webm_offers_two_channels_at_most() {
        let six = audio(6, "PCM");
        assert_eq!(six.mappable_channels("/a.webm"), 2);
        assert_eq!(six.mappable_channels("/a.MKV"), 2);
        assert_eq!(six.mappable_channels("/a.mov"), 6);
        assert_eq!(Map::file_layout(&six, "/a.webm"), Map::stereo(0, 1));
        assert_eq!(Map::file_layout(&six, "/a.mov"), None);
        // A map above the reader's two channels is fitted down or refused, never stored as is.
        assert_eq!(Map::mono(4).and_then(|m| m.stored(&six, "/a.webm")), None);
        assert_eq!(Map::dual_mono(1, 4).and_then(|m| m.stored(&six, "/a.webm")), Map::mono(1));
        assert_eq!(Map::mono(4).and_then(|m| m.stored(&six, "/a.mov")), Map::mono(4));
        let (mut p, id) = mxf(6, None);
        p.media[0].path = "/a.webm".to_string();
        assert!(!p.set_audio_channel_map(Map::mono(4).as_ref(), id));
        assert!(p.set_audio_channel_map(Map::mono(1).as_ref(), id));
        assert_eq!(p.audio_channel_map(id), Map::mono(1));
    }

    #[test]
    fn media_without_audio_is_refused() {
        let mut r = MediaRef::new(Id::from_u128(1), "v.mov", "/v.mov", MediaFingerprint::new(1));
        r.info = Some(media_info(None));
        let mut p = Project::new(Id::from_u128(100), "P", vec![r], vec![]);
        assert!(!p.set_audio_channel_map(Map::mono(0).as_ref(), Id::from_u128(1)));
    }

    #[test]
    fn a_subclip_shares_its_files_setting() {
        let (mut p, id) = mxf(4, None);
        let mut sub = p.media[0].clone();
        sub.id = Id::from_u128(2);
        sub.subclip = Some(Subclip { parent: id, range: TimeRange::new(Time::ZERO, t(1)) });
        p.media.push(sub);
        assert!(p.set_audio_channel_map(Map::mono(1).as_ref(), Id::from_u128(2)));
        assert_eq!(p.audio_channel_map(id), Map::mono(1));
        assert_eq!(p.audio_channel_map(Id::from_u128(2)), Map::mono(1));
    }
}
