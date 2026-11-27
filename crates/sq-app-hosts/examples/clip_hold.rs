//! Proof tool: puts one large picture on the system clipboard and keeps it there until the process is killed.
//! `clip_hold read` instead times one `get_image` and prints it.
//! `clip_hold [width height]` (default 3000 x 2000, noisy so the PNG stays big). Run it on the display under test only.
#![allow(clippy::expect_used)] // a proof tool: a missing clipboard should stop it with a message
// `SetExtLinux::wait` exists only on Linux/BSD; elsewhere the tool has nothing to prove and only says so.
#[cfg(not(all(unix, not(target_os = "macos"))))]
fn main() {
    eprintln!("clip_hold: Linux only");
}

#[cfg(all(unix, not(target_os = "macos")))]
fn main() {
    use arboard::{Clipboard, ImageData, SetExtLinux};

    if std::env::args().nth(1).as_deref() == Some("read") {
        let t = std::time::Instant::now();
        let r = Clipboard::new().and_then(|mut c| c.get_image());
        println!("read {:?} in {} ms", r.map(|i| (i.width, i.height)), t.elapsed().as_millis());
        return;
    }
    let mut a = std::env::args().skip(1);
    let w: usize = a.next().and_then(|s| s.parse().ok()).unwrap_or(3000);
    let h: usize = a.next().and_then(|s| s.parse().ok()).unwrap_or(2000);
    let mut seed = 0x2545_F491_4F6C_DD1Du64;
    let mut bytes = Vec::with_capacity(w * h * 4);
    for i in 0..w * h {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        let (x, y) = (i % w, i / w);
        bytes.extend_from_slice(&[
            (x * 255 / w) as u8 ^ (seed as u8 & 15),
            (y * 255 / h) as u8,
            (seed >> 8) as u8,
            255,
        ]);
    }
    let image = ImageData { width: w, height: h, bytes: bytes.into() };
    // `wait()` serves the selection until another app takes the clipboard.
    Clipboard::new().expect("clipboard").set().wait().image(image).expect("set image");
}
