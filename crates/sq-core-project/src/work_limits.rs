// Swift: WorkLimits.swift (`AsyncLimiter` is async-only and waits for the executor crate; `WorkLimits.current` is
// `MachineResources::current` evaluated by the caller, since the process environment is not read here)
//! RAM and cores of this machine and the background-job limits derived from them.

use sq_core_edit::work_pools::WorkPools;

/// RAM and cores of this machine, or of a smaller one simulated with `SQ_RAM_GB` / `SQ_CORES` (both only ever lower the
/// real values), so tests and benches can play a MacBook Air 8 GB on any machine.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct MachineResources {
    /// Physical memory in bytes.
    pub memory_bytes: u64,
    /// Active cores, at least 1.
    pub cores: i64,
    /// Intel Mac (software decode and the media engine are far slower there).
    pub is_intel: bool,
}

impl MachineResources {
    /// One GiB in bytes.
    pub const GIB: u64 = 1 << 30;

    /// Cores below 1 become 1.
    pub fn new(memory_bytes: u64, cores: i64, is_intel: bool) -> MachineResources {
        MachineResources { memory_bytes, cores: cores.max(1), is_intel }
    }

    /// True when this build targets x86-64.
    pub const BUILD_IS_INTEL: bool = cfg!(target_arch = "x86_64");

    /// The real machine lowered by `SQ_RAM_GB` / `SQ_CORES` read through `environment` (junk or larger values are ignored).
    pub fn current(
        environment: impl Fn(&str) -> Option<String>,
        physical_memory: u64,
        cores: i64,
        is_intel: bool,
    ) -> MachineResources {
        let mut m = MachineResources::new(physical_memory, cores, is_intel);
        if let Some(v) = environment("SQ_RAM_GB").and_then(|s| s.parse::<f64>().ok())
            && v.is_finite()
            && v > 0.0
        {
            // `as` saturates for huge values; the min below caps it at the real memory.
            m.memory_bytes = physical_memory.min((v * Self::GIB as f64) as u64);
        }
        if let Some(c) = environment("SQ_CORES").and_then(|s| s.parse::<i64>().ok())
            && c > 0
        {
            m.cores = m.cores.min(c);
        }
        m
    }

    /// 8 GB or less (MacBook Air base models): the same line as `MemoryBudget.isLowMemory`.
    pub fn is_low_memory(&self) -> bool {
        self.memory_bytes <= 8 * Self::GIB
    }

    /// Intel, 8 GB or less, or 4 cores or fewer: software decode (and its frames) is capped on these.
    pub fn is_weak_for_decode(&self) -> bool {
        self.is_intel || self.is_low_memory() || self.cores <= 4
    }

    /// The limits derived for this machine.
    pub fn limits(&self) -> WorkLimits {
        WorkLimits::new(self)
    }
}

