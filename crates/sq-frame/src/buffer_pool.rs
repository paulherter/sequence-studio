//! Reusable byte buffers for decoded pictures.
//!
//! Every decoded picture used to be a fresh `vec![0; n]`: a 1080p NV12 picture is 3 MB, a 4K P010 one 12 MB, and five layers at
//! 30 fps made over a hundred thousand page faults a second (the allocator hands such sizes straight back to the system on drop
//! and maps new zeroed pages for the next). A picture that leaves the frame cache returns its buffer here, and the next
//! download of the same size takes it again, so a steady playback allocates nothing.

use std::collections::HashMap;
use std::ops::{Deref, DerefMut};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock, PoisonError};

/// Free buffers kept per size; more are freed.
const PER_SIZE: usize = 32;

/// Bytes of free buffers the shared pool keeps. They sit on top of the frame cache's budget, so the figure stays small: the
/// frame cache trims in bursts of a few hundred MB, and this much covers the pictures decoded right after one.
const SHARED_BUDGET: usize = 128 << 20;

#[derive(Default)]
struct Free {
    by_len: HashMap<usize, Vec<Vec<u8>>>,
    bytes: usize,
}

/// Free buffers by exact size, behind a byte budget.
pub struct BufferPool {
    free: Mutex<Free>,
    budget: usize,
    reused: AtomicU64,
    allocated: AtomicU64,
}

impl BufferPool {
    pub fn new(budget: usize) -> Arc<BufferPool> {
        Arc::new(BufferPool {
            free: Mutex::new(Free::default()),
            budget,
            reused: AtomicU64::new(0),
            allocated: AtomicU64::new(0),
        })
    }

    /// The pool every picture download of the process uses.
    pub fn shared() -> Arc<BufferPool> {
        static SHARED: OnceLock<Arc<BufferPool>> = OnceLock::new();
        Arc::clone(SHARED.get_or_init(|| BufferPool::new(SHARED_BUDGET)))
    }

    /// A buffer of `len` bytes. A reused one holds the bytes of its last use: the caller overwrites all of it.
    pub fn take(self: &Arc<Self>, len: usize) -> PooledBytes {
        let reused = self.free.lock().unwrap_or_else(PoisonError::into_inner).take(len);
        let buf = match reused {
            Some(buf) => {
                self.reused.fetch_add(1, Ordering::Relaxed);
                buf
            }
            None => {
                self.allocated.fetch_add(1, Ordering::Relaxed);
                vec![0u8; len]
            }
        };
        PooledBytes { buf, len, pool: Some(Arc::clone(self)) }
    }

    fn give(&self, buf: Vec<u8>) {
        let len = buf.len();
        let mut free = self.free.lock().unwrap_or_else(PoisonError::into_inner);
        let room = len > 0
            && free.bytes + len <= self.budget
            && free.by_len.get(&len).is_none_or(|list| list.len() < PER_SIZE);
        if room {
            free.by_len.entry(len).or_default().push(buf);
            free.bytes += len;
        }
    }

    /// Bytes of free buffers held right now.
    pub fn free_bytes(&self) -> usize {
        self.free.lock().unwrap_or_else(PoisonError::into_inner).bytes
    }

    /// Buffers handed out again, and buffers allocated fresh, since the pool was made.
    pub fn counts(&self) -> (u64, u64) {
        (self.reused.load(Ordering::Relaxed), self.allocated.load(Ordering::Relaxed))
    }
}

impl Free {
    fn take(&mut self, len: usize) -> Option<Vec<u8>> {
        let buf = self.by_len.get_mut(&len).and_then(Vec::pop)?;
        self.bytes = self.bytes.saturating_sub(len);
        Some(buf)
    }
}

/// Picture bytes on loan from a [`BufferPool`] (or plain bytes that never return). Reads and writes as a byte slice.
pub struct PooledBytes {
    buf: Vec<u8>,
    /// The visible length (`<= buf.len()`): a download may need slack past the picture.
    len: usize,
    pool: Option<Arc<BufferPool>>,
}

impl PooledBytes {
    /// Shows only the first `len` bytes; the buffer still returns to the pool under its full size.
    pub fn truncate(&mut self, len: usize) {
        self.len = self.len.min(len);
    }

    /// The bytes as a `Vec` (a copy-free hand-over; the buffer does not return to the pool).
    pub fn into_vec(mut self) -> Vec<u8> {
        self.pool = None;
        let mut v = std::mem::take(&mut self.buf);
        v.truncate(self.len);
        v
    }
}

impl From<Vec<u8>> for PooledBytes {
    fn from(buf: Vec<u8>) -> Self {
        PooledBytes { len: buf.len(), buf, pool: None }
    }
}

impl Deref for PooledBytes {
    type Target = [u8];

    fn deref(&self) -> &[u8] {
        &self.buf[..self.len]
    }
}

impl DerefMut for PooledBytes {
    fn deref_mut(&mut self) -> &mut [u8] {
        &mut self.buf[..self.len]
    }
}

impl Drop for PooledBytes {
    fn drop(&mut self) {
        if let Some(pool) = self.pool.take() {
            pool.give(std::mem::take(&mut self.buf));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_dropped_buffer_comes_back_for_the_next_picture_of_that_size() {
        let pool = BufferPool::new(1 << 20);
        let first = pool.take(4096);
        let address = first.as_ptr();
        drop(first);
        let second = pool.take(4096);
        assert_eq!(second.as_ptr(), address, "the same memory, no new allocation");
        assert_eq!(pool.counts(), (1, 1));
        assert_eq!(pool.take(8192).len(), 8192, "another size is a new buffer");
    }

    #[test]
    fn a_playback_loop_that_holds_a_window_of_pictures_allocates_a_window_once() {
        let pool = BufferPool::new(64 << 20);
        let mut cache: std::collections::VecDeque<PooledBytes> = Default::default();
        for _ in 0..2000 {
            cache.push_back(pool.take(3 << 20)); // a 1080p NV12 picture
            if cache.len() > 8 {
                cache.pop_front(); // evicted from the frame cache
            }
        }
        let (reused, allocated) = pool.counts();
        assert_eq!(allocated, 9, "the window plus the one in flight, then nothing new");
        assert_eq!(reused, 2000 - 9);
        assert!(pool.free_bytes() <= 64 << 20);
    }

    #[test]
    fn free_buffers_never_exceed_the_budget_whatever_the_sizes() {
        let pool = BufferPool::new(1 << 20);
        for n in 1..300usize {
            drop(pool.take(n * 4096));
            assert!(pool.free_bytes() <= 1 << 20, "{} free after size {n}", pool.free_bytes());
        }
    }

    #[test]
    fn a_truncated_buffer_shows_the_picture_and_returns_whole() {
        let pool = BufferPool::new(1 << 20);
        let mut b = pool.take(100);
        b.truncate(64);
        assert_eq!(b.len(), 64);
        drop(b);
        assert_eq!(pool.take(100).len(), 100, "it came back under its full size");
        assert_eq!(pool.counts().0, 1);
    }

    #[test]
    fn plain_vectors_and_handed_over_vectors_never_return() {
        let pool = BufferPool::new(1 << 20);
        drop(PooledBytes::from(vec![1u8; 10]));
        let v = pool.take(10).into_vec();
        assert_eq!(v.len(), 10);
        assert_eq!(pool.free_bytes(), 0);
    }
}
