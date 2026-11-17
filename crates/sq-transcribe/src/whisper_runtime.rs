// Swift: WhisperRuntime.swift (the C face is the vendored `vendor/csqwhisper.c`; the only unsafe code of the crate is the
// `ffi` module below)
//! whisper.cpp behind `WhisperEngine`: `whisper.dll` is loaded at run time, so the app starts without it and the Transcribe
//! tab says what is missing. Off Windows the C layer reports "not available" (the Mac uses the Speech framework).

use crate::transcription_service::TranscriptionError;
use crate::whisper_transcriber::WhisperEngine;
use crate::whisper_words::WhisperToken;
use std::sync::{Mutex, MutexGuard, PoisonError};

/// Error text capacity of the C face.
const ERR_CAP: usize = 256;

/// The calls of `vendor/csqwhisper.h` behind safe wrappers; the only unsafe code of the crate.
#[allow(unsafe_code, reason = "FFI to the vendored C face over whisper.cpp")]
mod ffi {
    use super::{ERR_CAP, WhisperToken};
    use std::ffi::{CStr, CString, c_char, c_int, c_void};
    use std::ptr::NonNull;

    #[repr(C)]
    struct RawContext {
        _private: [u8; 0],
    }

    type ProgressFn = extern "C" fn(percent: c_int, user: *mut c_void);
    type CancelFn = extern "C" fn(user: *mut c_void) -> c_int;

    unsafe extern "C" {
        fn sqwh_load(dir: *const c_char, err: *mut c_char, cap: c_int) -> c_int;
        fn sqwh_available() -> c_int;
        fn sqwh_open(model: *const c_char, threads: c_int, err: *mut c_char, cap: c_int) -> *mut RawContext;
        fn sqwh_close(c: *mut RawContext);
        fn sqwh_run(
            c: *mut RawContext,
            samples: *const f32,
            count: c_int,
            language: *const c_char,
            threads: c_int,
            progress: Option<ProgressFn>,
            cancelled: Option<CancelFn>,
            user: *mut c_void,
            err: *mut c_char,
            cap: c_int,
        ) -> c_int;
        fn sqwh_token_count(c: *mut RawContext) -> c_int;
        fn sqwh_token_text(c: *mut RawContext, i: c_int, special: *mut c_int) -> *const c_char;
        fn sqwh_token_info(c: *mut RawContext, i: c_int, t0: *mut i64, t1: *mut i64, p: *mut f32);
    }

    /// How a recognition run ended.
    pub enum RunEnd {
        Done,
        Cancelled,
        Failed(String),
    }

    fn message(buf: &[c_char; ERR_CAP]) -> String {
        // SAFETY: the C face writes a NUL-terminated string into `buf` (snprintf) or leaves the zeroed buffer as it is.
        unsafe { CStr::from_ptr(buf.as_ptr()) }.to_string_lossy().into_owned()
    }

    fn c_string(s: &str) -> Result<CString, String> {
        CString::new(s).map_err(|_| format!("text contains a NUL byte: {s}"))
    }

    /// `None` when the engine library is loaded, else the reason.
    pub fn load(dir: Option<&str>) -> Option<String> {
        // SAFETY: no arguments; reads a process-wide flag of the C face.
        if unsafe { sqwh_available() } != 0 {
            return None;
        }
        let dir = match dir.map(c_string).transpose() {
            Ok(d) => d,
            Err(e) => return Some(e),
        };
        let mut err = [0 as c_char; ERR_CAP];
        // SAFETY: `dir` is NULL or a valid C string that outlives the call; `err` is writable for ERR_CAP bytes.
        let rc = unsafe {
            sqwh_load(dir.as_ref().map_or(std::ptr::null(), |d| d.as_ptr()), err.as_mut_ptr(), ERR_CAP as c_int)
        };
        if rc == 0 { None } else { Some(message(&err)) }
    }

    /// An open model; closed on drop.
    pub struct Context(NonNull<RawContext>);

