// Swift: OnnxModel.swift
//! One ONNX model on ONNX Runtime. Float32 inputs and outputs only.

use std::collections::HashMap;
use std::fmt;

/// Error text capacity of the C face.
const ERR_CAP: usize = 512;

/// A float32 tensor handed to or returned from a model.
#[derive(Clone, Debug, PartialEq)]
pub struct OnnxTensor {
    /// Dimensions.
    pub shape: Vec<i64>,
    /// Row-major elements.
    pub data: Vec<f32>,
}

impl OnnxTensor {
    /// A tensor over `data`. Panics when the shape does not match the data (Swift traps in a precondition).
    pub fn new(shape: Vec<i64>, data: Vec<f32>) -> OnnxTensor {
        assert!(shape.iter().product::<i64>() == data.len() as i64, "OnnxTensor shape does not match its data");
        OnnxTensor { shape, data }
    }

    /// A zero tensor.
    pub fn zeros(shape: Vec<i64>) -> OnnxTensor {
        let count = shape.iter().product::<i64>().max(0) as usize;
        OnnxTensor::new(shape, vec![0.0; count])
    }
}

/// The ONNX execution provider a session asks for. The numbers are the `SQORT_*` values of `vendor/csqonnx.h`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Provider {
    /// The CPU provider.
    Cpu = 0,
    /// DirectML (Windows, any DirectX 12 GPU).
    DirectMl = 1,
    /// Core ML (Mac).
    CoreMl = 2,
}

const NOT_FORCED: u8 = 255;
static FORCED: std::sync::atomic::AtomicU8 = std::sync::atomic::AtomicU8::new(NOT_FORCED);

impl Provider {
    /// The accelerator of this platform: DirectML on Windows, Core ML on the Mac, the CPU elsewhere.
    pub fn platform_default() -> Provider {
        if cfg!(windows) {
            Provider::DirectMl
        } else if cfg!(target_os = "macos") {
            Provider::CoreMl
        } else {
            Provider::Cpu
        }
    }

    /// Parses the value of `SQ_ONNX_PROVIDER` (`cpu`, `directml`, `coreml`, `auto`); `None` for `auto` and unknown text.
    pub fn parse(text: &str) -> Option<Provider> {
        match text.trim().to_ascii_lowercase().as_str() {
            "cpu" => Some(Provider::Cpu),
            "directml" | "dml" => Some(Provider::DirectMl),
            "coreml" => Some(Provider::CoreMl),
            _ => None,
        }
    }

    /// The one place that decides the provider. `SQ_ONNX_PROVIDER` = `cpu`, `directml` or `coreml` forces it for every model;
    /// `auto` (the default) takes the platform accelerator for models whose caller `accelerate`s and the CPU for the rest.
    /// The old `SQ_ONNX_CPU` still means `cpu`.
    pub fn choose(accelerate: bool) -> Provider {
        if let Some(forced) = Self::forced() {
            return forced;
        }
        Self::choose_from(
            std::env::var("SQ_ONNX_PROVIDER").ok().as_deref(),
            std::env::var_os("SQ_ONNX_CPU").is_some(),
            accelerate,
        )
    }

    /// Forces one provider for every model opened afterwards (`None` = back to the setting). For tests and tools that compare
    /// providers inside one process (the environment is not safe to change at run time); it wins over `SQ_ONNX_PROVIDER`.
    pub fn force(provider: Option<Provider>) {
        FORCED.store(provider.map_or(NOT_FORCED, |p| p as u8), std::sync::atomic::Ordering::SeqCst);
    }

    fn forced() -> Option<Provider> {
        match FORCED.load(std::sync::atomic::Ordering::SeqCst) {
            0 => Some(Provider::Cpu),
            1 => Some(Provider::DirectMl),
            2 => Some(Provider::CoreMl),
            _ => None,
        }
    }

