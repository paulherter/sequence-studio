use super::*;

/// A microphone that plays a sine at `rate` in blocks of 480 the moment it starts, then goes quiet.
struct FakeMic {
    rate: u32,
    seconds: f32,
    refuse: bool,
    stopped: Arc<AtomicBool>,
}

impl FakeMic {
    fn new(rate: u32, seconds: f32) -> FakeMic {
        FakeMic { rate, seconds, refuse: false, stopped: Arc::new(AtomicBool::new(false)) }
    }
}

impl MicSource for FakeMic {
    fn sample_rate(&self) -> u32 {
        self.rate
    }
    fn start(&mut self, mut sink: MicSink) -> Result<(), MicError> {
        if self.refuse {
            return Err(MicError::NoDevice);
        }
        let total = (self.rate as f32 * self.seconds) as usize;
        let wave: Vec<f32> = (0..total)
            .map(|i| 0.5 * (i as f32 * 2.0 * std::f32::consts::PI * 440.0 / self.rate as f32).sin())
            .collect();
        for block in wave.chunks(480) {
            sink(block);
        }
        Ok(())
    }
    fn stop(&mut self) {
        self.stopped.store(true, Relaxed);
    }
}

fn tmp(name: &str) -> std::path::PathBuf {
    let d = std::env::temp_dir().join(format!("sq-input-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    d.join("Voice-Over.wav")
}

fn read_wav(path: &Path) -> (u32, Vec<i16>) {
    let b = std::fs::read(path).unwrap();
    assert_eq!(&b[0..4], b"RIFF");
    assert_eq!(&b[8..16], b"WAVEfmt ");
    assert_eq!(u16::from_le_bytes([b[22], b[23]]), 1, "mono");
    assert_eq!(u16::from_le_bytes([b[34], b[35]]), 16, "16-bit");
    let rate = u32::from_le_bytes([b[24], b[25], b[26], b[27]]);
    let data = u32::from_le_bytes([b[40], b[41], b[42], b[43]]) as usize;
    assert_eq!(b.len(), 44 + data, "header length matches the data");
    assert_eq!(u32::from_le_bytes([b[4], b[5], b[6], b[7]]) as usize, 36 + data);
    (rate, b[44..].chunks(2).map(|c| i16::from_le_bytes([c[0], c[1]])).collect())
}

#[test]
fn a_48k_source_is_written_as_it_is_and_the_header_is_patched() {
    let path = tmp("same");
    let mic = FakeMic::new(48_000, 1.0);
    let stopped = Arc::clone(&mic.stopped);
    let take = MicTake::start(Box::new(mic), &path).unwrap();
    assert!((take.elapsed() - 1.0).abs() < 0.02);
    let frames = take.finish().unwrap();
    assert!(stopped.load(Relaxed), "the source is stopped before the file is closed");
    assert_eq!(frames, 48_000);
    let (rate, samples) = read_wav(&path);
    assert_eq!((rate, samples.len()), (48_000, 48_000));
    assert!(samples.iter().any(|s| s.abs() > 10_000), "the sine arrived");
}

#[test]
fn a_44k_source_is_resampled_to_48k() {
    let path = tmp("resample");
    let take = MicTake::start(Box::new(FakeMic::new(44_100, 1.0)), &path).unwrap();
    let frames = take.finish().unwrap();
    assert!((frames as i64 - 48_000).abs() <= 2, "{frames}");
    let (_, samples) = read_wav(&path);
    // A 440 Hz sine stays smooth: no step between neighbors bigger than the sine's own slope allows.
    let max_step = samples.windows(2).map(|w| (i32::from(w[1]) - i32::from(w[0])).abs()).max().unwrap();
    assert!(max_step < 2_000, "{max_step}");
}

#[test]
fn a_missing_device_fails_the_take_without_a_file_left_open() {
    let path = tmp("refuse");
    let mut mic = FakeMic::new(48_000, 1.0);
    mic.refuse = true;
    assert!(matches!(MicTake::start(Box::new(mic), &path), Err(MicError::NoDevice)));
}

#[test]
fn the_wav_header_of_an_empty_take_is_valid() {
    let path = tmp("empty");
    let take = MicTake::start(Box::new(FakeMic::new(48_000, 0.0)), &path).unwrap();
    assert_eq!(take.finish().unwrap(), 0);
    assert_eq!(read_wav(&path).1.len(), 0);
}

/// The real default input for a third of a second (loopback on the PC: the file must have about that length). Skips on a
/// machine without an input device, without the microphone permission, or whose default input delivers no samples (on
/// Linux a PipeWire default source that is a virtual or unplugged device: `arecord -D default -d 1 x.wav` stays empty
/// too). Run it from a shell that has `XDG_RUNTIME_DIR=/run/user/<uid>` so cpal's ALSA plugin finds PipeWire.
#[test]
fn the_default_microphone_records_a_file() {
    if !CpalMic::available() {
        return;
    }
    let path = tmp("hardware");
    let Ok(take) = MicTake::start(Box::new(CpalMic::new()), &path) else { return };
    std::thread::sleep(std::time::Duration::from_millis(400));
    let frames = take.finish().unwrap();
    if frames == 0 {
        sq_os::errln!("skipped: the default input delivered no samples in 0.4 s");
        return;
    }
    assert!(frames > 48_000 / 10, "{frames}");
    let (rate, samples) = read_wav(&path);
    assert_eq!((rate, samples.len() as u64), (48_000, frames));
}