    // SAFETY: a whisper context is not thread safe, but it is only ever used by one thread at a time: `WhisperRuntime` keeps it
    // behind a `Mutex` (the Swift class serializes runs with an `NSLock` and is `@unchecked Sendable` for the same reason).
    unsafe impl Send for Context {}

    impl Context {
        pub fn open(model: &str) -> Result<Context, String> {
            let model = c_string(model)?;
            let mut err = [0 as c_char; ERR_CAP];
            // SAFETY: `model` is a valid C string and `err` is writable for ERR_CAP bytes, both for the whole call.
            let raw = unsafe { sqwh_open(model.as_ptr(), 0, err.as_mut_ptr(), ERR_CAP as c_int) };
            NonNull::new(raw).map(Context).ok_or_else(|| message(&err))
        }

        /// Recognizes `samples`; the tokens are read with `tokens` afterwards.
        pub fn run(
            &mut self,
            samples: &[f32],
            language: &str,
            threads: i32,
            progress: &mut dyn FnMut(f64),
            is_cancelled: &(dyn Fn() -> bool + Sync),
        ) -> RunEnd {
            let Ok(language) = c_string(language) else { return RunEnd::Failed("language contains a NUL byte".into()) };
            let Ok(count) = c_int::try_from(samples.len()) else {
                return RunEnd::Failed("the audio is too long".into());
            };
            let mut callbacks = Callbacks { progress, is_cancelled };
            let mut err = [0 as c_char; ERR_CAP];
            // SAFETY: `self.0` is an open context; `samples` holds `count` floats and `language` is a valid C string for the
            // whole call; `callbacks` lives on this stack frame until `sqwh_run` returns, and the trampolines only use it through
            // the `user` pointer given here; `err` is writable for ERR_CAP bytes.
            let rc = unsafe {
                sqwh_run(
                    self.0.as_ptr(),
                    samples.as_ptr(),
                    count,
                    language.as_ptr(),
                    threads,
                    Some(progress_trampoline),
                    Some(cancel_trampoline),
                    (&mut callbacks as *mut Callbacks<'_>).cast::<c_void>(),
                    err.as_mut_ptr(),
                    ERR_CAP as c_int,
                )
            };
            match rc {
                0 => RunEnd::Done,
                2 => RunEnd::Cancelled,
                _ => RunEnd::Failed(message(&err)),
            }
        }

        /// The tokens of the last run, flattened over all segments.
        pub fn tokens(&mut self) -> Vec<WhisperToken> {
            // SAFETY: `self.0` is an open context.
            let n = unsafe { sqwh_token_count(self.0.as_ptr()) };
            (0..n)
                .map(|i| {
                    let mut special: c_int = 0;
                    let (mut t0, mut t1, mut p) = (0i64, 0i64, 0f32);
                    // SAFETY: `i` is below the token count; the returned text is NUL terminated and valid until the next run or
                    // close, and is copied before then; the out-pointers are valid for the call.
                    let bytes = unsafe {
                        let text = sqwh_token_text(self.0.as_ptr(), i, &mut special);
                        sqwh_token_info(self.0.as_ptr(), i, &mut t0, &mut t1, &mut p);
                        if text.is_null() { Vec::new() } else { CStr::from_ptr(text).to_bytes().to_vec() }
                    };
                    WhisperToken { bytes, is_special: special != 0, start_cs: t0, end_cs: t1, probability: p }
                })
                .collect()
        }
    }

    impl Drop for Context {
        fn drop(&mut self) {
            // SAFETY: the context is open and dropped once.
            unsafe { sqwh_close(self.0.as_ptr()) }
        }
    }

    /// What the C callbacks reach through the `user` pointer.
    struct Callbacks<'a> {
        progress: &'a mut dyn FnMut(f64),
        is_cancelled: &'a (dyn Fn() -> bool + Sync),
    }

    extern "C" fn progress_trampoline(percent: c_int, user: *mut c_void) {
        if user.is_null() {
            return;
        }
        let cb = user.cast::<Callbacks<'_>>();
        // SAFETY: `user` is the `Callbacks` that `Context::run` keeps alive until `sqwh_run` returns. Only the `progress` field is
        // borrowed (never the whole struct), and the C layer calls this callback from the thread that called `sqwh_run`, so the
        // exclusive borrow of that field is not shared; the cancel trampoline touches the other field only.
        let progress = unsafe { &mut *std::ptr::addr_of_mut!((*cb).progress) };
        progress(f64::from(percent) / 100.0);
    }

