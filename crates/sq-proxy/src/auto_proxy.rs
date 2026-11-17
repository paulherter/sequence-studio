// Swift: AutoProxy.swift (`UserDefaults` is the injected `ProxyDefaults`; `MachineProfile.current` and the volume sizes
// need the platform layer and are not ported, see NOTES.md)
//! Automatic proxy generation: which sources get a background proxy, and where the setting lives.

use crate::model::ProxyKind;
use crate::proxy_policy::{ProxyDecision, ProxyPolicy, SkipReason, SourceSeekInfo};
use sq_core_model::VideoTrackInfo;
use sq_core_project::work_limits::MachineResources;
use sq_core_time::{Id, Time};

/// Automatic proxy generation. Default `Auto`: heavy long-GOP sources (and, on a weak machine, any long-GOP source
/// above 1440p) get a background proxy that the monitor uses while scrubbing. Export never reads proxies.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ProxyMode {
    /// Only where scrubbing would be slow.
    Auto,
    /// Every long-GOP source.
    Always,
    /// None.
    Off,
}

impl ProxyMode {
    /// Swift `CaseIterable.allCases`.
    pub const ALL: [ProxyMode; 3] = [ProxyMode::Auto, ProxyMode::Always, ProxyMode::Off];

    /// The Swift raw value.
    pub fn raw_value(self) -> &'static str {
        match self {
            ProxyMode::Auto => "auto",
            ProxyMode::Always => "always",
            ProxyMode::Off => "off",
        }
    }

    /// The case with this raw value.
    pub fn from_raw(raw: &str) -> Option<ProxyMode> {
        Self::ALL.into_iter().find(|m| m.raw_value() == raw)
    }
}

/// Whether playback (not only scrubbing) uses ready proxies. `Auto`: only on a weak machine.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ProxyPlaybackMode {
    /// Follows the machine.
    Auto,
    /// Always.
    On,
    /// Never.
    Off,
}

impl ProxyPlaybackMode {
    /// Swift `CaseIterable.allCases`.
    pub const ALL: [ProxyPlaybackMode; 3] = [ProxyPlaybackMode::Auto, ProxyPlaybackMode::On, ProxyPlaybackMode::Off];

    /// The Swift raw value.
    pub fn raw_value(self) -> &'static str {
        match self {
            ProxyPlaybackMode::Auto => "auto",
            ProxyPlaybackMode::On => "on",
            ProxyPlaybackMode::Off => "off",
        }
    }

    /// The case with this raw value.
    pub fn from_raw(raw: &str) -> Option<ProxyPlaybackMode> {
        Self::ALL.into_iter().find(|m| m.raw_value() == raw)
    }
}

/// What the rule needs to know about this machine.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct MachineProfile {
    /// Physical memory.
    pub memory_bytes: u64,
    /// Active cores.
    pub cores: i64,
    /// Apple silicon (not Intel).
    pub is_apple_silicon: bool,
}

impl MachineProfile {
    /// This machine; `SQ_RAM_GB` / `SQ_CORES` read through `environment` simulate a smaller one (as for `MachineResources`).
    pub fn current_with(
        environment: impl Fn(&str) -> Option<String>,
        physical_memory: u64,
        cores: i64,
        is_apple_silicon: bool,
    ) -> MachineProfile {
        let r = MachineResources::current(environment, physical_memory, cores, !is_apple_silicon);
        MachineProfile { memory_bytes: r.memory_bytes, cores: r.cores, is_apple_silicon }
    }

    /// Intel, under 16 GB or under 8 cores: 4K long-GOP decoding is slow here.
    pub fn is_weak(&self) -> bool {
        !self.is_apple_silicon || self.memory_bytes < 16 << 30 || self.cores < 8
    }

    /// 8 GB or less: the frame cache is 1/6 of RAM, so 10-bit / 4:2:2 GOPs from 1440p up do not fit.
    pub fn is_low_memory(&self) -> bool {
        self.memory_bytes <= 8 << 30
    }
}

const UHD_PIXELS: i64 = 3840 * 2160;
const QHD_PIXELS: i64 = 2560 * 1440;
const HD_PIXELS: i64 = 1920 * 1080;

