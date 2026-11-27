// Swift: EditAPIServer+Network.swift, EditAPIServer+Winsock.swift
//! Loopback-only HTTP listener for `EditAPIRouter`.

use crate::edit_apirouter::EditAPIRouter;
use crate::http::{HTTPParser, HTTPResponse, ParseResult};
use std::io::{Read, Write};
use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4, TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex, PoisonError};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

/// Listener state, reported through the `on_state` callback.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum State {
    /// Binding.
    Starting,
    /// Listening on this port.
    Ready(u16),
    /// Could not listen.
    Failed(String),
    /// Closed.
    Stopped,
}

/// Counts open connections against a cap.
#[derive(Debug)]
pub(crate) struct ConnectionLimiter {
    max: usize,
    pub(crate) open: usize,
}

impl ConnectionLimiter {
    pub(crate) fn new(max: usize) -> ConnectionLimiter {
        ConnectionLimiter { max, open: 0 }
    }

    pub(crate) fn acquire(&mut self) -> bool {
        if self.open >= self.max {
            return false;
        }
        self.open += 1;
        true
    }

    pub(crate) fn release(&mut self) {
        self.open = self.open.saturating_sub(1);
    }
}

/// Loopback-only HTTP listener for `EditAPIRouter`. Binds 127.0.0.1 (never a public interface), refuses non-loopback
/// peers, one request per connection, bounded size and a 15 s deadline per connection, at most 8 connections at once
/// (more are closed at once).
///
/// shortcut: the accept loop polls a non-blocking listener every 10 ms and each connection gets a thread; fine for a
/// local tool API, upgrade to the executor's sockets if it ever serves many clients.
pub struct EditAPIServer {
    router: Arc<EditAPIRouter>,
    on_state: Arc<dyn Fn(State) + Send + Sync>,
    limiter: Arc<Mutex<ConnectionLimiter>>,
    running: Arc<AtomicBool>,
    accept_thread: Mutex<Option<JoinHandle<()>>>,
}

impl EditAPIServer {
    /// Per-connection deadline for reading the request and answering it.
    pub const TIMEOUT: Duration = Duration::from_secs(15);

    /// A stopped server over `router`.
    pub fn new(router: EditAPIRouter, on_state: impl Fn(State) + Send + Sync + 'static) -> EditAPIServer {
        EditAPIServer {
            router: Arc::new(router),
            on_state: Arc::new(on_state),
            limiter: Arc::new(Mutex::new(ConnectionLimiter::new(8))),
            running: Arc::new(AtomicBool::new(false)),
            accept_thread: Mutex::new(None),
        }
    }

    /// Starts listening on `127.0.0.1:port`; reports `Starting` then `Ready` or `Failed`. Does nothing when running.
    pub fn start(&self) {
        let mut thread = self.accept_thread.lock().unwrap_or_else(PoisonError::into_inner);
        if self.running.load(Ordering::SeqCst) {
            return;
        }
        (self.on_state)(State::Starting);
        let port = self.router.config.port;
        let listener = match TcpListener::bind(SocketAddrV4::new(Ipv4Addr::LOCALHOST, port)) {
            Ok(l) => l,
            Err(e) => return (self.on_state)(State::Failed(e.to_string())),
        };
        if let Err(e) = listener.set_nonblocking(true) {
            return (self.on_state)(State::Failed(e.to_string()));
        }
        self.running.store(true, Ordering::SeqCst);
        (self.on_state)(State::Ready(port));
        let (router, limiter, running) =
            (Arc::clone(&self.router), Arc::clone(&self.limiter), Arc::clone(&self.running));
        *thread = Some(std::thread::spawn(move || accept_loop(&listener, &router, &limiter, &running)));
    }

    /// Stops listening; connections already accepted finish or time out on their own.
    pub fn stop(&self) {
        let mut thread = self.accept_thread.lock().unwrap_or_else(PoisonError::into_inner);
        let was = self.running.swap(false, Ordering::SeqCst);
        if let Some(t) = thread.take() {
            let _ = t.join();
        }
        if was {
            (self.on_state)(State::Stopped);
        }
    }
}

impl Drop for EditAPIServer {
    fn drop(&mut self) {
        self.stop();
    }
}

fn is_loopback(peer: &SocketAddr) -> bool {
    match peer.ip() {
        std::net::IpAddr::V4(a) => a.is_loopback(),
        std::net::IpAddr::V6(a) => a.is_loopback() || a.to_ipv4_mapped().is_some_and(|v4| v4.is_loopback()),
    }
}

fn accept_loop(
    listener: &TcpListener,
    router: &Arc<EditAPIRouter>,
    limiter: &Arc<Mutex<ConnectionLimiter>>,
    running: &AtomicBool,
) {
    while running.load(Ordering::SeqCst) {
        match listener.accept() {
            Ok((stream, peer)) => {
                let admitted = is_loopback(&peer) && limiter.lock().unwrap_or_else(PoisonError::into_inner).acquire();
                if !admitted || stream.set_nonblocking(false).is_err() {
                    continue; // dropped: closed at once
                }
                let (router, limiter) = (Arc::clone(router), Arc::clone(limiter));
                std::thread::spawn(move || {
                    serve(stream, &router);
                    limiter.lock().unwrap_or_else(PoisonError::into_inner).release();
                });
            }
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => std::thread::sleep(Duration::from_millis(10)),
            Err(_) => return,
        }
    }
}

