//! Real present timestamps of the window's CAMetalLayer: when each drawable reached the glass (`MTLDrawable.presentedTime`).
//! wgpu acquires and presents the drawables itself and gives no handle to them, so `nextDrawable` of the window's layer is
//! wrapped once: each drawable it returns gets a presented handler, which reports `(sequence number, time)`. The sequence
//! number counts the layer's acquisitions, so the window can tell which present a time belongs to.

use block2::RcBlock;
use objc2::runtime::{AnyObject, Imp, Sel};
use objc2::{msg_send, sel};
use std::ffi::{c_int, c_void};
use std::sync::atomic::{AtomicBool, AtomicPtr, AtomicUsize, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};

#[repr(C)]
struct MachTimebase {
    numer: u32,
    denom: u32,
}

unsafe extern "C" {
    fn mach_timebase_info(info: *mut MachTimebase) -> c_int;
    fn mach_absolute_time() -> u64;
}

type NextDrawable = unsafe extern "C-unwind" fn(*mut AnyObject, Sel) -> *mut AnyObject;

/// The wrapped layer's address (0: none) and the method this wrapper replaced.
static LAYER: AtomicUsize = AtomicUsize::new(0);
static ORIGINAL: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());

struct Hooks {
    acquired: Box<dyn Fn() -> u64 + Send + Sync>,
    presented: Arc<dyn Fn(u64, Instant) + Send + Sync>,
}

static HOOKS: OnceLock<Hooks> = OnceLock::new();
/// Keeps the wrapped layer alive (see `install_glass_clock`).
struct KeptLayer(#[allow(dead_code)] objc2::rc::Retained<AnyObject>);
// SAFETY: only held, never messaged, from any thread.
unsafe impl Send for KeptLayer {}
static KEPT: std::sync::Mutex<Option<KeptLayer>> = std::sync::Mutex::new(None);
static FIRST_REPORTED: AtomicBool = AtomicBool::new(false);

/// `presentedTime` (seconds of the mach clock) as an `Instant`.
fn instant_of(media_secs: f64) -> Option<Instant> {
    let mut base = MachTimebase { numer: 0, denom: 0 };
    // SAFETY: plain mach calls.
    let ticks = unsafe {
        mach_timebase_info(&mut base);
        mach_absolute_time()
    };
    if base.denom == 0 {
        return None;
    }
    let now_secs = ticks as f64 * f64::from(base.numer) / f64::from(base.denom) / 1e9;
    let now = Instant::now();
    let delta = media_secs - now_secs;
    if delta >= 0.0 {
        now.checked_add(Duration::from_secs_f64(delta))
    } else {
        now.checked_sub(Duration::from_secs_f64(-delta))
    }
}

unsafe extern "C-unwind" fn next_drawable(this: *mut AnyObject, cmd: Sel) -> *mut AnyObject {
    let original = ORIGINAL.load(Ordering::Acquire);
    if original.is_null() {
        return std::ptr::null_mut();
    }
    // SAFETY: `original` is the `Imp` of `-[CAMetalLayer nextDrawable]` stored by `install`, called with its own signature.
    let drawable = unsafe { std::mem::transmute::<*mut c_void, NextDrawable>(original)(this, cmd) };
    if !drawable.is_null()
        && this as usize == LAYER.load(Ordering::Acquire)
        && let Some(hooks) = HOOKS.get()
    {
        let seq = (hooks.acquired)();
        let report = Arc::clone(&hooks.presented);
        let block = RcBlock::new(move |d: *mut AnyObject| {
            // SAFETY: `d` is the presented drawable the system passes to its handler; `presentedTime` is a getter (0: it was
            // never shown).
            let secs: f64 = unsafe { msg_send![d, presentedTime] };
            if secs > 0.0
                && let Some(at) = instant_of(secs)
            {
                if !FIRST_REPORTED.swap(true, Ordering::Relaxed) {
                    eprintln!("glass clock: first presented time received (drawable {seq})");
                }
                report(seq, at);
            }
        });
        // SAFETY: `drawable` is the live `id<CAMetalDrawable>` just returned; the handler block is copied by the call.
        unsafe {
            let _: () = msg_send![drawable, addPresentedHandler: &*block];
        }
    }
    drawable
}

/// The first CAMetalLayer in the tree below (or at) `layer`, or null.
fn find_metal_layer(layer: *mut AnyObject, depth: u32) -> *mut AnyObject {
    if layer.is_null() || depth > 6 {
        return std::ptr::null_mut();
    }
    // SAFETY: getters on live layers of the window's layer tree (main thread, called from the window loop); `sublayers` is
    // nil or an NSArray whose elements are layers.
    unsafe {
        let metal: bool = msg_send![layer, isKindOfClass: objc2::class!(CAMetalLayer)];
        if metal {
            return layer;
        }
        let subs: *mut AnyObject = msg_send![layer, sublayers];
        if subs.is_null() {
            return std::ptr::null_mut();
        }
        let count: usize = msg_send![subs, count];
        for i in 0..count {
            let child: *mut AnyObject = msg_send![subs, objectAtIndex: i];
            let found = find_metal_layer(child, depth + 1);
            if !found.is_null() {
                return found;
            }
        }
    }
    std::ptr::null_mut()
}

/// Reports when each drawable of the layer of `ns_view` (the window's view) reaches the glass: `acquired()` gives the
/// sequence number of a new drawable, `presented(seq, at)` is called on a system thread with its glass time. Call after the
/// first frame was presented (the view's layer exists then). `true`: installed.
pub fn install_glass_clock(
    ns_view: *mut c_void,
    acquired: impl Fn() -> u64 + Send + Sync + 'static,
    presented: impl Fn(u64, Instant) + Send + Sync + 'static,
) -> bool {
    if ns_view.is_null() || HOOKS.get().is_some() {
        return false;
    }
    // SAFETY: `ns_view` is the window's live NSView (the caller holds the window); `layer` is a getter.
    let root: *mut AnyObject = unsafe { msg_send![ns_view as *mut AnyObject, layer] };
    // wgpu hosts its CAMetalLayer as a sublayer of the view's own layer, so the layer tree is searched.
    let layer = find_metal_layer(root, 0);
    if layer.is_null() {
        eprintln!("glass clock: no CAMetalLayer found under the window view's layer");
        return false;
    }
    if HOOKS.set(Hooks { acquired: Box::new(acquired), presented: Arc::new(presented) }).is_err() {
        return false;
    }
    // The layer stays retained for the life of the process, so its address is never reused by another object.
    // SAFETY: `layer` is a live object (found in the view's layer tree above).
    let Some(kept) = (unsafe { objc2::rc::Retained::retain(layer) }) else { return false };
    *KEPT.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = Some(KeptLayer(kept));
    let Some(method) = objc2::class!(CAMetalLayer).instance_method(sel!(nextDrawable)) else {
        return false;
    };
    // The replaced method is stored before the swap: a `nextDrawable` in between must find it.
    ORIGINAL.store(method.implementation() as *mut c_void, Ordering::Release);
    LAYER.store(layer as usize, Ordering::Release);
    let wrapper: NextDrawable = next_drawable;
    // SAFETY: the wrapper has the signature of `-[CAMetalLayer nextDrawable]` and calls the replaced method.
    unsafe { method.set_implementation(std::mem::transmute::<NextDrawable, Imp>(wrapper)) };
    eprintln!("glass clock: installed on the window's CAMetalLayer");
    true
}