/// Which sources get a background proxy (mode x source x machine).
pub struct AutoProxyRule;

impl AutoProxyRule {
    /// Long-GOP decides whether seeking is slow at all (`ProxyPolicy`); size, bit depth and chroma decide whether it is
    /// slow enough to be worth a background transcode.
    /// `software_decode`: this machine has no hardware decoder for the source. Software decode costs ~28 ms per 4K
    /// H.264 frame on one core, so a long-GOP source from 1080p up gets a proxy on every machine.
    pub fn decide(
        seek: &SourceSeekInfo,
        video: Option<&VideoTrackInfo>,
        mode: ProxyMode,
        machine: &MachineProfile,
        software_decode: bool,
        policy: &ProxyPolicy,
    ) -> ProxyDecision {
        if mode == ProxyMode::Off {
            return ProxyDecision::Skip(SkipReason::Disabled);
        }
        // A proxy of an interlaced source is progressive; with Deinterlace off the fields are wanted and playback reads
        // the original, so the proxy would never be used.
        if let Some(v) = video
            && v.is_interlaced()
            && v.deinterlace_off
        {
            return ProxyDecision::Skip(SkipReason::KeepsFields);
        }
        let gop = policy.decide(seek);
        let pixels = video.map_or(0, |v| v.width * v.height);
        // Intra-only media (ProRes) seeks fast, but without a hardware decoder every frame costs a full software decode:
        // a half-size proxy plays for a fraction of it.
        let heavy_intra =
            software_decode && pixels * 10 >= HD_PIXELS * 9 && gop == ProxyDecision::Skip(SkipReason::IntraOnlyCodec);
        if !(gop.needs_proxy() || heavy_intra) {
            return gop;
        }
        let kind = if pixels >= 2 * UHD_PIXELS { ProxyKind::ProxyQuarter } else { ProxyKind::ProxyHalf };
        if mode == ProxyMode::Always {
            return ProxyDecision::NeedsProxy(kind);
        }
        let Some(v) = video else { return ProxyDecision::Skip(SkipReason::Unknown) };
        let rich = v.bit_depth > 8 || v.chroma != "4:2:0";
        let heavy = pixels >= 2 * UHD_PIXELS || (pixels * 10 >= UHD_PIXELS * 9 && rich);
        let weak_needs = machine.is_weak() && pixels > QHD_PIXELS;
        let low_memory_needs = machine.is_low_memory() && rich && pixels >= QHD_PIXELS;
        let software_needs = software_decode && pixels * 10 >= HD_PIXELS * 9;
        if heavy || weak_needs || low_memory_needs || software_needs {
            ProxyDecision::NeedsProxy(kind)
        } else {
            ProxyDecision::Skip(SkipReason::LightSource)
        }
    }

    /// Queue rank (lower runs first) of a media at timeline rank `rank`: software-decoded media move ahead of all others
    /// (`media_count` = number of ranked media) and keep their order among themselves; unranked (`i64::MAX`) stays last.
    pub fn rank(rank: i64, software_decode: bool, media_count: i64) -> i64 {
        if software_decode && rank != i64::MAX { rank - media_count } else { rank }
    }

    /// Whether playback reads proxies under `mode`.
    pub fn uses_proxies_for_playback(mode: ProxyPlaybackMode, machine: &MachineProfile) -> bool {
        match mode {
            ProxyPlaybackMode::Auto => machine.is_weak(),
            ProxyPlaybackMode::On => true,
            ProxyPlaybackMode::Off => false,
        }
    }
}

/// Background proxies never fill the disk: after the estimated proxy the volume keeps max(15 GB, 10 % of its size, at
/// most 30 GB) free. Unknown sizes allow the job.
pub struct ProxyDiskGuard;

impl ProxyDiskGuard {
    /// The smallest reserve.
    pub const FLOOR_BYTES: i64 = 15 << 30;

    /// Whether a proxy of `estimated_bytes` still leaves the reserve free.
    pub fn allows(estimated_bytes: i64, free_bytes: Option<i64>, volume_bytes: Option<i64>) -> bool {
        let Some(free) = free_bytes else { return true };
        let reserve = Self::FLOOR_BYTES.max((volume_bytes.unwrap_or(0) / 10).min(30 << 30));
        free - estimated_bytes.max(0) >= reserve
    }
}

