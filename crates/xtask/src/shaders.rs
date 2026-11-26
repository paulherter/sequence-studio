// SPDX-License-Identifier: GPL-3.0-or-later
//! `cargo xtask shaders`: compiles `crates/sq-gpu/shaders-src/*.slang` with slangc and writes the committed outputs to
//! `crates/sq-gpu/shaders/`: MSL per module, DXIL per entry, `reflection.json` (the checked summary) and
//! `entries.rs` (the table `sq-gpu` embeds). Contributors without slangc build from the committed outputs.
//! DXIL needs the Windows `dxcompiler.dll`, so it is only (re)written on Windows; elsewhere the committed files stay.
//! SPIR-V per entry (`shaders/spirv/<Module>.<entry>.spv`, for Vulkan on Linux) is written on every platform: slangc needs no
//! extra compiler for it.
//! Every module's reflection is checked against the fixed 35-entry binding layout (docs/rust/render-playback-export-design.md).

use crate::json::Json;
use std::collections::BTreeMap;
use std::fmt::Write as _;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};

/// Largest constant block a pass may set (`sq-gpu` uniform arena window).
const MAX_CONSTANT_BYTES: u64 = 4096;
const WARN: [&str; 2] = ["-warnings-disable", "39029,39001"];
/// SPIR-V binding shifts that give the fixed layout: b0..b1 -> 0..1, t0..t24 -> 2..26, u0..u4 -> 27..31, s0..s2 -> 32..34.
const FIXED_SHIFTS: [&str; 4] = ["0", "2", "27", "32"];
/// DrawQuads has its own layout: b0 -> 0, t0..t9 -> 1..10, s0..s2 -> 11..13.
const DRAW_SHIFTS: [&str; 4] = ["0", "1", "27", "11"];
const DRAW_MODULE: &str = "DrawQuads";

struct Entry {
    module: String,
    name: String,
    stage: String,
    workgroup: [u64; 3],
    out_read: bool,
    cbuffers: [u64; 2],
}