    fn choose_from(setting: Option<&str>, legacy_cpu: bool, accelerate: bool) -> Provider {
        if let Some(forced) = setting.and_then(Provider::parse) {
            return forced;
        }
        if legacy_cpu || !accelerate {
            return Provider::Cpu;
        }
        // shortcut: `auto` stays on the CPU on the Mac: EdgeTAM measured 2026-11-09 under Core ML is slower than the CPU (986 vs 755 ms
        // per frame, 14 s model load); upgrade when a newer Core ML or a re-exported model beats the CPU. `SQ_ONNX_PROVIDER=coreml` forces it.
        if cfg!(target_os = "macos") { Provider::Cpu } else { Provider::platform_default() }
    }
}

/// Why the runtime or a model could not be used.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum OnnxError {
    /// The runtime cannot be loaded (off Windows, or the DLL is missing).
    Unavailable(String),
    /// Opening or running a model failed.
    Failed(String),
}

impl fmt::Display for OnnxError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            OnnxError::Unavailable(s) | OnnxError::Failed(s) => f.write_str(s),
        }
    }
}

impl std::error::Error for OnnxError {}

/// The six calls of `vendor/csqonnx.h` behind safe wrappers; the only unsafe code of the crate.
#[allow(unsafe_code, reason = "FFI to the vendored C face over ONNX Runtime")]
mod ffi {
    use super::{ERR_CAP, OnnxError};
    use std::ffi::{CStr, CString, c_char, c_int, c_void};
    use std::ptr::NonNull;

    #[repr(C)]
    struct RawSession {
        _private: [u8; 0],
    }

    unsafe extern "C" {
        fn sqort_load(dll: *const c_char, err: *mut c_char, cap: c_int) -> c_int;
        fn sqort_available() -> c_int;
        fn sqort_open(
            model: *const c_char,
            provider: c_int,
            device: c_int,
            threads: c_int,
            err: *mut c_char,
            cap: c_int,
        ) -> *mut RawSession;
        fn sqort_close(s: *mut RawSession);
        fn sqort_provider(s: *mut RawSession) -> *const c_char;
        fn sqort_fallback_reason(s: *mut RawSession) -> *const c_char;
        fn sqort_input_count(s: *mut RawSession) -> c_int;
        fn sqort_output_count(s: *mut RawSession) -> c_int;
        fn sqort_input_name(s: *mut RawSession, i: c_int) -> *const c_char;
        fn sqort_output_name(s: *mut RawSession, i: c_int) -> *const c_char;
        fn sqort_run(
            s: *mut RawSession,
            in_data: *const *const f32,
            in_shapes: *const *const i64,
            in_ranks: *const c_int,
            out_data: *mut *mut f32,
            out_counts: *mut i64,
            out_ranks: *mut c_int,
            out_dims: *mut i64,
            err: *mut c_char,
            cap: c_int,
        ) -> c_int;
        fn sqort_run_typed(
            s: *mut RawSession,
            in_types: *const c_int,
            in_data: *const *const c_void,
            in_shapes: *const *const i64,
            in_ranks: *const c_int,
            n_want: c_int,
            want: *const c_int,
            out_data: *mut *mut c_void,
            out_types: *mut c_int,
            out_counts: *mut i64,
            out_ranks: *mut c_int,
            out_dims: *mut i64,
            err: *mut c_char,
            cap: c_int,
        ) -> c_int;
        fn sqort_free(p: *mut c_void);
    }