/// Rough size of a proxy: ProRes 422 Proxy is about 45 Mbit/s at 1920x1080, 29.97 fps; scales with pixels and rate.
pub struct ProxySizeEstimate;

impl ProxySizeEstimate {
    const BITS_PER_SECOND_1080P30: f64 = 45e6;

    /// Estimated file size in bytes.
    pub fn bytes(kind: ProxyKind, width: i64, height: i64, frame_duration: Time, duration: Time) -> i64 {
        let d = kind.scale_divisor();
        let pixels = ((width / d).max(1) * (height / d).max(1)) as f64;
        let fps = if frame_duration > Time::ZERO {
            frame_duration.timescale() as f64 / frame_duration.value() as f64
        } else {
            30.0
        };
        let seconds = duration.value() as f64 / duration.timescale().max(1) as f64;
        // ProRes 422 ~147 Mbit/s
        let rate = if kind == ProxyKind::Optimized {
            Self::BITS_PER_SECOND_1080P30 * 3.3
        } else {
            Self::BITS_PER_SECOND_1080P30
        };
        // `as` saturates; the estimate is finite for any real clip.
        (rate / 8.0 * pixels / (1920.0 * 1080.0) * fps / 30.0 * seconds.max(0.0)) as i64
    }
}

/// Where `ProxySettingsStore` keeps its values: the app's settings store (Swift `UserDefaults`).
pub trait ProxyDefaults {
    /// The stored text; `None` when the key is unset or holds something else.
    fn string(&self, key: &str) -> Option<String>;
    /// The stored flag; `false` when unset.
    fn bool(&self, key: &str) -> bool;
    /// Stores text.
    fn set_string(&mut self, key: &str, value: &str);
    /// Stores a flag.
    fn set_bool(&mut self, key: &str, value: bool);
    /// Removes a key.
    fn remove(&mut self, key: &str);
}

/// The proxy settings (`sq.proxy.*`): an app-wide mode, an optional per-project override (keyed by the project's ID, so
/// the project file stays unchanged) and the playback mode. Unknown values read as `Auto`.
pub struct ProxySettingsStore<D: ProxyDefaults> {
    defaults: D,
}

impl<D: ProxyDefaults> ProxySettingsStore<D> {
    /// Key of the app-wide mode.
    pub const MODE_KEY: &'static str = "sq.proxy.mode";
    /// Key of the playback mode.
    pub const PLAYBACK_KEY: &'static str = "sq.proxy.playback";
    /// Key of "use proxies for export".
    pub const EXPORT_KEY: &'static str = "sq.proxy.export";

    /// A store over `defaults`.
    pub fn new(defaults: D) -> ProxySettingsStore<D> {
        ProxySettingsStore { defaults }
    }

    /// Key of a project's override.
    pub fn project_mode_key(project: Id) -> String {
        format!("{}.{}", Self::MODE_KEY, project)
    }

    /// The project's override if set, else the app setting.
    pub fn mode(&self, project: Option<Id>) -> ProxyMode {
        if let Some(project) = project
            && let Some(m) =
                self.defaults.string(&Self::project_mode_key(project)).and_then(|s| ProxyMode::from_raw(&s))
        {
            return m;
        }
        self.defaults.string(Self::MODE_KEY).and_then(|s| ProxyMode::from_raw(&s)).unwrap_or(ProxyMode::Auto)
    }

    /// `project` `None` = the app setting; with a project, `None` removes its override.
    pub fn set_mode(&mut self, mode: Option<ProxyMode>, project: Option<Id>) {
        let key = project.map_or_else(|| Self::MODE_KEY.to_string(), Self::project_mode_key);
        match mode {
            Some(m) => self.defaults.set_string(&key, m.raw_value()),
            None => self.defaults.remove(&key),
        }
    }

    /// Global "use proxies for export": the render reads ready proxies instead of the originals (fast drafts, lower
    /// quality). Off by default; the export dialog and presets are unchanged.
    pub fn use_proxies_for_export(&self) -> bool {
        self.defaults.bool(Self::EXPORT_KEY)
    }