/// How many background media jobs of each kind run at once. Every lane is bounded by cores and narrower on
/// low-memory Macs.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct WorkLimits {
    /// Import: probe (+ copy into Files) of dropped files.
    pub import_probes: i64,
    /// Poster / thumbnail frame decodes (one decoder session each).
    pub poster_decodes: i64,
    /// Whole-file audio reads (waveform peaks, `BlockingLane.media`).
    pub waveform_reads: i64,
    /// Background proxy transcodes (ProRes encode + long-GOP decode on the media engine).
    pub proxy_transcodes: i64,
    /// Export render: media of one output frame decoded at once (stacked layers). 1 = serial.
    pub layer_decodes: i64,
    /// Mask tracking: long side of the analyzed frames (px). Optical flow costs grow with the area.
    pub mask_track_dimension: i64,
    /// Subject (Magic) mask: long side of the segmented frames and of the stored mattes (px).
    pub subject_mask_dimension: i64,
    /// Mask tracking backward: seconds of frames read and held at once before they are walked in reverse.
    pub mask_track_chunk_seconds: f64,
    /// Export render: submit frame N+1 to the GPU while frame N finishes and encodes (off on 8 GB Macs and one core).
    pub export_render_ahead: bool,
    /// Export: open VideoToolbox sessions over the whole export (all parallel segments).
    pub export_decoder_sessions: i64,
    /// Export: bytes of decoded frames kept, look-ahead included.
    pub export_frame_bytes: i64,
    /// Export: free intermediate textures kept by each export compositor (one per parallel segment).
    pub export_intermediate_pool_bytes: i64,
    /// Picture analyzes (Stabilizer: sequential decode + Vision registration), on their own threads.
    pub picture_analyses: i64,
    /// Preview: live software (non-hardware) decoder sessions at most; the idle ones are evicted first.
    pub software_decoder_sessions: i64,
    /// Preview: bytes of decoded frames the preview `DecoderBudget` keeps.
    pub preview_decoder_frame_bytes: i64,
    /// Preview: decode jobs of the playback `DecodeScheduler` running at once.
    pub preview_decode_jobs: i64,
    /// CPU pool (`WorkPools.cpu`): software-path jobs at once.
    pub cpu_fallback_jobs: i64,
    /// Preview: decode at half resolution at least (a stack of layers is viewed small anyway).
    pub reduced_preview_decode: bool,
    /// Project bin posters (`ProjectThumbnails`).
    pub poster_cache_bytes: i64,
    /// Color page clip frames (`ProjectThumbnails`).
    pub clip_frame_cache_bytes: i64,
    /// Decoded thumbnails of the bin's `Thumbnailer`.
    pub thumbnail_memory_bytes: i64,
    /// Resampled waveform peaks per zoom bucket (`WaveformCache`).
    pub waveform_cache_bytes: i64,
    /// Frame cache of both monitors together when the setting is Auto: 1/6 of RAM on 8 GB Macs and smaller, else 1/4, at most 8 GB.
    pub frame_cache_bytes: i64,
    /// Free intermediate textures the playback compositor keeps: RAM / 32, between 128 MB and 1 GB.
    pub intermediate_pool_bytes: i64,
}

fn to_int(v: u64) -> i64 {
    i64::try_from(v).unwrap_or(i64::MAX)
}

impl WorkLimits {
    /// Seconds one frame's object segmentation may take before its request is given up.
    pub const SUBJECT_FRAME_DEADLINE: f64 = 8.0;

    /// Seconds a frame read on the frame lane may go without a sign of life before it counts as hung.
    pub const FRAME_WORK_STALL_SECONDS: f64 = 30.0;

    /// The limits of machine `m`.
    pub fn new(m: &MachineResources) -> WorkLimits {
        let half = (m.cores / 2).max(1);
        let gib = MachineResources::GIB;
        let low = m.is_low_memory();
        let weak = m.is_weak_for_decode();
        let tiny = m.memory_bytes <= 4 * gib || m.cores <= 2;
        let software_decoder_sessions = if tiny {
            1
        } else if weak {
            2
        } else {
            8
        };
        let mb = |n: i64| n << 20;
        let (import_probes, poster_decodes, waveform_reads, proxy_transcodes, layer_decodes) = if low {
            (4.min(half), 2.min(half), 2.min(half), 1, 2.min(half))
        } else {
            (
                8.min(half),
                6.min(2.max(half - 1)),
                if m.cores >= 16 { 3 } else { 2 },
                if m.memory_bytes >= 64 * gib && m.cores >= 16 { 2 } else { 1 },
                4.min(half),
            )
        };
        WorkLimits {
            import_probes,
            poster_decodes,
            waveform_reads,
            proxy_transcodes,
            layer_decodes,
            mask_track_dimension: if low { 480 } else { 640 },
            subject_mask_dimension: if low {
                540
            } else if weak {
                640
            } else {
                960
            },
            mask_track_chunk_seconds: if low { 0.5 } else { 1.0 },
            export_render_ahead: !low && m.cores > 1,
            export_decoder_sessions: if low { 4 } else { 8 },
            export_frame_bytes: if low { mb(384) } else { mb(768) },
            export_intermediate_pool_bytes: if low { mb(256) } else { 1 << 30 },
            picture_analyses: if !low && m.cores > 4 { 2 } else { 1 },
            software_decoder_sessions,
            preview_decoder_frame_bytes: if tiny {
                mb(96)
            } else if weak {
                mb(192)
            } else {
                mb(768)
            },
            preview_decode_jobs: if software_decoder_sessions == 1 {
                1
            } else if weak {
                2
            } else {
                4
            },
            cpu_fallback_jobs: if weak { 1 } else { half },
            reduced_preview_decode: weak,
            poster_cache_bytes: if low { mb(32) } else { mb(64) },
            clip_frame_cache_bytes: if low { mb(24) } else { mb(48) },
            thumbnail_memory_bytes: if low { mb(24) } else { mb(48) },
            waveform_cache_bytes: if low { mb(32) } else { mb(64) },
            frame_cache_bytes: if low { to_int(m.memory_bytes / 6) } else { to_int((m.memory_bytes / 4).min(8 * gib)) },
            intermediate_pool_bytes: to_int((m.memory_bytes / 32).clamp(128 << 20, 1 << 30)),
        }
    }