pub fn run(args: &[String]) -> Result<(), String> {
    if !args.is_empty() {
        return Err("usage: cargo xtask shaders".into());
    }
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).ancestors().nth(2).ok_or("no repo root")?.to_path_buf();
    let src = root.join("crates/sq-gpu/shaders-src");
    let out = root.join("crates/sq-gpu/shaders");
    let slangc = slangc()?;
    // slangc loads dxcompiler.dll and dxil.dll from PATH for DXIL.
    let path = if cfg!(windows) {
        let dxc =
            dxc_dir().ok_or("dxcompiler.dll and dxil.dll not found (install the Windows SDK or set SQ_DXC_DIR)")?;
        let old = std::env::var_os("PATH").unwrap_or_default();
        Some(std::env::join_paths(std::iter::once(dxc).chain(std::env::split_paths(&old))).map_err(|e| e.to_string())?)
    } else {
        None
    };
    for sub in ["msl", "dxil", "spirv"] {
        std::fs::create_dir_all(out.join(sub)).map_err(|e| e.to_string())?;
    }
    let mut modules: Vec<String> = std::fs::read_dir(&src)
        .map_err(|e| format!("{}: {e}", src.display()))?
        .flatten()
        .filter_map(|e| e.file_name().into_string().ok())
        .filter_map(|n| n.strip_suffix(".slang").map(str::to_string))
        .filter(|n| n != "Bindings")
        .collect();
    modules.sort();

    // 1. MSL and reflection per module.
    let refl_dir = std::env::temp_dir().join(format!("sq-shaders-{}", std::process::id()));
    std::fs::create_dir_all(&refl_dir).map_err(|e| e.to_string())?;
    let msl_jobs: Vec<Vec<String>> = modules
        .iter()
        .map(|m| {
            let mut a = base_args(&src, m);
            a.extend(strs(&["-target", "metal", "-D", "SQ_METAL_BUFFERS", "-reflection-json"]));
            a.push(refl_dir.join(format!("{m}.json")).display().to_string());
            a.extend(strs(&["-o"]));
            a.push(out.join(format!("msl/{m}.metal")).display().to_string());
            a
        })
        .collect();
    run_all(&slangc, &src, &path, msl_jobs)?;
    let mut entries = Vec::new();
    for m in &modules {
        let text = std::fs::read_to_string(refl_dir.join(format!("{m}.json"))).map_err(|e| format!("{m}: {e}"))?;
        let json = Json::parse(&text).map_err(|e| format!("{m} reflection: {e}"))?;
        entries.extend(check_module(m, &json)?);
    }
    let _ = std::fs::remove_dir_all(&refl_dir);

    // 2. SPIR-V per entry on every platform, DXIL per entry on Windows only.
    let windows = cfg!(windows);
    let mut jobs = Vec::new();
    for e in &entries {
        let shifts = if e.module == DRAW_MODULE { DRAW_SHIFTS } else { FIXED_SHIFTS };
        let mut a = base_args(&src, &e.module);
        a.extend(strs(&["-target", "spirv", "-entry", &e.name, "-fvk-use-entrypoint-name", "-O3"]));
        for (flag, shift) in ["-fvk-b-shift", "-fvk-t-shift", "-fvk-u-shift", "-fvk-s-shift"].iter().zip(shifts) {
            a.extend(strs(&[flag, shift, "all"]));
        }
        a.extend(strs(&["-o"]));
        a.push(out.join(format!("spirv/{}.{}.spv", e.module, e.name)).display().to_string());
        jobs.push(a);
    }
    for e in entries.iter().filter(|_| windows) {
        let mut a = base_args(&src, &e.module);
        a.extend(strs(&["-target", "dxil", "-entry", &e.name, "-profile", "sm_6_0", "-o"]));
        a.push(out.join(format!("dxil/{}.{}.dxil", e.module, e.name)).display().to_string());
        jobs.push(a);
    }
    run_all(&slangc, &src, &path, jobs)?;
    if !windows {
        println!("note: DXIL needs Windows (dxcompiler.dll); the committed dxil/ files were left as they are");
    }

    // slangc writes CRLF on Windows; the committed MSL is LF everywhere.
    for m in &modules {
        let file = out.join(format!("msl/{m}.metal"));
        let text = std::fs::read_to_string(&file).map_err(|e| format!("{}: {e}", file.display()))?;
        // `#line` strings name the absolute source file; keep the checked-in text free of the builder's folders.
        let abs = src.display().to_string();
        let text = text
            .replace("\r\n", "\n")
            .replace(&abs, "crates/sq-gpu/shaders-src")
            .replace(&abs.replace('\\', "\\\\"), "crates/sq-gpu/shaders-src")
            .replace(&abs.replace('\\', "/"), "crates/sq-gpu/shaders-src");
        std::fs::write(&file, text).map_err(|e| e.to_string())?;
    }

    // 3. The checked summary and the Rust table.
    std::fs::write(out.join("reflection.json"), summary(&entries)).map_err(|e| e.to_string())?;
    std::fs::write(out.join("entries.rs"), table(&entries)).map_err(|e| e.to_string())?;
    println!("shaders ok: {} modules, {} entries", modules.len(), entries.len());
    Ok(())
}

fn slangc() -> Result<PathBuf, String> {
    if let Ok(p) = std::env::var("SQ_SLANGC") {
        return Ok(p.into());
    }
    let p = if cfg!(windows) {
        Path::new(&std::env::var("USERPROFILE").unwrap_or_default()).join(r"slang\bin\slangc.exe")
    } else {
        Path::new(&std::env::var("HOME").unwrap_or_default()).join("tools/slang/bin/slangc")
    };
    if p.exists() { Ok(p) } else { Err(format!("slangc not found at {} (set SQ_SLANGC)", p.display())) }
}

/// The folder with `dxcompiler.dll` and `dxil.dll` slangc loads for DXIL: `SQ_DXC_DIR`, else the newest Windows SDK x64 bin.
fn dxc_dir() -> Option<PathBuf> {
    let both = |d: &Path| d.join("dxcompiler.dll").exists() && d.join("dxil.dll").exists();
    if let Ok(d) = std::env::var("SQ_DXC_DIR") {
        return Some(PathBuf::from(d));
    }
    let kits = Path::new(&std::env::var("ProgramFiles(x86)").unwrap_or_default()).join(r"Windows Kits\10\bin");
    let mut dirs: Vec<PathBuf> =
        std::fs::read_dir(kits).ok()?.flatten().map(|e| e.path().join("x64")).filter(|d| both(d)).collect();
    dirs.sort();
    dirs.pop()
}

fn strs(v: &[&str]) -> Vec<String> {
    v.iter().map(|s| s.to_string()).collect()
}

fn base_args(src: &Path, module: &str) -> Vec<String> {
    let mut a = vec![src.join(format!("{module}.slang")).display().to_string(), "-I".into(), src.display().to_string()];
    a.extend(strs(&WARN));
    a
}