    /// Sets "use proxies for export".
    pub fn set_use_proxies_for_export(&mut self, on: bool) {
        self.defaults.set_bool(Self::EXPORT_KEY, on);
    }

    /// The playback mode.
    pub fn playback(&self) -> ProxyPlaybackMode {
        self.defaults
            .string(Self::PLAYBACK_KEY)
            .and_then(|s| ProxyPlaybackMode::from_raw(&s))
            .unwrap_or(ProxyPlaybackMode::Auto)
    }

    /// Sets the playback mode.
    pub fn set_playback(&mut self, mode: ProxyPlaybackMode) {
        self.defaults.set_string(Self::PLAYBACK_KEY, mode.raw_value());
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    const G: i64 = 1 << 30;

    fn long_gop() -> SourceSeekInfo {
        SourceSeekInfo::new("avc1", Some(60))
    }
    fn short_gop() -> SourceSeekInfo {
        SourceSeekInfo::new("avc1", Some(1))
    }
    fn prores() -> SourceSeekInfo {
        SourceSeekInfo::new("apcn", Some(1))
    }

    fn video(w: i64, h: i64, bits: i64, chroma: &str) -> VideoTrackInfo {
        serde_json::from_value(serde_json::json!({
            "width": w, "height": h, "codec": "avc1", "bitDepth": bits, "chroma": chroma,
            "nominalFrameDuration": { "value": 1001, "timescale": 30000 }, "isVariableFrameRate": false
        }))
        .unwrap()
    }
    fn v8(w: i64, h: i64) -> VideoTrackInfo {
        video(w, h, 8, "4:2:0")
    }

    fn strong() -> MachineProfile {
        MachineProfile { memory_bytes: 32 << 30, cores: 12, is_apple_silicon: true }
    }
    fn weak() -> MachineProfile {
        MachineProfile { memory_bytes: 8 << 30, cores: 8, is_apple_silicon: true }
    }

    fn decide(seek: &SourceSeekInfo, v: Option<&VideoTrackInfo>, mode: ProxyMode, m: &MachineProfile) -> ProxyDecision {
        AutoProxyRule::decide(seek, v, mode, m, false, &ProxyPolicy::default())
    }
    fn decide_sw(
        seek: &SourceSeekInfo,
        v: &VideoTrackInfo,
        mode: ProxyMode,
        m: &MachineProfile,
        sw: bool,
    ) -> ProxyDecision {
        AutoProxyRule::decide(seek, Some(v), mode, m, sw, &ProxyPolicy::default())
    }

    const HALF: ProxyDecision = ProxyDecision::NeedsProxy(ProxyKind::ProxyHalf);
    const LIGHT: ProxyDecision = ProxyDecision::Skip(SkipReason::LightSource);

    /// Deinterlace off: the fields are wanted, a proxy has none and playback never reads it, so none is made.
    #[test]
    fn interlaced_with_deinterlace_off_gets_no_proxy() {
        let mut v: VideoTrackInfo = {
            let mut j = serde_json::to_value(video(3840, 2160, 10, "4:2:2")).unwrap();
            j["fieldOrder"] = serde_json::json!("topFirst");
            serde_json::from_value(j).unwrap()
        };
        assert!(decide(&long_gop(), Some(&v), ProxyMode::Always, &strong()).needs_proxy());
        v.deinterlace_off = true;
        let keeps = ProxyDecision::Skip(SkipReason::KeepsFields);
        assert_eq!(decide(&long_gop(), Some(&v), ProxyMode::Always, &strong()), keeps);
        assert_eq!(decide(&long_gop(), Some(&v), ProxyMode::Auto, &strong()), keeps);
        assert_eq!(decide(&long_gop(), Some(&v), ProxyMode::Off, &strong()), ProxyDecision::Skip(SkipReason::Disabled));
        v.field_order = None; // the switch means nothing on progressive media
        assert!(decide(&long_gop(), Some(&v), ProxyMode::Always, &strong()).needs_proxy());
    }

    /// The Sony case that missed the 50 ms scrub target: 4K long-GOP 10-bit 4:2:2.
    #[test]
    fn sony_4k_10_bit_422_gets_a_half_proxy_on_every_machine() {
        let sony = video(3840, 2160, 10, "4:2:2");
        assert_eq!(decide(&long_gop(), Some(&sony), ProxyMode::Auto, &strong()), HALF);
        assert_eq!(decide(&long_gop(), Some(&sony), ProxyMode::Auto, &weak()), HALF);
    }

    #[test]
    fn light_8_bit_420_sources_only_on_a_weak_machine() {
        let uhd8 = v8(3840, 2160);
        assert_eq!(decide(&long_gop(), Some(&uhd8), ProxyMode::Auto, &strong()), LIGHT);
        assert_eq!(decide(&long_gop(), Some(&uhd8), ProxyMode::Auto, &weak()), HALF);
        let hd = v8(1920, 1080);
        assert_eq!(decide(&long_gop(), Some(&hd), ProxyMode::Auto, &weak()), LIGHT);
        assert_eq!(decide(&long_gop(), Some(&hd), ProxyMode::Auto, &strong()), LIGHT);
    }

    /// ProRes seeks fast, but a software decode of every frame is what loads the cores in playback.
    #[test]
    fn software_decoded_prores_from_1080p_gets_a_proxy() {
        let hd = v8(1920, 1080);
        let intra = ProxyDecision::Skip(SkipReason::IntraOnlyCodec);
        assert_eq!(decide_sw(&prores(), &hd, ProxyMode::Auto, &strong(), true), HALF);
        assert_eq!(decide_sw(&prores(), &hd, ProxyMode::Auto, &strong(), false), intra);
        assert_eq!(decide_sw(&prores(), &v8(1280, 720), ProxyMode::Auto, &strong(), true), intra);
        assert_eq!(
            decide_sw(&prores(), &hd, ProxyMode::Off, &strong(), true),
            ProxyDecision::Skip(SkipReason::Disabled)
        );
    }

    /// No hardware decoder for the source: from 1080p on a long GOP gets a proxy on every machine; below 1080p and
    /// short GOPs stay as before.
    #[test]
    fn software_decoded_long_gop_from_1080p_gets_a_proxy() {
        let (hd, uhd8) = (v8(1920, 1080), v8(3840, 2160));
        assert_eq!(decide_sw(&long_gop(), &hd, ProxyMode::Auto, &strong(), true), HALF);
        assert_eq!(decide_sw(&long_gop(), &uhd8, ProxyMode::Auto, &strong(), true), HALF);
        assert_eq!(decide_sw(&long_gop(), &v8(1280, 720), ProxyMode::Auto, &strong(), true), LIGHT);
        assert!(!decide_sw(&short_gop(), &hd, ProxyMode::Auto, &strong(), true).needs_proxy());
        assert_eq!(
            decide_sw(&long_gop(), &hd, ProxyMode::Off, &strong(), true),
            ProxyDecision::Skip(SkipReason::Disabled)
        );
        assert_eq!(decide_sw(&long_gop(), &hd, ProxyMode::Auto, &strong(), false), LIGHT);
    }

    /// Software-decoded media go to the front of the proxy queue, in their timeline order.
    #[test]
    fn software_decoded_media_rank_first() {
        assert!(AutoProxyRule::rank(3, true, 10) < AutoProxyRule::rank(0, false, 10));
        assert!(AutoProxyRule::rank(1, true, 10) < AutoProxyRule::rank(3, true, 10));
        assert_eq!(AutoProxyRule::rank(4, false, 10), 4);
        assert_eq!(AutoProxyRule::rank(i64::MAX, true, 10), i64::MAX); // unranked stays last
    }

    #[test]
    fn eight_k_gets_a_quarter_proxy() {
        let d = decide(&long_gop(), Some(&v8(7680, 4320)), ProxyMode::Auto, &strong());
        assert_eq!(d, ProxyDecision::NeedsProxy(ProxyKind::ProxyQuarter));
    }

    #[test]
    fn intra_and_short_gop_never_need_one() {
        let big = video(3840, 2160, 10, "4:2:2");
        for mode in ProxyMode::ALL {
            assert!(!decide(&prores(), Some(&big), mode, &weak()).needs_proxy());
            assert!(!decide(&short_gop(), Some(&big), mode, &weak()).needs_proxy());
        }
    }

    #[test]
    fn always_proxies_every_long_gop_source_and_off_none() {
        assert_eq!(decide(&long_gop(), Some(&v8(1920, 1080)), ProxyMode::Always, &strong()), HALF);
        assert_eq!(decide(&long_gop(), None, ProxyMode::Always, &strong()), HALF);
        let off = decide(&long_gop(), Some(&video(3840, 2160, 10, "4:2:0")), ProxyMode::Off, &weak());
        assert_eq!(off, ProxyDecision::Skip(SkipReason::Disabled));
    }

    /// Without probed track info Auto stays conservative (only the GOP is known).
    #[test]
    fn unknown_track_info_is_skipped_in_auto() {
        assert_eq!(decide(&long_gop(), None, ProxyMode::Auto, &weak()), ProxyDecision::Skip(SkipReason::Unknown));
    }

    #[test]
    fn machine_weakness() {
        assert!(!strong().is_weak());
        assert!(weak().is_weak());
        assert!(MachineProfile { memory_bytes: 64 << 30, cores: 16, is_apple_silicon: false }.is_weak());
        assert!(MachineProfile { memory_bytes: 16 << 30, cores: 4, is_apple_silicon: true }.is_weak());
    }

    /// On 8 GB a 1440p 10-bit or 4:2:2 long-GOP source is proxied too; a 16 GB weak machine and 8-bit 1440p stay on the original.
    #[test]
    fn low_memory_machines_also_proxy_rich_qhd() {
        let qhd10 = video(2560, 1440, 10, "4:2:2");
        let mid = MachineProfile { memory_bytes: 16 << 30, cores: 4, is_apple_silicon: true };
        assert!(weak().is_low_memory() && !mid.is_low_memory());
        assert_eq!(decide(&long_gop(), Some(&qhd10), ProxyMode::Auto, &weak()), HALF);
        assert_eq!(decide(&long_gop(), Some(&qhd10), ProxyMode::Auto, &mid), LIGHT);
        assert_eq!(decide(&long_gop(), Some(&v8(2560, 1440)), ProxyMode::Auto, &weak()), LIGHT);
        assert_eq!(decide(&long_gop(), Some(&video(1920, 1080, 10, "4:2:2")), ProxyMode::Auto, &weak()), LIGHT);
    }

    /// `SQ_RAM_GB=8` makes this machine an 8 GB one for the rule as well.
    #[test]
    fn simulated_small_machine_is_weak() {
        let env = |k: &str| (k == "SQ_RAM_GB").then(|| "8".to_string());
        let m = MachineProfile::current_with(env, 32 << 30, 10, true);
        assert!(m.memory_bytes == 8 << 30 && m.is_weak() && m.is_low_memory());
        let real = MachineProfile::current_with(|_| None, 32 << 30, 10, true);
        assert!(!real.is_weak());
    }

    /// A background proxy never eats the disk: the volume keeps max(15 GB, 10 % up to 30 GB) free after the estimated proxy.
    #[test]
    fn disk_reserve_blocks_auto_proxies() {
        assert!(ProxyDiskGuard::allows(5 * G, Some(100 * G), Some(256 * G)));
        assert!(!ProxyDiskGuard::allows(5 * G, Some(30 * G), Some(256 * G))); // 25.6 GB reserve
        assert!(!ProxyDiskGuard::allows(G, Some(15 * G), Some(128 * G))); // 15 GB floor
        assert!(ProxyDiskGuard::allows(G, Some(17 * G), Some(128 * G)));
        assert!(ProxyDiskGuard::allows(G, Some(40 * G), Some(2048 * G))); // reserve capped at 30 GB
        assert!(ProxyDiskGuard::allows(G, None, None)); // unknown: allowed
    }

    /// ProRes 422 Proxy at 1080p30 is about 45 Mbit/s; the estimate scales with pixels and frame rate.
    #[test]
    fn proxy_size_estimate() {
        let hour = Time::new(3600, 1);
        let uhd30 = ProxySizeEstimate::bytes(ProxyKind::ProxyHalf, 3840, 2160, Time::new(1, 30), hour);
        let expected = 45e6 / 8.0 * 3600.0;
        assert!((uhd30 as f64 - expected).abs() / expected < 0.01);
        let uhd60 = ProxySizeEstimate::bytes(ProxyKind::ProxyHalf, 3840, 2160, Time::new(1, 60), hour);
        assert!((uhd60 as f64 / uhd30 as f64 - 2.0).abs() < 0.01);
        let q = ProxySizeEstimate::bytes(ProxyKind::ProxyQuarter, 7680, 4320, Time::new(1, 30), hour);
        assert!((q as f64 / uhd30 as f64 - 1.0).abs() < 0.01);
    }

    #[test]
    fn playback_proxies_follow_the_machine_in_auto() {
        assert!(AutoProxyRule::uses_proxies_for_playback(ProxyPlaybackMode::Auto, &weak()));
        assert!(!AutoProxyRule::uses_proxies_for_playback(ProxyPlaybackMode::Auto, &strong()));
        assert!(AutoProxyRule::uses_proxies_for_playback(ProxyPlaybackMode::On, &strong()));
        assert!(!AutoProxyRule::uses_proxies_for_playback(ProxyPlaybackMode::Off, &weak()));
    }

    #[derive(Default)]
    struct Mem(HashMap<String, String>);

    impl ProxyDefaults for Mem {
        fn string(&self, key: &str) -> Option<String> {
            self.0.get(key).filter(|v| !v.starts_with('#')).cloned()
        }
        fn bool(&self, key: &str) -> bool {
            self.0.get(key).is_some_and(|v| v == "true")
        }
        fn set_string(&mut self, key: &str, value: &str) {
            self.0.insert(key.to_string(), value.to_string());
        }
        fn set_bool(&mut self, key: &str, value: bool) {
            self.0.insert(key.to_string(), value.to_string());
        }
        fn remove(&mut self, key: &str) {
            self.0.remove(key);
        }
    }

    #[test]
    fn proxies_for_export_is_off_until_switched_on() {
        let mut s = ProxySettingsStore::new(Mem::default());
        assert!(!s.use_proxies_for_export());
        s.set_use_proxies_for_export(true);
        assert!(s.use_proxies_for_export());
    }

    #[test]
    fn defaults_to_auto() {
        let s = ProxySettingsStore::new(Mem::default());
        assert_eq!(s.mode(None), ProxyMode::Auto);
        assert_eq!(s.mode(Some(Id::fixed(1))), ProxyMode::Auto);
        assert_eq!(s.playback(), ProxyPlaybackMode::Auto);
    }

    #[test]
    fn project_override_wins_over_the_app_setting() {
        let mut s = ProxySettingsStore::new(Mem::default());
        let (p, other) = (Id::fixed(1), Id::fixed(2));
        s.set_mode(Some(ProxyMode::Off), None);
        s.set_mode(Some(ProxyMode::Always), Some(p));
        assert_eq!(s.defaults.string(&format!("sq.proxy.mode.{p}")).as_deref(), Some("always"));
        assert_eq!(s.mode(Some(p)), ProxyMode::Always);
        assert_eq!(s.mode(Some(other)), ProxyMode::Off);
        s.set_mode(None, Some(p)); // back to the app setting
        assert_eq!(s.mode(Some(p)), ProxyMode::Off);
        s.set_playback(ProxyPlaybackMode::On);
        assert_eq!(s.defaults.string("sq.proxy.playback").as_deref(), Some("on"));
        assert_eq!(s.playback(), ProxyPlaybackMode::On);
    }

    #[test]
    fn garbage_values_read_as_auto() {
        let mut d = Mem::default();
        d.set_string("sq.proxy.mode", "sometimes");
        d.set_string("sq.proxy.playback", "#42"); // a number is not text
        let s = ProxySettingsStore::new(d);
        assert_eq!(s.mode(None), ProxyMode::Auto);
        assert_eq!(s.playback(), ProxyPlaybackMode::Auto);
    }
}