    /// The caps per pool for this machine: decode = preview decode jobs, gpu = frames in flight (render-ahead doubles
    /// it), cpu = software-path jobs.
    pub fn pools(&self) -> WorkPools {
        WorkPools::new(self.preview_decode_jobs, if self.export_render_ahead { 2 } else { 1 }, self.cpu_fallback_jobs)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const GB: u64 = 1 << 30;

    fn limits(gb: u64, cores: i64) -> WorkLimits {
        MachineResources::new(gb * GB, cores, false).limits()
    }

    fn env(pairs: &'static [(&'static str, &'static str)]) -> impl Fn(&str) -> Option<String> {
        move |k| pairs.iter().find(|(n, _)| *n == k).map(|(_, v)| v.to_string())
    }

    #[test]
    fn simulation_only_lowers_ram_and_cores() {
        let air = MachineResources::current(env(&[("SQ_RAM_GB", "8"), ("SQ_CORES", "8")]), 32 * GB, 10, false);
        assert!(air.memory_bytes == 8 * GB && air.cores == 8 && air.is_low_memory());
        let bigger = MachineResources::current(env(&[("SQ_RAM_GB", "64"), ("SQ_CORES", "32")]), 32 * GB, 10, false);
        assert!(bigger.memory_bytes == 32 * GB && bigger.cores == 10);
        let junk = MachineResources::current(env(&[("SQ_RAM_GB", "x"), ("SQ_CORES", "0")]), 32 * GB, 10, false);
        assert_eq!(junk, MachineResources::new(32 * GB, 10, false));
    }

    #[test]
    fn eight_gigabyte_air_gets_narrow_lanes() {
        let air = limits(8, 8);
        assert_eq!(air.import_probes, 4);
        assert_eq!(air.poster_decodes, 2);
        assert_eq!(air.waveform_reads, 2);
        assert_eq!(air.proxy_transcodes, 1);
        assert!(air.mask_track_dimension == 480 && air.mask_track_chunk_seconds == 0.5);
        let big = limits(32, 10);
        assert!(big.mask_track_dimension == 640 && big.mask_track_chunk_seconds == 1.0);
        assert!(big.subject_mask_dimension == 960 && air.subject_mask_dimension == 540);
        assert_eq!(limits(16, 4).subject_mask_dimension, 640);
    }

    #[test]
    fn big_mac_gets_wider_lanes_but_stays_bounded() {
        let max = limits(32, 10);
        assert_eq!((max.import_probes, max.poster_decodes, max.waveform_reads, max.proxy_transcodes), (5, 4, 2, 1));
        let studio = limits(128, 24);
        assert_eq!(
            (studio.import_probes, studio.poster_decodes, studio.waveform_reads, studio.proxy_transcodes),
            (8, 6, 3, 2)
        );
    }

    #[test]
    fn picture_analyses_run_one_at_a_time_on_small_macs() {
        assert_eq!(limits(8, 8).picture_analyses, 1);
        assert_eq!(limits(32, 4).picture_analyses, 1);
        assert_eq!(limits(32, 10).picture_analyses, 2);
        assert_eq!(limits(4, 2).picture_analyses, 1);
    }

    #[test]
    fn software_decode_is_capped_on_weak_macs() {
        // (RAM GB, cores, intel, software sessions, preview frame MB, preview decode jobs, reduced decode)
        let table = [
            (8, 8, false, 2, 192, 2, true),
            (4, 2, false, 1, 96, 1, true),
            (32, 4, false, 2, 192, 2, true),
            (32, 10, true, 2, 192, 2, true),
            (16, 10, false, 8, 768, 4, false),
            (32, 10, false, 8, 768, 4, false),
            (128, 24, false, 8, 768, 4, false),
        ];
        for (ram, cores, intel, sessions, mb, jobs, reduced) in table {
            let l = MachineResources::new(ram * GB, cores, intel).limits();
            assert_eq!(l.software_decoder_sessions, sessions, "{ram} GB {cores} cores intel {intel}");
            assert_eq!(l.preview_decoder_frame_bytes, mb << 20, "{ram} GB {cores} cores intel {intel}");
            assert_eq!(l.preview_decode_jobs, jobs);
            assert_eq!(l.reduced_preview_decode, reduced);
        }
    }

    #[test]
    fn intel_flag_comes_from_the_environment_injection() {
        let m = MachineResources::current(env(&[]), 32 * GB, 10, true);
        assert!(m.is_intel && m.is_weak_for_decode());
        assert!(!MachineResources::current(env(&[]), 32 * GB, 10, false).is_weak_for_decode());
    }

    #[test]
    fn tiny_machine_still_makes_progress() {
        let l = limits(4, 2);
        assert!(l.import_probes >= 1 && l.poster_decodes >= 1 && l.waveform_reads >= 1 && l.proxy_transcodes == 1);
        assert!(l.import_probes <= 2 && l.poster_decodes == 1);
    }

    #[test]
    fn export_decoder_budget_is_halved_only_on_low_memory_macs() {
        let air = limits(8, 8);
        assert!(air.export_decoder_sessions == 4 && air.export_frame_bytes == 384 << 20);
        let tiny = limits(4, 2);
        assert!(tiny.export_decoder_sessions == 4 && tiny.export_frame_bytes == 384 << 20);
        for m in [16, 32, 128] {
            let l = limits(m, 10);
            assert!(l.export_decoder_sessions == 8 && l.export_frame_bytes == 768 << 20);
        }
    }

    #[test]
    fn export_compositor_pool_is_small_on_low_memory_macs() {
        assert_eq!(limits(8, 8).export_intermediate_pool_bytes, 256 << 20);
        assert_eq!(limits(4, 4).export_intermediate_pool_bytes, 256 << 20);
        assert_eq!(limits(16, 10).export_intermediate_pool_bytes, 1 << 30);
        assert_eq!(limits(64, 16).export_intermediate_pool_bytes, 1 << 30);
    }

    #[test]
    fn layer_decodes_are_bounded_by_cores_and_memory() {
        assert_eq!(limits(8, 8).layer_decodes, 2);
        assert_eq!(limits(32, 10).layer_decodes, 4);
        assert_eq!(limits(128, 24).layer_decodes, 4);
        assert_eq!(limits(16, 4).layer_decodes, 2);
        assert_eq!(limits(8, 1).layer_decodes, 1);
        assert_eq!(limits(32, 1).layer_decodes, 1);
    }

    #[test]
    fn export_renders_ahead_only_with_memory_and_cores_to_spare() {
        assert!(!limits(8, 8).export_render_ahead);
        assert!(limits(16, 8).export_render_ahead);
        assert!(limits(64, 10).export_render_ahead);
        assert!(!limits(32, 1).export_render_ahead);
    }

    #[test]
    fn pools_are_capped_separately() {
        assert_eq!(limits(8, 8).pools(), WorkPools::new(2, 1, 1));
        assert_eq!(limits(64, 16).pools(), WorkPools::new(4, 2, 8));
        let tiny = limits(4, 1).pools();
        assert!(tiny.decode == 1 && tiny.gpu == 1 && tiny.cpu == 1);
    }
}
