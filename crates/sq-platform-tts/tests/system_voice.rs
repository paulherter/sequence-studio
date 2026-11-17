//! The system voices write a WAV with real sound. Needs the system's voices and, on the Mac, a running main run loop
//! (the synthesizer delivers its buffers through it; in the app winit provides it), so this test has its own `main`.
//! It only runs with `SQ_TTS_SYSTEM=1`.

use sq_platform_tts::{own_language, render, system_engine};
use std::path::Path;

#[cfg(target_os = "macos")]
fn pump_main_run_loop(done: &std::sync::atomic::AtomicBool) {
    use std::ffi::c_void;
    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        static kCFRunLoopDefaultMode: *const c_void;
        fn CFRunLoopRunInMode(mode: *const c_void, secs: f64, ret: u8) -> i32;
    }
    let started = std::time::Instant::now();
    while !done.load(std::sync::atomic::Ordering::SeqCst) && started.elapsed().as_secs() < 60 {
        // SAFETY: plain CoreFoundation call on the main thread with its default mode.
        unsafe { CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, 0) };
    }
}

#[cfg(not(target_os = "macos"))]
fn pump_main_run_loop(_: &std::sync::atomic::AtomicBool) {}

fn speak() -> Result<(), String> {
    let engine = system_engine().ok_or("no engine in this build")?;
    let mut voices = engine.voices();
    sq_platform_tts::sort_voices(&mut voices, &own_language());
    let voice = voices.first().ok_or("no voices installed")?;
    let out = std::env::temp_dir().join(format!("sq-tts-system-{}.wav", std::process::id()));
    let length = render(engine.as_ref(), "Hello from Sequence Studio.", &voice.id, 0.5, Path::new(&out))
        .map_err(|e| format!("{e:?}"))?;
    let bytes = std::fs::read(&out).map_err(|e| e.to_string())?;
    let _ = std::fs::remove_file(&out);
    let peak = bytes
        .get(44..)
        .unwrap_or_default()
        .as_chunks::<2>()
        .0
        .iter()
        .map(|c| i16::from_le_bytes(*c).unsigned_abs())
        .max();
    if length.value() <= 0 || peak.unwrap_or(0) < 500 {
        return Err(format!("silent: {length:?}, peak {peak:?}"));
    }
    println!(
        "{} spoke {:.2} s, peak {}",
        voice.name,
        length.value() as f64 / length.timescale() as f64,
        peak.unwrap_or(0)
    );
    Ok(())
}

fn main() {
    // nextest lists tests with `--list`: this opt-in run exposes none, so it prints nothing there.
    if std::env::args().any(|a| a == "--list") {
        return;
    }
    if std::env::var("SQ_TTS_SYSTEM").is_err() {
        println!("skipped: set SQ_TTS_SYSTEM=1 to speak with the system voices");
        return;
    }
    let done = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let flag = std::sync::Arc::clone(&done);
    let worker = std::thread::spawn(move || {
        let r = speak();
        flag.store(true, std::sync::atomic::Ordering::SeqCst);
        r
    });
    pump_main_run_loop(&done);
    match worker.join() {
        Ok(Ok(())) => {}
        Ok(Err(e)) => panic!("{e}"),
        Err(_) => panic!("worker panicked"),
    }
}