    /// One typed input: ONNX element type, data pointer and the shape.
    pub struct RawInput<'a> {
        pub elem_type: i32,
        pub data: *const c_void,
        pub shape: &'a [i64],
    }

    /// One typed output as the C face returns it: the bytes are copied here.
    pub struct RawTyped {
        pub elem_type: i32,
        pub shape: Vec<i64>,
        pub count: usize,
        pub bytes: Vec<u8>,
    }

    /// One output as the C face returns it.
    pub struct RawOutput {
        pub shape: Vec<i64>,
        pub data: Vec<f32>,
    }

    fn message(buf: &[c_char; ERR_CAP]) -> String {
        // SAFETY: the C face always writes a NUL-terminated string into `buf` (snprintf) or leaves the zeroed buffer as is.
        unsafe { CStr::from_ptr(buf.as_ptr()) }.to_string_lossy().into_owned()
    }

    fn c_string(s: &str) -> Result<CString, OnnxError> {
        CString::new(s).map_err(|_| OnnxError::Failed(format!("path contains a NUL byte: {s}")))
    }

    pub fn load(dll: Option<&str>) -> Result<(), OnnxError> {
        let path = dll.map(c_string).transpose()?;
        let mut err = [0 as c_char; ERR_CAP];
        // SAFETY: `path` is NULL or a valid C string that outlives the call; `err` is writable for ERR_CAP bytes.
        let rc = unsafe {
            sqort_load(path.as_ref().map_or(std::ptr::null(), |p| p.as_ptr()), err.as_mut_ptr(), ERR_CAP as c_int)
        };
        if rc != 0 { Err(OnnxError::Unavailable(message(&err))) } else { Ok(()) }
    }

    pub fn available() -> bool {
        // SAFETY: no arguments; reads a process-wide flag of the C face.
        unsafe { sqort_available() != 0 }
    }

    /// An open session; closed on drop.
    pub struct Session(NonNull<RawSession>);

    // SAFETY: ONNX Runtime sessions may be used from any thread (Run is thread-safe), the C face keeps no per-thread state
    // and `Session` is only ever dropped once. The Swift class is `@unchecked Sendable` for the same reason.
    unsafe impl Send for Session {}
    // SAFETY: see above; every method takes `&self` and the C face does not mutate the session outside ONNX Runtime calls.
    unsafe impl Sync for Session {}

    impl Session {
        pub fn open(path: &str, provider: super::Provider, device: i32, threads: i32) -> Result<Session, OnnxError> {
            let model = c_string(path)?;
            let mut err = [0 as c_char; ERR_CAP];
            // SAFETY: `model` is a valid C string and `err` is writable for ERR_CAP bytes, both for the whole call.
            let raw = unsafe {
                sqort_open(model.as_ptr(), provider as c_int, device, threads, err.as_mut_ptr(), ERR_CAP as c_int)
            };
            NonNull::new(raw).map(Session).ok_or_else(|| OnnxError::Failed(message(&err)))
        }

        fn text(&self, f: unsafe extern "C" fn(*mut RawSession) -> *const c_char) -> String {
            // SAFETY: the session is open; the C face returns a NUL-terminated string owned by it (never NULL for an open session).
            unsafe {
                let p = f(self.0.as_ptr());
                if p.is_null() { String::new() } else { CStr::from_ptr(p).to_string_lossy().into_owned() }
            }
        }

        /// The provider that runs this session ("cpu", "directml", "coreml").
        pub fn provider(&self) -> String {
            self.text(sqort_provider)
        }

        /// Why the asked provider was not used (empty when it was).
        pub fn fallback_reason(&self) -> String {
            self.text(sqort_fallback_reason)
        }

        fn names(
            &self,
            count: unsafe extern "C" fn(*mut RawSession) -> c_int,
            name: unsafe extern "C" fn(*mut RawSession, c_int) -> *const c_char,
        ) -> Vec<String> {
            // SAFETY: the session is open; names are NUL-terminated strings owned by it and valid until it closes.
            unsafe {
                (0..count(self.0.as_ptr()))
                    .map(|i| {
                        let p = name(self.0.as_ptr(), i);
                        if p.is_null() { String::new() } else { CStr::from_ptr(p).to_string_lossy().into_owned() }
                    })
                    .collect()
            }
        }

        pub fn input_names(&self) -> Vec<String> {
            self.names(sqort_input_count, sqort_input_name)
        }

        pub fn output_names(&self) -> Vec<String> {
            self.names(sqort_output_count, sqort_output_name)
        }

        /// Runs the model on `inputs` (data, shape) in the model's input order; `outputs` is the output count.
        pub fn run(&self, inputs: &[(&[f32], &[i64])], outputs: usize) -> Result<Vec<RawOutput>, OnnxError> {
            let data: Vec<*const f32> = inputs.iter().map(|(d, _)| d.as_ptr()).collect();
            let shapes: Vec<*const i64> = inputs.iter().map(|(_, s)| s.as_ptr()).collect();
            let ranks: Vec<c_int> = inputs.iter().map(|(_, s)| s.len() as c_int).collect();
            let mut out_data = vec![std::ptr::null_mut::<f32>(); outputs];
            let mut counts = vec![0_i64; outputs];
            let mut out_ranks = vec![0 as c_int; outputs];
            let mut dims = vec![0_i64; outputs * 8];
            let mut err = [0 as c_char; ERR_CAP];
            // SAFETY: the pointer arrays have one entry per model input / output (the caller matched them to the names), the
            // input slices outlive the call, `dims` holds 8 entries per output, `err` is writable for ERR_CAP bytes.
            let rc = unsafe {
                sqort_run(
                    self.0.as_ptr(),
                    data.as_ptr(),
                    shapes.as_ptr(),
                    ranks.as_ptr(),
                    out_data.as_mut_ptr(),
                    counts.as_mut_ptr(),
                    out_ranks.as_mut_ptr(),
                    dims.as_mut_ptr(),
                    err.as_mut_ptr(),
                    ERR_CAP as c_int,
                )
            };
            if rc != 0 {
                return Err(OnnxError::Failed(message(&err)));
            }
            Ok((0..outputs)
                .map(|i| {
                    let n = usize::try_from(counts[i]).unwrap_or(0);
                    let rank = usize::try_from(out_ranks[i]).unwrap_or(0).min(8);
                    // SAFETY: on success the C face stored a malloc'd buffer of `counts[i]` floats (or NULL) in `out_data[i]`;
                    // it is copied here and then freed exactly once with `sqort_free`.
                    let data = unsafe {
                        let p = out_data[i];
                        let copy = if p.is_null() { Vec::new() } else { std::slice::from_raw_parts(p, n).to_vec() };
                        sqort_free(p.cast());
                        copy
                    };
                    RawOutput { shape: dims[i * 8..i * 8 + rank].to_vec(), data }
                })
                .collect())
        }
    }

    impl Session {
        /// Runs the model on typed `inputs` (model input order) and fetches the outputs at the indices in `want`.
        pub fn run_typed(&self, inputs: &[RawInput<'_>], want: &[i32]) -> Result<Vec<RawTyped>, OnnxError> {
            let types: Vec<c_int> = inputs.iter().map(|i| i.elem_type).collect();
            let data: Vec<*const c_void> = inputs.iter().map(|i| i.data).collect();
            let shapes: Vec<*const i64> = inputs.iter().map(|i| i.shape.as_ptr()).collect();
            let ranks: Vec<c_int> = inputs.iter().map(|i| i.shape.len() as c_int).collect();
            let n = want.len();
            let mut out_data = vec![std::ptr::null_mut::<c_void>(); n];
            let mut out_types = vec![0 as c_int; n];
            let mut counts = vec![0_i64; n];
            let mut out_ranks = vec![0 as c_int; n];
            let mut dims = vec![0_i64; n * 8];
            let mut err = [0 as c_char; ERR_CAP];
            // SAFETY: one entry per model input in the input arrays (the caller matched them to the names) whose data pointers
            // outlive the call, `want` holds valid output indices, `dims` holds 8 entries per fetched output, `err` is writable.
            let rc = unsafe {
                sqort_run_typed(
                    self.0.as_ptr(),
                    types.as_ptr(),
                    data.as_ptr(),
                    shapes.as_ptr(),
                    ranks.as_ptr(),
                    n as c_int,
                    want.as_ptr(),
                    out_data.as_mut_ptr(),
                    out_types.as_mut_ptr(),
                    counts.as_mut_ptr(),
                    out_ranks.as_mut_ptr(),
                    dims.as_mut_ptr(),
                    err.as_mut_ptr(),
                    ERR_CAP as c_int,
                )
            };
            if rc != 0 {
                return Err(OnnxError::Failed(message(&err)));
            }
            Ok((0..n)
                .map(|k| {
                    let count = usize::try_from(counts[k]).unwrap_or(0);
                    let rank = usize::try_from(out_ranks[k]).unwrap_or(0).min(8);
                    let size = match out_types[k] {
                        1 => 4,
                        7 => 8,
                        _ => 1,
                    };
                    // SAFETY: on success the C face stored a malloc'd buffer of `count * size` bytes in `out_data[k]`; it is
                    // copied here and then freed exactly once with `sqort_free`.
                    let bytes = unsafe {
                        let p = out_data[k];
                        let copy = if p.is_null() {
                            Vec::new()
                        } else {
                            std::slice::from_raw_parts(p.cast::<u8>(), count * size).to_vec()
                        };
                        sqort_free(p);
                        copy
                    };
                    RawTyped { elem_type: out_types[k], shape: dims[k * 8..k * 8 + rank].to_vec(), count, bytes }
                })
                .collect())
        }
    }

    impl Drop for Session {
        fn drop(&mut self) {
            // SAFETY: the session was opened by `sqort_open` and is closed only here.
            unsafe { sqort_close(self.0.as_ptr()) }
        }
    }
}