/// One connection: read one request, answer it, close. The deadline covers reading and the router; when it passes, the
/// request's cancel flag is set so a commit that has not started yet is dropped, not applied late.
fn serve(mut stream: TcpStream, router: &Arc<EditAPIRouter>) {
    let deadline = Instant::now() + EditAPIServer::TIMEOUT;
    let mut buf: Vec<u8> = Vec::new();
    let mut chunk = vec![0_u8; 64 * 1024];
    loop {
        match HTTPParser::parse(&buf, router.config.max_body_bytes) {
            ParseResult::Invalid(status) => {
                return send(&mut stream, &HTTPResponse::error(status, "bad request", None));
            }
            ParseResult::Complete(req, _) => {
                let cancel = Arc::new(AtomicBool::new(false));
                let (tx, rx) = mpsc::channel();
                let (worker_router, worker_cancel) = (Arc::clone(router), Arc::clone(&cancel));
                std::thread::spawn(move || {
                    let _ = tx.send(worker_router.handle(&req, &worker_cancel));
                });
                let remaining = deadline.saturating_duration_since(Instant::now());
                match rx.recv_timeout(remaining) {
                    Ok(response) => send(&mut stream, &response),
                    Err(_) => {
                        cancel.store(true, Ordering::SeqCst);
                        // Never close without a reply: the caller learns the call was canceled.
                        send(
                            &mut stream,
                            &HTTPResponse::error(503, "request deadline passed; the call was canceled", None),
                        );
                    }
                }
                return;
            }
            ParseResult::Incomplete => {
                let remaining = deadline.saturating_duration_since(Instant::now());
                if remaining.is_zero() || stream.set_read_timeout(Some(remaining)).is_err() {
                    return;
                }
                match stream.read(&mut chunk) {
                    Ok(0) | Err(_) => return,
                    Ok(n) => buf.extend_from_slice(&chunk[..n]),
                }
            }
        }
    }
}

fn send(stream: &mut TcpStream, response: &HTTPResponse) {
    if stream.write_all(&response.serialized()).is_ok() {
        let _ = stream.shutdown(std::net::Shutdown::Write);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::edit_apirouter::{EditAPIConfig, tests::FakeHost};
    use crate::edit_transaction::fixture::Fixture;
    use crate::project_state::ProjectState;

    #[test]
    fn connection_limiter_caps() {
        let mut l = ConnectionLimiter::new(2);
        let (a, b, c) = (l.acquire(), l.acquire(), l.acquire());
        assert!(a && b && !c);
        l.release();
        assert!(l.acquire());
        l.release();
        l.release();
        l.release();
        assert_eq!(l.open, 0);
    }

    fn free_port() -> u16 {
        TcpListener::bind("127.0.0.1:0").and_then(|l| l.local_addr()).map_or(41234, |a| a.port())
    }

    fn get(port: u16, token: &str) -> (u16, Vec<u8>) {
        let mut s = TcpStream::connect(("127.0.0.1", port)).unwrap_or_else(|e| panic!("connect: {e}"));
        let request =
            format!("GET /v1/state HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nAuthorization: Bearer {token}\r\n\r\n");
        assert!(s.write_all(request.as_bytes()).is_ok());
        let mut raw = Vec::new();
        assert!(s.read_to_end(&mut raw).is_ok());
        let text = String::from_utf8_lossy(&raw).into_owned();
        let status = text.split(' ').nth(1).and_then(|c| c.parse().ok()).unwrap_or(0);
        let body = raw.windows(4).position(|w| w == b"\r\n\r\n").map_or_else(Vec::new, |i| raw[i + 4..].to_vec());
        (status, body)
    }

    #[test]
    fn serves_over_loopback_with_token() {
        let port = free_port();
        let token = EditAPIConfig::make_token(&mut || 0xAB);
        let states = Arc::new(Mutex::new(Vec::new()));
        let seen = Arc::clone(&states);
        let router = EditAPIRouter::new(EditAPIConfig::new(token.clone(), port), FakeHost::new(&Fixture::new()));
        let server = EditAPIServer::new(router, move |s| seen.lock().unwrap_or_else(PoisonError::into_inner).push(s));
        server.start();
        assert!(states.lock().unwrap_or_else(PoisonError::into_inner).contains(&State::Ready(port)));

        let (status, body) = get(port, &token);
        assert_eq!(status, 200);
        let state: ProjectState = serde_json::from_slice(&body).unwrap_or_else(|e| panic!("state: {e}"));
        assert_eq!(state.sequences.len(), 1);
        assert_eq!(get(port, "nope").0, 401);

        server.stop();
        assert_eq!(states.lock().unwrap_or_else(PoisonError::into_inner).last(), Some(&State::Stopped));
        assert!(TcpStream::connect(("127.0.0.1", port)).is_err());
    }
}