/// Runs the slangc jobs on 8 threads; the first failure is returned with its first error line.
fn run_all(slangc: &Path, dir: &Path, path: &Option<std::ffi::OsString>, jobs: Vec<Vec<String>>) -> Result<(), String> {
    let next = AtomicUsize::new(0);
    let failure = Mutex::new(None::<String>);
    std::thread::scope(|s| {
        for _ in 0..8 {
            s.spawn(|| {
                loop {
                    let i = next.fetch_add(1, Ordering::Relaxed);
                    let Some(args) = jobs.get(i) else { break };
                    let mut cmd = Command::new(slangc);
                    cmd.current_dir(dir).args(args);
                    if let Some(p) = path {
                        cmd.env("PATH", p);
                    }
                    let result = cmd.output();
                    let error = match result {
                        Ok(o) if o.status.success() => continue,
                        Ok(o) => {
                            let err = String::from_utf8_lossy(&o.stderr);
                            err.lines().find(|l| l.contains("error")).unwrap_or("failed").to_string()
                        }
                        Err(e) => e.to_string(),
                    };
                    if let Ok(mut f) = failure.lock() {
                        f.get_or_insert(format!("slangc {}: {error}", args.join(" ")));
                    }
                }
            });
        }
    });
    match failure.into_inner() {
        Ok(Some(e)) => Err(e),
        _ => Ok(()),
    }
}

fn num(j: Option<&Json>) -> Option<u64> {
    j.and_then(Json::as_f64).map(|n| n as u64)
}

/// The Metal-target binding of a parameter: (kind, index).
fn binding(p: &Json) -> Option<(&str, u64)> {
    let b = p.get("bindings")?.as_arr()?.first()?;
    Some((b.get("kind")?.as_str()?, num(b.get("index"))?))
}

/// Checks one module's parameters against the fixed layout and returns its entry points.
/// Fixed (Bindings.slang, Metal numbering = register numbers): constant blocks 0..1, raw buffers 2..4, in0...in23 = 0...23,
/// lut0 = 24, out0 = 25, samplers 0...2. DrawQuads: C 0, quads buffer 1, textures 0...8, samplers 0...2.
fn check_module(module: &str, refl: &Json) -> Result<Vec<Entry>, String> {
    let fail = |name: &str, why: &str| Err(format!("{module}: parameter `{name}` {why}"));
    let params = refl.get("parameters").and_then(Json::as_arr).ok_or(format!("{module}: no parameters"))?;
    let mut cbuffers = [0u64; 2];
    let mut out_read = false;
    let mut seen = BTreeMap::new();
    for p in params {
        let name = p.get("name").and_then(Json::as_str).unwrap_or("?");
        let (kind, index) = binding(p).ok_or(format!("{module}: `{name}` has no binding"))?;
        let ty = p.get("type").ok_or(format!("{module}: `{name}` has no type"))?;
        let shape = ty.get("baseShape").and_then(Json::as_str).unwrap_or("");
        let access = ty.get("access").and_then(Json::as_str);
        let tex_slot = name.strip_prefix("in").and_then(|n| n.parse::<u64>().ok());
        let draw = module == DRAW_MODULE;
        let class = match (ty.get("kind").and_then(Json::as_str), shape) {
            (Some("constantBuffer"), _) => {
                let size = num(ty.at(&["elementVarLayout", "binding", "size"])).unwrap_or(0);
                if index > 1 || size > MAX_CONSTANT_BYTES || (draw && index != 0) {
                    return fail(
                        name,
                        &format!("is constant block {index} of {size} B (fixed: b0..b1, <= {MAX_CONSTANT_BYTES})"),
                    );
                }
                cbuffers[index as usize] = size;
                "b"
            }
            (Some("resource"), "byteAddressBuffer") => {
                let ok = if draw {
                    index == 1 && access.is_none() && name == "quads"
                } else {
                    (2..=4).contains(&index) && access == Some("readWrite")
                };
                if !ok {
                    return fail(
                        name,
                        &format!(
                            "is a raw buffer at {index} (fixed: RWByteAddressBuffer u2..u4; DrawQuads: quads at 1)"
                        ),
                    );
                }
                "buf"
            }
            (Some("resource"), "structuredBuffer") => {
                return fail(name, "is a structured buffer (D3D12 binds raw views: use ByteAddressBuffer)");
            }
            (Some("resource"), "texture3D") if !draw && name == "lut0" && index == 24 && kind == "shaderResource" => {
                "tex"
            }
            (Some("resource"), "texture2D")
                if name == "out0" && !draw && index == 25 && matches!(access, Some("write" | "readWrite")) =>
            {
                out_read |= access == Some("readWrite");
                "out"
            }
            (Some("resource"), "texture2D") if !draw && tex_slot == Some(index) && index < 24 && access.is_none() => {
                "tex"
            }
            (Some("resource"), "texture2D") if draw && index <= 8 && access.is_none() => "tex",
            (Some("samplerState"), _) if index <= 2 => "s",
            _ => return fail(name, &format!("does not fit the fixed layout ({kind} {index} {shape})")),
        };
        if seen.insert((class, index), name.to_string()).is_some() {
            return fail(name, &format!("shares slot {class}{index} with another parameter"));
        }
    }
    let entry_points = refl.get("entryPoints").and_then(Json::as_arr).ok_or(format!("{module}: no entry points"))?;
    entry_points
        .iter()
        .map(|e| {
            let name = e.get("name").and_then(Json::as_str).ok_or("entry without name")?.to_string();
            let stage = e.get("stage").and_then(Json::as_str).unwrap_or("?").to_string();
            let wg = e.get("threadGroupSize").and_then(Json::as_arr);
            let workgroup = match wg {
                Some([x, y, z]) => [num(Some(x)).unwrap_or(1), num(Some(y)).unwrap_or(1), num(Some(z)).unwrap_or(1)],
                _ => [1, 1, 1],
            };
            if stage == "compute" && workgroup != [16, 16, 1] {
                return Err(format!("{module}.{name}: workgroup {workgroup:?}, the dispatch helpers assume 16x16x1"));
            }
            Ok(Entry { module: module.to_string(), name, stage, workgroup, out_read, cbuffers })
        })
        .collect()
}