/// The elements of a [`TypedTensor`].
#[derive(Clone, Debug, PartialEq)]
pub enum TensorData {
    /// ONNX float32.
    F32(Vec<f32>),
    /// ONNX int64 (token ids, masks).
    I64(Vec<i64>),
    /// ONNX bool.
    Bool(Vec<bool>),
}

impl TensorData {
    fn len(&self) -> usize {
        match self {
            TensorData::F32(v) => v.len(),
            TensorData::I64(v) => v.len(),
            TensorData::Bool(v) => v.len(),
        }
    }
}

/// A tensor of any of the supported element types (text models: int64 ids and masks, a bool switch, float32 states).
#[derive(Clone, Debug, PartialEq)]
pub struct TypedTensor {
    /// Dimensions (a 0 is allowed: an empty cache).
    pub shape: Vec<i64>,
    /// Row-major elements.
    pub data: TensorData,
}

impl TypedTensor {
    /// A tensor over `data`. Panics when the shape does not match the data.
    pub fn new(shape: Vec<i64>, data: TensorData) -> TypedTensor {
        assert!(shape.iter().product::<i64>() == data.len() as i64, "TypedTensor shape does not match its data");
        TypedTensor { shape, data }
    }
}

/// One ONNX model on ONNX Runtime. Float32 inputs and outputs only (all five EdgeTAM parts are). Calls on one model are
/// serialized by the caller (ONNX Runtime allows parallel runs, DirectML on one device gains nothing from them).
pub struct OnnxModel {
    session: ffi::Session,
    /// Input names in the model's order.
    pub input_names: Vec<String>,
    /// Output names in the model's order.
    pub output_names: Vec<String>,
    /// The provider that runs this model: "cpu", "directml" or "coreml" (the CPU when the accelerator refused the model).
    pub provider: String,
}