    extern "C" fn cancel_trampoline(user: *mut c_void) -> c_int {
        if user.is_null() {
            return 0;
        }
        let cb = user.cast::<Callbacks<'_>>();
        // SAFETY: as above; only the shared `is_cancelled` field is borrowed, and it is `Sync` because ggml may poll it from
        // worker threads.
        let is_cancelled = unsafe { &*std::ptr::addr_of!((*cb).is_cancelled) };
        c_int::from(is_cancelled())
    }
}

/// An open model and the path it was loaded from.
struct Loaded {
    context: ffi::Context,
    path: String,
}

/// whisper.cpp behind `WhisperEngine`: `whisper.dll` is loaded at run time (the vendored C face), so the app starts without it.
pub struct WhisperRuntime {
    /// Where whisper.dll lives (`None`: beside the exe, `SQ_WHISPER_DIR`, then PATH).
    folder: Option<String>,
    /// One run at a time: a context is not thread safe.
    loaded: Mutex<Option<Loaded>>,
}

impl WhisperRuntime {
    /// `folder`: where whisper.dll lives (`None`: beside the exe, `SQ_WHISPER_DIR`, then PATH).
    pub fn new(folder: Option<String>) -> WhisperRuntime {
        WhisperRuntime { folder, loaded: Mutex::new(None) }
    }

    fn lock(&self) -> MutexGuard<'_, Option<Loaded>> {
        self.loaded.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

impl WhisperEngine for WhisperRuntime {
    fn unavailable_reason(&self) -> Option<String> {
        let _guard = self.lock();
        ffi::load(self.folder.as_deref())
    }

    fn recognize(
        &self,
        model_path: &str,
        samples: &[f32],
        language: &str,
        progress: &mut dyn FnMut(f64),
        is_cancelled: &(dyn Fn() -> bool + Sync),
    ) -> Result<Vec<WhisperToken>, TranscriptionError> {
        let mut loaded = self.lock();
        if let Some(why) = ffi::load(self.folder.as_deref()) {
            return Err(TranscriptionError::EngineMissing(why));
        }
        if loaded.as_ref().is_none_or(|l| l.path != model_path) {
            *loaded = None; // closes the old context first
            let context = ffi::Context::open(model_path).map_err(TranscriptionError::EngineMissing)?;
            *loaded = Some(Loaded { context, path: model_path.to_string() });
        }
        let Some(l) = loaded.as_mut() else { return Err(TranscriptionError::EngineMissing("no model loaded".into())) };
        let cores = std::thread::available_parallelism().map_or(1, usize::from);
        let threads = i32::try_from(cores.saturating_sub(1).clamp(2, 8)).unwrap_or(2);
        match l.context.run(samples, language, threads, progress, is_cancelled) {
            ffi::RunEnd::Done => Ok(l.context.tokens()),
            ffi::RunEnd::Cancelled => Err(TranscriptionError::Cancelled),
            ffi::RunEnd::Failed(why) => Err(TranscriptionError::EngineMissing(why)),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The C face is a stub off Windows: the engine says why it cannot run, and `recognize` fails the same way.
    #[cfg(not(windows))]
    #[test]
    fn off_windows_the_engine_is_unavailable() {
        let rt = WhisperRuntime::new(None);
        let why = rt.unavailable_reason();
        assert!(why.is_some());
        let r = rt.recognize("/nonexistent.bin", &[0.0; 16], "de", &mut |_| {}, &|| false);
        assert!(matches!(r, Err(TranscriptionError::EngineMissing(_))));
    }

    #[test]
    fn a_nul_byte_in_the_folder_is_reported_not_passed_on() {
        let rt = WhisperRuntime::new(Some("a\0b".into()));
        assert!(rt.unavailable_reason().is_some());
    }
}
