// SPDX-License-Identifier: GPL-3.0-or-later
//! `cargo run -p sq-audio-out --example probe --release`: lists the cpal output devices with their default and supported
//! formats, then plays a 440 Hz tone for 2 s through `AudioOut::open` (the code path of the app) and prints the result.
use cpal::traits::{DeviceTrait, HostTrait};
use sq_audio_out::output::{AudioOut, OutputConfig, OutputEvent, Renderer};
use sq_core_edit::playback::PlaybackRate;
use sq_core_time::Time;
use std::time::Duration;

struct Tone(f64);
impl Renderer for Tone {
    fn render(&mut self, out: &mut [f32]) {
        for f in out.chunks_mut(2) {
            let s = (self.0 * 2.0 * std::f64::consts::PI * 440.0 / 48_000.0).sin() as f32 * 0.2;
            f[0] = s;
            f[1] = s;
            self.0 += 1.0;
        }
    }
    fn flush(&mut self, _: Time, _: PlaybackRate) {}
}

fn main() {
    let host = cpal::default_host();
    let default = host.default_output_device().and_then(|d| d.description().ok().map(|d| d.name().to_string()));
    println!("default: {default:?}");
    for d in host.output_devices().into_iter().flatten() {
        let name = d.description().map(|d| d.name().to_string()).unwrap_or_default();
        println!("device {name}: default {:?}", d.default_output_config().map_err(|e| e.to_string()));
        for c in d.supported_output_configs().into_iter().flatten().take(6) {
            println!("   {c:?}");
        }
    }
    let (tx, rx) = std::sync::mpsc::channel();
    match AudioOut::open(OutputConfig::default(), Box::new(Tone(0.0)), tx) {
        Err(e) => println!("OPEN FAILED: {e}"),
        Ok(out) => {
            out.restart(Time::new(0, 1), PlaybackRate::FORWARD);
            std::thread::sleep(Duration::from_secs(2));
            println!("clock {:?} stats {:?} latency {:?}", out.clock().now(), out.stats(), out.latency());
            while let Ok(e) = rx.try_recv() {
                println!("event {e:?}");
                let _: OutputEvent = e;
            }
        }
    }
}