impl OnnxModel {
    /// Loads the runtime once (`dll`: a full path to onnxruntime.dll; `None` = next to the exe or on PATH). Fails with
    /// `Unavailable` when it cannot (the Mac, or the DLL is missing).
    pub fn load_runtime(dll: Option<&str>) -> Result<(), OnnxError> {
        ffi::load(dll)
    }

    /// Whether a runtime is loaded.
    pub fn is_available() -> bool {
        ffi::available()
    }

    /// `accelerate`: let the platform accelerator run it (DirectML on adapter `device`, `None` = the default; Core ML on the Mac),
    /// the CPU for what it does not take; `SQ_ONNX_PROVIDER` overrides ([`Provider::choose`]). A provider that cannot open
    /// the model falls back to the CPU, and one log line on stderr names the provider that runs. `threads` 0 = the runtime's default.
    pub fn new(path: &str, accelerate: bool, device: Option<i32>, threads: i32) -> Result<OnnxModel, OnnxError> {
        Self::with_provider(path, Provider::choose(accelerate), device, threads)
    }

    /// Like [`OnnxModel::new`] with the provider named (the CPU fallback and the log line stay).
    #[allow(clippy::print_stderr, reason = "the one log line saying which provider ran")]
    pub fn with_provider(
        path: &str,
        asked: Provider,
        device: Option<i32>,
        threads: i32,
    ) -> Result<OnnxModel, OnnxError> {
        if !Self::is_available() {
            Self::load_runtime(None)?;
        }
        let session = ffi::Session::open(path, asked, device.unwrap_or(-1), threads)?;
        let provider = session.provider();
        let name = path.rsplit(['/', '\\']).next().unwrap_or(path);
        match session.fallback_reason() {
            why if why.is_empty() => eprintln!("onnx: {name} runs on {provider}"),
            why => eprintln!("onnx: {name} runs on {provider} ({asked:?} refused it: {why})"),
        }
        let input_names = session.input_names();
        let output_names = session.output_names();
        Ok(OnnxModel { session, input_names, output_names, provider })
    }