/// The committed summary: per module and entry the stage, workgroup, constant block sizes and whether out0 is read-write.
fn summary(entries: &[Entry]) -> String {
    let mut s = String::from("{\n  \"fixed_layout_entries\": 35,\n  \"modules\": {");
    let mut last = "";
    for e in entries {
        if e.module != last {
            if !last.is_empty() {
                s.push_str("\n    },");
            }
            let _ = write!(s, "\n    \"{}\": {{", e.module);
            last = &e.module;
        } else {
            s.push(',');
        }
        let _ = write!(
            s,
            "\n      \"{}\": {{\"stage\": \"{}\", \"workgroup\": {:?}, \"cbuffers\": {:?}, \"out_read\": {}}}",
            e.name, e.stage, e.workgroup, e.cbuffers, e.out_read
        );
    }
    s.push_str("\n    }\n  }\n}\n");
    s
}

/// Entries whose `.dxil` was never generated (DXIL needs Windows). Windows gets an empty blob and the code never picks them
/// there (`SCALED_GYRO_WARP`). Windows: run `cargo xtask shaders`, commit the dxil, remove the name here and enable the flag.
const NO_DXIL_YET: &[&str] = &["gyroWarpScaled"];

/// `entries.rs`, included by `sq-gpu`: one `ShaderEntry` per entry point; each backend's bytes only on its own target.
fn table(entries: &[Entry]) -> String {
    let mut s =
        String::from("// Generated by `cargo xtask shaders`; do not edit.\npub static ENTRIES: &[ShaderEntry] = &[\n");
    for e in entries {
        let path =
            |sub: &str, file: String| format!("concat!(env!(\"CARGO_MANIFEST_DIR\"), \"/shaders/{sub}/{file}\")");
        let stage = match e.stage.as_str() {
            "compute" => "ShaderStage::Compute",
            "vertex" => "ShaderStage::Vertex",
            _ => "ShaderStage::Fragment",
        };
        let _ = writeln!(
            s,
            "    ShaderEntry {{ module: \"{m}\", name: \"{n}\", stage: {stage}, workgroup: ({}, {}, {}), out_read: {}, cbuffers: {:?},\n        #[cfg(target_os = \"macos\")] msl: include_str!({}),\n        #[cfg(windows)] dxil: {},\n        #[cfg(not(any(target_os = \"macos\", windows)))] spirv: include_bytes!({}) }},",
            e.workgroup[0],
            e.workgroup[1],
            e.workgroup[2],
            e.out_read,
            e.cbuffers,
            path("msl", format!("{}.metal", e.module)),
            if NO_DXIL_YET.contains(&e.name.as_str()) {
                "&[]".to_string()
            } else {
                format!("include_bytes!({})", path("dxil", format!("{}.{}.dxil", e.module, e.name)))
            },
            path("spirv", format!("{}.{}.spv", e.module, e.name)),
            m = e.module,
            n = e.name,
        );
    }
    s.push_str("];\n");
    s
}
