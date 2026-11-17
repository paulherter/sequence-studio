// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: ComputeFallback.swift
//! Where a request runs: on the default devices (Neural Engine / GPU), and on the CPU when that fails. Every request falls
//! back by itself, so one failure never decides the next request and two requests failing at the same moment both get their
//! CPU try.
//!
//! What is remembered is only an order: after a fallback that worked, the next `retry_after` requests try the CPU first (no
//! failed attempt per frame while the Neural Engine is busy), then the default devices are tried again. Whatever is
//! remembered, a request fails only when both ways failed for that request.
use std::fmt::Display;
use std::sync::Mutex;

/// The CPU-or-default-devices fallback of one kind of request.
pub struct ComputeFallback {
    name: String,
    retry_after: usize,
    /// Requests left that try the CPU first.
    cpu_first: Mutex<usize>,
}

impl ComputeFallback {
    /// A fallback called `name` in the log; `retry_after` is 120 in Swift's default.
    pub fn new(name: &str, retry_after: usize) -> ComputeFallback {
        ComputeFallback { name: name.to_string(), retry_after, cpu_first: Mutex::new(0) }
    }

    fn count(&self) -> std::sync::MutexGuard<'_, usize> {
        self.cpu_first.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// True while requests try the CPU first.
    pub fn prefers_cpu(&self) -> bool {
        *self.count() > 0
    }

    /// Runs `perform` (`cpu`: pin the request to the CPU), and once more the other way when it fails. Returns the error of
    /// the default devices when both ways failed.
    pub fn run<T, E: Display>(&self, mut perform: impl FnMut(bool) -> Result<T, E>) -> Result<T, E> {
        let cpu = {
            let mut n = self.count();
            if *n > 0 {
                *n -= 1;
                true
            } else {
                false
            }
        };
        let first = match perform(cpu) {
            Ok(v) => return Ok(v),
            Err(e) => e,
        };
        eprintln!(
            "[{}] {} failed, fallback to {}: {}",
            self.name,
            if cpu { "CPU" } else { "default compute" },
            if cpu { "default compute" } else { "CPU" },
            first
        );
        match perform(!cpu) {
            Ok(v) => {
                // The CPU worked where the default did not: CPU first for a while. The default worked where the CPU
                // did not: back to the default at once.
                *self.count() = if cpu { 0 } else { self.retry_after };
                Ok(v)
            }
            Err(second) => {
                *self.count() = 0;
                eprintln!("[{}] both compute paths failed: {}", self.name, second);
                Err(if cpu { second } else { first })
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use std::thread;

    #[test]
    fn one_failure_falls_back_and_the_next_request_works() {
        let f = ComputeFallback::new("test", 3);
        let mut calls: Vec<bool> = Vec::new();
        // The default devices fail once: that request is answered by the CPU.
        let first = f.run(|cpu| {
            calls.push(cpu);
            if !cpu { Err("boom") } else { Ok("cpu") }
        });
        assert_eq!(first, Ok("cpu"));
        assert_eq!(calls, [false, true]);
        assert!(f.prefers_cpu());
        // The next requests work (CPU first, three times), then the default devices are tried again.
        calls.clear();
        for _ in 0..4 {
            let _ = f.run(|cpu| {
                calls.push(cpu);
                Ok::<_, &str>(1)
            });
        }
        assert_eq!(calls, [true, true, true, false]);
        assert!(!f.prefers_cpu());
    }

    #[test]
    fn a_cpu_failure_does_not_poison_later_requests() {
        let f = ComputeFallback::new("test", 100);
        let _ = f.run(|cpu| if !cpu { Err("boom") } else { Ok(1) });
        assert!(f.prefers_cpu());
        // CPU first now, and the CPU fails: the same request goes to the default devices and works.
        let mut calls: Vec<bool> = Vec::new();
        let r = f.run(|cpu| {
            calls.push(cpu);
            if cpu { Err("boom") } else { Ok("default") }
        });
        assert_eq!(r, Ok("default"));
        assert_eq!(calls, [true, false]);
        assert!(!f.prefers_cpu());
        // Both ways fail for one request: it fails, and the request after it runs as if nothing had happened.
        assert_eq!(f.run(|_| Err::<i32, _>("boom")), Err("boom"));
        assert!(!f.prefers_cpu());
        calls.clear();
        let after = f.run(|cpu| {
            calls.push(cpu);
            Ok::<_, &str>(7)
        });
        assert_eq!(after, Ok(7));
        assert_eq!(calls, [false]);
    }

    #[test]
    fn concurrent_failures_each_get_their_own_cpu_try() {
        let f = Arc::new(ComputeFallback::new("test", 5));
        let handles: Vec<_> = (0..64)
            .map(|_| {
                let f = Arc::clone(&f);
                // The default devices always fail, the CPU always works.
                thread::spawn(move || f.run(|cpu| if !cpu { Err("boom") } else { Ok(true) }).unwrap_or(false))
            })
            .collect();
        let results: Vec<bool> = handles.into_iter().map(|h| h.join().unwrap_or(false)).collect();
        assert!(results.len() == 64 && results.iter().all(|r| *r));
    }
}
