// Swift: NSApplication open-file (the running app takes a second `open file.sqproj`), AppController.application(_:open:)
//! One running window: a second launch (double click on a `.sqproj`, Open With, the command line) hands its file to the
//! running app and exits. Same on every system: a loopback TCP port named in a file beside the app state, with a random
//! token so only this user's processes that can read the file may send. The primary instance gets the paths on a channel;
//! an empty path means "just bring the window forward".

use std::fs::{File, TryLockError};
use std::io::{BufRead, BufReader, Write};
use std::net::{Ipv4Addr, SocketAddr, TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::sync::mpsc::Sender;
use std::time::Duration;

/// File name of the claim in the app's support folder.
pub const CLAIM_FILE: &str = "instance.port";
/// File name of the OS lock beside it: held (exclusively) by the primary for its whole life. The OS drops the lock when
/// the process ends, however it ends, so a crash never leaves a stale lock behind.
pub const LOCK_FILE: &str = "instance.lock";
/// How long a second launch waits for a primary that holds the lock but has not published its port yet.
const FORWARD_WAIT: Duration = Duration::from_secs(4);

/// What `claim` found out.
pub enum Claim {
    /// This process is the only one: it owns the listener (kept alive by the value).
    Primary(Primary),
    /// Another instance is running and got the request: exit.
    Forwarded,
}

/// The listener of the running instance; dropped at exit (the OS frees the lock, the next start replaces the claim file).
pub struct Primary {
    _lock: File,
    _thread: std::thread::JoinHandle<()>,
}

fn token() -> String {
    let mut seed =
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(1, |d| d.as_nanos() as u64);
    seed ^= u64::from(std::process::id()) << 32;
    let mut out = String::new();
    for _ in 0..2 {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        out.push_str(&format!("{seed:016x}"));
    }
    out
}

/// Sends `request` (a path or "") to the instance named in `dir`'s claim file; false when none answers.
fn forward(dir: &Path, request: &str) -> bool {
    let Ok(text) = std::fs::read_to_string(dir.join(CLAIM_FILE)) else { return false };
    let mut parts = text.split_whitespace();
    let (Some(port), Some(token)) = (parts.next().and_then(|p| p.parse::<u16>().ok()), parts.next()) else {
        return false;
    };
    let addr = SocketAddr::from((Ipv4Addr::LOCALHOST, port));
    let Ok(mut s) = TcpStream::connect_timeout(&addr, Duration::from_millis(400)) else { return false };
    let _ = s.set_write_timeout(Some(Duration::from_millis(400)));
    let _ = s.set_read_timeout(Some(Duration::from_millis(400)));
    if s.write_all(format!("{token}\n{request}\n").as_bytes()).is_err() {
        return false;
    }
    // The primary answers "ok" once it took the request; a dead port or a stranger does not.
    let mut answer = String::new();
    BufReader::new(s).read_line(&mut answer).is_ok() && answer.trim() == "ok"
}

/// Takes the instance lock; `Ok(None)` when another process holds it.
fn try_lock(dir: &Path) -> std::io::Result<Option<File>> {
    std::fs::create_dir_all(dir)?;
    let file = File::options().create(true).truncate(false).write(true).open(dir.join(LOCK_FILE))?;
    match file.try_lock() {
        Ok(()) => Ok(Some(file)),
        Err(TryLockError::WouldBlock) => Ok(None),
        Err(TryLockError::Error(e)) => Err(e),
    }
}

/// Forwards `path` (None = just raise the window) to a running instance, else becomes the primary: `on_open` then gets
/// every later request (`None` = raise the window) on the listener's thread. Who is primary is decided by the OS lock,
/// so two launches at the same moment cannot both win; a launch that loses waits until the winner has published its
/// port, and takes over when the winner dies meanwhile.
pub fn claim(dir: &Path, path: Option<&Path>, on_open: Sender<Option<PathBuf>>) -> std::io::Result<Claim> {
    let request = path.map(|p| p.to_string_lossy().into_owned()).unwrap_or_default();
    if request.contains('\n') {
        return Err(std::io::Error::new(std::io::ErrorKind::InvalidInput, "newline in path"));
    }
    let started = std::time::Instant::now();
    let lock = loop {
        if let Some(lock) = try_lock(dir)? {
            break lock;
        }
        if forward(dir, &request) {
            return Ok(Claim::Forwarded);
        }
        if started.elapsed() > FORWARD_WAIT {
            return Err(std::io::Error::new(
                std::io::ErrorKind::TimedOut,
                "another instance holds the lock but does not answer",
            ));
        }
        std::thread::sleep(Duration::from_millis(50));
    };
    // The lock is ours: an old claim file belongs to a dead process.
    let _ = std::fs::remove_file(dir.join(CLAIM_FILE));
    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0))?;
    let port = listener.local_addr()?.port();
    let secret = token();
    // Write beside, then rename: a reader never sees half a file.
    let tmp = dir.join(format!("{CLAIM_FILE}.tmp"));
    std::fs::write(&tmp, format!("{port} {secret}"))?;
    std::fs::rename(&tmp, dir.join(CLAIM_FILE))?;
    let thread = std::thread::Builder::new().name("sq-instance".into()).spawn(move || {
        for conn in listener.incoming().flatten() {
            let _ = conn.set_read_timeout(Some(Duration::from_millis(500)));
            let mut lines = BufReader::new(&conn).lines();
            let (Some(Ok(got)), Some(Ok(request))) = (lines.next(), lines.next()) else { continue };
            if got != secret {
                continue;
            }
            let path = (!request.is_empty()).then(|| PathBuf::from(request));
            let _ = (&conn).write_all(b"ok\n");
            if on_open.send(path).is_err() {
                return;
            }
        }
    })?;
    // The first launch opens its own file itself: the caller keeps `path`.
    Ok(Claim::Primary(Primary { _lock: lock, _thread: thread }))
}

#[cfg(test)]
mod tests;