    /// Runs the model. `inputs` are matched by name; every input the model has must be given (extras are ignored).
    /// The outputs come back in `output_names` order.
    pub fn run(&self, inputs: &HashMap<String, OnnxTensor>) -> Result<Vec<OnnxTensor>, OnnxError> {
        let mut ordered: Vec<(&[f32], &[i64])> = Vec::new();
        for name in &self.input_names {
            let t = inputs.get(name).ok_or_else(|| OnnxError::Failed(format!("missing input {name}")))?;
            ordered.push((&t.data, &t.shape));
        }
        let outputs = self.session.run(&ordered, self.output_names.len())?;
        Ok(outputs.into_iter().map(|o| OnnxTensor { shape: o.shape, data: o.data }).collect())
    }
}

impl OnnxModel {
    /// Runs the model with typed inputs (matched by name, every model input must be given) and returns the outputs named in
    /// `wanted`, in that order (the other outputs are not copied out).
    pub fn run_typed(
        &self,
        inputs: &HashMap<String, TypedTensor>,
        wanted: &[&str],
    ) -> Result<Vec<TypedTensor>, OnnxError> {
        let mut ordered: Vec<&TypedTensor> = Vec::new();
        for name in &self.input_names {
            ordered.push(inputs.get(name).ok_or_else(|| OnnxError::Failed(format!("missing input {name}")))?);
        }
        // Bool tensors go to the C face as one byte each; the buffers live until the run is over.
        let bool_bytes: Vec<Vec<u8>> = ordered
            .iter()
            .map(|t| match &t.data {
                TensorData::Bool(v) => v.iter().map(|b| u8::from(*b)).collect(),
                _ => Vec::new(),
            })
            .collect();
        let raw: Vec<ffi::RawInput<'_>> = ordered
            .iter()
            .zip(&bool_bytes)
            .map(|(t, bytes)| {
                let (elem_type, data) = match &t.data {
                    TensorData::F32(v) => (1, v.as_ptr().cast()),
                    TensorData::I64(v) => (7, v.as_ptr().cast()),
                    TensorData::Bool(_) => (9, bytes.as_ptr().cast()),
                };
                ffi::RawInput { elem_type, data, shape: &t.shape }
            })
            .collect();
        let mut want = Vec::new();
        for name in wanted {
            let i = self
                .output_names
                .iter()
                .position(|o| o == name)
                .ok_or_else(|| OnnxError::Failed(format!("the model has no output {name}")))?;
            want.push(i as i32);
        }
        let outs = self.session.run_typed(&raw, &want)?;
        outs.into_iter()
            .map(|o| {
                let data = match o.elem_type {
                    1 => TensorData::F32(o.bytes.as_chunks::<4>().0.iter().map(|c| f32::from_le_bytes(*c)).collect()),
                    7 => TensorData::I64(o.bytes.as_chunks::<8>().0.iter().map(|c| i64::from_le_bytes(*c)).collect()),
                    9 => TensorData::Bool(o.bytes.iter().map(|b| *b != 0).collect()),
                    t => return Err(OnnxError::Failed(format!("an output has the unsupported type {t}"))),
                };
                let _ = o.count;
                Ok(TypedTensor { shape: o.shape, data })
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tensor_keeps_its_shape() {
        let t = OnnxTensor::zeros(vec![2, 3]);
        assert_eq!(t.data.len(), 6);
    }

    #[test]
    #[should_panic(expected = "shape does not match")]
    fn tensor_refuses_a_wrong_shape() {
        let _ = OnnxTensor::new(vec![2, 2], vec![0.0]);
    }

    #[test]
    fn the_provider_choice_follows_the_setting() {
        let auto = if cfg!(target_os = "macos") { Provider::Cpu } else { Provider::platform_default() };
        assert_eq!(Provider::choose_from(None, false, true), auto);
        assert_eq!(Provider::choose_from(Some("auto"), false, true), auto);
        assert_eq!(Provider::choose_from(None, false, false), Provider::Cpu);
        assert_eq!(Provider::choose_from(Some("cpu"), false, true), Provider::Cpu);
        assert_eq!(Provider::choose_from(None, true, true), Provider::Cpu);
        assert_eq!(Provider::choose_from(Some("DirectML"), false, false), Provider::DirectMl);
        assert_eq!(Provider::choose_from(Some("coreml"), true, false), Provider::CoreMl);
        assert_eq!(Provider::choose_from(Some("nonsense"), false, true), auto);
        Provider::force(Some(Provider::Cpu));
        assert_eq!(Provider::choose(true), Provider::Cpu);
        Provider::force(None);
    }

    #[cfg(not(windows))]
    #[test]
    fn a_missing_runtime_is_unavailable_not_a_crash() {
        assert!(matches!(OnnxModel::load_runtime(None), Err(OnnxError::Unavailable(_))));
        assert!(!OnnxModel::is_available());
        assert!(OnnxModel::new("/nope.onnx", false, None, 0).is_err());
    }

    #[cfg(windows)]
    #[test]
    fn a_missing_runtime_is_unavailable_not_a_crash() {
        let r = OnnxModel::load_runtime(Some("C:/does-not-exist/onnxruntime.dll"));
        assert!(matches!(r, Err(OnnxError::Unavailable(_))));
    }

    /// With `SQ_ONNXRUNTIME_LIB` set to a runtime library the real loader must accept it (the Mac dlopen path, the PC LoadLibrary).
    #[test]
    fn a_real_runtime_library_loads_when_given() {
        let Ok(lib) = std::env::var("SQ_ONNXRUNTIME_LIB") else { return };
        assert!(OnnxModel::load_runtime(Some(&lib)).is_ok(), "cannot load {lib}");
        assert!(OnnxModel::is_available());
    }

    /// Any float32 model through every provider of this platform: `SQ_ONNX_TEST_MODEL` (one input), `SQ_ONNX_TEST_SHAPE` (`1,3,640,640`),
    /// `SQ_ONNXRUNTIME_LIB`. The outputs must agree within 1e-2 of max(1, largest value); times go to stderr.
    #[test]
    fn the_accelerator_gives_the_cpu_outputs_within_tolerance() {
        let (Ok(model), Ok(shape), Ok(lib)) = (
            std::env::var("SQ_ONNX_TEST_MODEL"),
            std::env::var("SQ_ONNX_TEST_SHAPE"),
            std::env::var("SQ_ONNXRUNTIME_LIB"),
        ) else {
            return;
        };
        assert!(OnnxModel::load_runtime(Some(&lib)).is_ok());
        let dims: Vec<i64> = shape.split(',').filter_map(|d| d.trim().parse().ok()).collect();
        let count = dims.iter().product::<i64>() as usize;
        let data: Vec<f32> = (0..count).map(|i| ((i * 37 % 255) as f32) / 255.0).collect();
        let mut results = Vec::new();
        for provider in [Provider::Cpu, Provider::platform_default()] {
            let m = OnnxModel::with_provider(&model, provider, None, 0).expect("model opens");
            let input = HashMap::from([(m.input_names[0].clone(), OnnxTensor::new(dims.clone(), data.clone()))]);
            let _ = m.run(&input).expect("warm-up run");
            let start = std::time::Instant::now();
            let mut out = Vec::new();
            for _ in 0..5 {
                out = m.run(&input).expect("run");
            }
            eprintln!("{provider:?} (ran on {}): {:.1} ms per run", m.provider, start.elapsed().as_secs_f64() * 200.0);
            results.push(out);
        }
        for (c, a) in results[0].iter().zip(&results[1]) {
            let scale = c.data.iter().fold(1.0_f32, |m, v| m.max(v.abs()));
            let worst = c.data.iter().zip(&a.data).fold(0.0_f32, |m, (x, y)| m.max((x - y).abs()));
            eprintln!("output {}: worst difference {:.5} of {scale:.3}", c.data.len(), worst);
            assert!(worst <= 1e-2 * scale, "outputs differ: {worst} of {scale}");
        }
    }
}
