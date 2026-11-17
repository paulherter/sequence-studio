//! Async runtime of the UI side: single-threaded executor, worker pool, modal asks, channels, UI root handle. std only.
pub mod channel;
pub mod clock;
pub mod executor;
#[cfg(test)]
mod flows;
pub mod group;
pub mod inbox;
pub mod modal;
pub mod pool;
pub mod proxy_state;
pub mod root;
pub mod testing;

pub use clock::{Clock, FakeClock, SystemClock};
pub use executor::{
    Cancelled, FrameStats, JoinError, JoinHandle, UiExecutor, is_cancelled, sleep, spawn_cooperative, spawn_local,
    yield_now,
};
pub use group::TaskGroup;
pub use inbox::Inbox;
pub use modal::{Dismissed, ModalAnswer, ModalAsk, modal};
pub use pool::{JobCtl, WorkFuture, WorkerPanic, WorkerPool};
pub use root::{UiRef, UiRoot};
