//! The five representative passes of gate G2 (docs/rust/render-playback-export-design.md, spikes/g2-slang/REPORT.md) on the
//! `sq-gpu` layer: grade, blur, in-place grade, scope counters (atomics) and a draw with the fixed samplers, plus a build of
//! all 64 pipelines. Tests skip with a note when the machine has no GPU adapter.
//!
//! Cross-backend check: `SQ_GPU_DUMP=<dir>` writes the pass outputs; `SQ_GPU_GOLDEN=<dir>` (a dump from the other backend)
//! asserts Metal vs D3D12 <= 1/255 in the 8-bit view (g2 numbers: colorChain 0, blur 1, in-place 1, present linear 1; scope
//! counters identical). Present with `nearest` at a non-integer scale differs by texel-edge rounding and is not compared.
#![allow(clippy::too_many_arguments)]

use sq_gpu::frames::GpuTexture;
use sq_gpu::gpu::{Gpu, GpuError};
use sq_gpu::layout::PixelFormat;
use sq_gpu::pipelines::{Blend, ENTRIES, Primitive, RenderKey, ShaderStage};
use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock};

type R<T> = Result<T, Box<dyn std::error::Error>>;
const F16: PixelFormat = PixelFormat::Rgba16Float;

fn gpu() -> Option<Arc<Gpu>> {
    static GPU: OnceLock<Option<Arc<Gpu>>> = OnceLock::new();
    GPU.get_or_init(|| match Gpu::new() {
        Ok(g) => {
            eprintln!("adapter: {} ({:?})", g.info().name, g.info().backend);
            Some(g)
        }
        Err(e) => {
            eprintln!("skipping GPU tests: {e}");
            None
        }
    })
    .clone()
}

fn f32_to_f16(v: f32) -> u16 {
    let x = v.to_bits();
    let sign = ((x >> 16) & 0x8000) as u16;
    let exp = ((x >> 23) & 0xff) as i32;
    let mant = x & 0x7f_ffff;
    if exp == 255 {
        return sign | 0x7c00 | if mant != 0 { 0x200 } else { 0 };
    }
    let e = exp - 127 + 15;
    if e >= 31 {
        return sign | 0x7c00;
    }
    if e <= 0 {
        if e < -10 {
            return sign;
        }
        let m = mant | 0x80_0000;
        let shift = (14 - e) as u32;
        let half = 1u32 << (shift - 1);
        let mut r = m >> shift;
        let rem = m & ((1 << shift) - 1);
        if rem > half || (rem == half && (r & 1) == 1) {
            r += 1;
        }
        return sign | r as u16;
    }
    let mut r = ((e as u32) << 10) | (mant >> 13);
    let rem = mant & 0x1fff;
    if rem > 0x1000 || (rem == 0x1000 && (r & 1) == 1) {
        r += 1;
    }
    sign | r as u16
}

// Truncating conversion (what an RTZ texture store does), for finite normal results only.
fn f32_to_f16_rtz(v: f32) -> u16 {
    let n = f32_to_f16(v);
    if f16_to_f32(n).abs() > v.abs() && n & 0x7fff != 0 { n - 1 } else { n }
}

fn f16_to_f32(h: u16) -> f32 {
    let sign = ((h as u32) & 0x8000) << 16;
    let exp = ((h >> 10) & 0x1f) as u32;
    let mant = (h & 0x3ff) as u32;
    let bits = if exp == 0 {
        if mant == 0 {
            sign
        } else {
            let (mut e, mut m) = (113u32, mant);
            while m & 0x400 == 0 {
                m <<= 1;
                e -= 1;
            }
            sign | (e << 23) | ((m & 0x3ff) << 13)
        }
    } else if exp == 31 {
        sign | 0x7f80_0000 | (mant << 13)
    } else {
        sign | ((exp + 112) << 23) | (mant << 13)
    };
    f32::from_bits(bits)
}

// ---- uniform blocks (layouts mirror the Slang structs; uint4/float4 rows pack the same in MSL and HLSL) ----
struct Bytes(Vec<u8>);
impl Bytes {
    fn u(&mut self, v: &[u32]) -> &mut Self {
        v.iter().for_each(|x| self.0.extend(x.to_le_bytes()));
        self
    }
    fn f(&mut self, v: &[f32]) -> &mut Self {
        v.iter().for_each(|x| self.0.extend(x.to_le_bytes()));
        self
    }
    fn i(&mut self, v: &[i32]) -> &mut Self {
        v.iter().for_each(|x| self.0.extend(x.to_le_bytes()));
        self
    }
}

type Sec = ([u32; 4], [[f32; 4]; 4]);

fn color_chain(ints: [u32; 4], secs: &[Sec]) -> Vec<u8> {
    let mut b = Bytes(Vec::new());
    b.u(&ints).u(&[0, 0, 0, 0]);
    for i in 0..24 {
        let (head, abcd) = secs.get(i).copied().unwrap_or(([0; 4], [[0.0; 4]; 4]));
        b.u(&head);
        abcd.iter().for_each(|r| {
            b.f(r);
        });
        b.f(&[1.0, 0.0, 0.0, 0.0]).f(&[0.0, 1.0, 0.0, 0.0]).f(&[0.0, 0.0, 1.0, 0.0]);
    }
    b.0
}

fn input_image(w: u32, h: u32) -> Vec<u16> {
    let mut v = Vec::with_capacity((w * h * 4) as usize);
    for y in 0..h {
        for x in 0..w {
            let (fx, fy) = (x as f32 / (w - 1) as f32, y as f32 / (h - 1) as f32);
            let mut c = [fx, fy, 0.5 + 0.5 * (x as f32 * 0.15).sin() * (y as f32 * 0.11).cos(), 1.0];
            if (60..84).contains(&y) {
                let on = ((x / 8) + (y / 8)) % 2 == 0;
                c = if on { [1.6, 1.2, 0.9, 1.0] } else { [0.02, 0.03, 0.05, 1.0] };
            }
            if x > 200 && y > 100 {
                c = [c[0] * 0.5, c[1] * 0.5, c[2] * 0.5, 0.5];
            }
            v.extend(c.iter().map(|&f| f32_to_f16(f)));
        }
    }
    v
}

fn gauss(radius: i32, sigma: f32) -> Vec<f32> {
    let w: Vec<f32> = (-radius..=radius).map(|k| (-(k * k) as f32 / (2.0 * sigma * sigma)).exp()).collect();
    let sum: f32 = w.iter().sum();
    w.iter().map(|x| x / sum).collect()
}

fn blur_u(axis: [i32; 2], radius: i32, clamp: i32, w: u32, h: u32) -> Vec<u8> {
    Bytes(Vec::new()).i(&axis).i(&[radius, clamp]).i(&[0, 0]).i(&[w as i32 - 1, h as i32 - 1]).0.clone()
}

// CPU blur with the same tap order as Blur.slang, stored to half like the GPU.
fn cpu_blur(src: &[u16], w: u32, h: u32, axis: [i32; 2], wts: &[f32], clamp: bool, rtz: bool) -> Vec<u16> {
    let r = (wts.len() as i32 - 1) / 2;
    let mut out = vec![0u16; src.len()];
    for y in 0..h as i32 {
        for x in 0..w as i32 {
            let mut acc = [0f32; 4];
            for k in -r..=r {
                let (mut px, mut py) = (x + axis[0] * k, y + axis[1] * k);
                if clamp {
                    px = px.clamp(0, w as i32 - 1);
                    py = py.clamp(0, h as i32 - 1);
                } else if px < 0 || py < 0 || px >= w as i32 || py >= h as i32 {
                    continue;
                }
                let i = ((py as u32 * w + px as u32) * 4) as usize;
                for c in 0..4 {
                    acc[c] += f16_to_f32(src[i + c]) * wts[(k + r) as usize];
                }
            }
            let o = ((y as u32 * w + x as u32) * 4) as usize;
            for c in 0..4 {
                out[o + c] = if rtz { f32_to_f16_rtz(acc[c]) } else { f32_to_f16(acc[c]) };
            }
        }
    }
    out
}

// Half-float compare: absolute and relative (ulp) distance, plus the 8-bit view the Swift Metal-vs-D3D12 bar uses
// (scripts/win-gpu-check.sh: values clamped to 0...1, quantized to 0...255, max diff and share of channels over 1).
struct Diff {
    max_abs: f32,
    max_ulp: u32,
    max8: u32,
    ch_over1_8: usize,
    px_any: usize,
    px: usize,
}

impl std::fmt::Display for Diff {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "f16: max abs {:.6}, max {} ulp, pixels differing {:.2} % | 8-bit: max {}/255, channels over 1: {:.3} %",
            self.max_abs,
            self.max_ulp,
            100.0 * self.px_any as f64 / self.px.max(1) as f64,
            self.max8,
            100.0 * self.ch_over1_8 as f64 / (self.px.max(1) * 4) as f64
        )
    }
}

fn ordered(h: u16) -> i32 {
    if h & 0x8000 != 0 { -((h & 0x7fff) as i32) } else { h as i32 }
}

fn diff16(a: &[u16], b: &[u16]) -> Diff {
    let mut d = Diff { max_abs: 0.0, max_ulp: 0, max8: 0, ch_over1_8: 0, px_any: 0, px: a.len() / 4 };
    let q8 = |v: f32| (v.clamp(0.0, 1.0) * 255.0).round() as i32;
    for (pa, pb) in a.as_chunks::<4>().0.iter().zip(b.as_chunks::<4>().0) {
        let mut any = false;
        for c in 0..4 {
            let (x, y) = (f16_to_f32(pa[c]), f16_to_f32(pb[c]));
            any |= pa[c] != pb[c];
            let ad = (x - y).abs();
            d.max_abs = if ad.is_nan() { f32::INFINITY } else { d.max_abs.max(ad) };
            d.max_ulp = d.max_ulp.max(ordered(pa[c]).abs_diff(ordered(pb[c])));
            let e8 = q8(x).abs_diff(q8(y));
            d.max8 = d.max8.max(e8);
            d.ch_over1_8 += (e8 > 1) as usize;
        }
        d.px_any += any as usize;
    }
    d
}

fn to_u16(bytes: &[u8]) -> Vec<u16> {
    bytes.as_chunks::<2>().0.iter().map(|c| u16::from_le_bytes(*c)).collect()
}

fn to_u32(bytes: &[u8]) -> Vec<u32> {
    bytes.as_chunks::<4>().0.iter().map(|c| u32::from_le_bytes(*c)).collect()
}

fn dump(name: &str, bytes: &[u8]) -> R<()> {
    if let Ok(dir) = std::env::var("SQ_GPU_DUMP") {
        std::fs::create_dir_all(&dir)?;
        std::fs::write(Path::new(&dir).join(name), bytes)?;
    }
    Ok(())
}

/// Compares against the other backend's dump when `SQ_GPU_GOLDEN` is set; `compared` = false skips the assertion.
fn golden(name: &str, bytes: &[u8], compared: bool) -> R<()> {
    let Ok(dir) = std::env::var("SQ_GPU_GOLDEN") else { return Ok(()) };
    let other = std::fs::read(PathBuf::from(dir).join(name))?;
    if name.ends_with(".u32") {
        let bad = to_u32(bytes).iter().zip(to_u32(&other)).filter(|(a, b)| **a != *b).count();
        eprintln!("{name}: {bad} counters differ");
        assert_eq!(bad, 0, "{name}");
    } else {
        let d = diff16(&to_u16(bytes), &to_u16(&other));
        eprintln!("{name}: {d}");
        if compared {
            assert!(d.max8 <= 1 && d.ch_over1_8 == 0, "{name}: {d}");
        }
    }
    Ok(())
}

fn upload(gpu: &Gpu, w: u32, h: u32, data: &[u16]) -> GpuTexture {
    let t = gpu.texture(w, h, F16);
    let bytes: Vec<u8> = data.iter().flat_map(|v| v.to_le_bytes()).collect();
    gpu.upload_texture(&t, &bytes, w * 8);
    t
}

#[test]
fn all_pipelines_build() -> R<()> {
    let Some(gpu) = gpu() else { return Ok(()) };
    let mut built = 0;
    for e in ENTRIES {
        match e.stage {
            ShaderStage::Compute => {
                gpu.compute_pipeline(e.module, e.name, F16)?;
            }
            ShaderStage::Fragment => {
                let vertex = ENTRIES
                    .iter()
                    .find(|v| v.module == e.module && v.stage == ShaderStage::Vertex)
                    .ok_or("no vertex entry")?;
                let key = RenderKey {
                    module: e.module,
                    vertex: vertex.name,
                    fragment: e.name,
                    format: F16,
                    blend: Blend::Replace,
                    primitive: Primitive::Triangles,
                };
                gpu.render_pipeline(key)?;
            }
            ShaderStage::Vertex => continue,
        }
        built += 1;
    }
    assert_eq!(built, 66);
    Ok(())
}

#[test]
fn g2_passes() -> R<()> {
    let Some(gpu) = gpu() else { return Ok(()) };
    let (w, h) = (256u32, 144u32);
    let src_data = input_image(w, h);
    let src = upload(&gpu, w, h, &src_data);
    let mut cmds = gpu.commands();

    // 1. Grade: colorChain, 3104 B + 3072 B constant blocks.
    let a = gpu.texture(w, h, F16);
    let cc = color_chain(
        [3, 0, 3, 2],
        &[
            ([1, 1, 2, 0], [[1.4, 0.0, 0.0, 0.0], [0.0; 4], [0.0; 4], [0.0; 4]]),
            (
                [2, 0, 1, 0],
                [
                    [0.08, 1.25, 0.3, 0.1],
                    [0.02, -0.01, 0.03, 0.0],
                    [-0.02, 0.01, 0.04, 0.0],
                    [0.2126, 0.7152, 0.0722, 0.0],
                ],
            ),
            ([6, 1, 0, 0], [[-1.0, 0.35, 0.6, 2.0], [0.0; 4], [0.0; 4], [0.0; 4]]),
        ],
    );
    {
        let mut pass = cmds.compute();
        pass.set_pipeline(&gpu.compute_pipeline("ColorChain", "colorChain", F16)?);
        pass.set_input(&src, 0)?;
        pass.set_output(&a);
        pass.set_constants(&cc, 0)?;
        pass.set_constants(&[0u8; 3072], 1)?;
        pass.dispatch(w, h)?;
    }

    // 2. Blur: gaussianBlur1D horizontal (transparent outside) then vertical (clamped), a -> b -> c.
    let (b, c) = (gpu.texture(w, h, F16), gpu.texture(w, h, F16));
    let wts = gauss(6, 2.5);
    let mut wb = Bytes(Vec::new());
    wb.f(&wts).f(&vec![0.0; 128 - wts.len()]);
    {
        let mut pass = cmds.compute();
        pass.set_pipeline(&gpu.compute_pipeline("Blur", "gaussianBlur1D", F16)?);
        pass.set_constants(&wb.0, 1)?;
        pass.set_input(&a, 0)?;
        pass.set_output(&b);
        pass.set_constants(&blur_u([1, 0], 6, 0, w, h), 0)?;
        pass.dispatch(w, h)?;
        pass.set_input(&b, 0)?;
        pass.set_output(&c);
        pass.set_constants(&blur_u([0, 1], 6, 1, w, h), 0)?;
        pass.dispatch(w, h)?;
    }
    let c_ticket = cmds.read_texture(&c)?;
    let a_ticket = cmds.read_texture(&a)?;

    // 3. Storage texture read-write: colorChainInPlace on c.
    {
        let mut pass = cmds.compute();
        pass.set_pipeline(&gpu.compute_pipeline("ColorChainInPlace", "colorChainInPlace", F16)?);
        pass.set_output(&c);
        pass.set_constants(
            &color_chain([1, 1, 3, 2], &[([1, 1, 2, 0], [[0.85, 0.0, 0.0, 0.0], [0.0; 4], [0.0; 4], [0.0; 4]])]),
            0,
        )?;
        pass.set_constants(&[0u8; 3072], 1)?;
        pass.dispatch(w, h)?;
    }

    // 4. Storage buffer + atomics: scopeClear then scopeAccumulate into one uint buffer at u2.
    let (wave_w, wave_l, vec_n) = (256u32, 64u32, 64u32);
    let (off_par, off_vec) = (wave_w * wave_l, wave_w * wave_l * 4);
    let off_hist = off_vec + vec_n * vec_n;
    let total = off_hist + 4 * 256;
    let counts = gpu.storage_buffer(u64::from(total) * 4);
    gpu.queue().write_buffer(&counts, 0, &vec![0xEFu8; total as usize * 4]);
    let su = Bytes(Vec::new())
        .u(&[w, h, 1, 15, wave_w, wave_l, vec_n, 256, 0, off_par, off_vec, off_hist, 0, total, 0, 0, 0, 0, 0, 0])
        .0
        .clone();
    {
        let mut pass = cmds.compute();
        pass.set_constants(&su, 0)?;
        pass.set_buffer(&counts, 2)?;
        pass.set_pipeline(&gpu.compute_pipeline("Scopes", "scopeClear", F16)?);
        pass.dispatch_groups(16, total.div_ceil(256).div_ceil(16))?;
        pass.set_pipeline(&gpu.compute_pipeline("Scopes", "scopeAccumulate", F16)?);
        pass.set_input(&src, 0)?;
        pass.dispatch(w, h)?;
    }
    let counts_ticket = cmds.read_buffer(&counts, u64::from(total) * 4);
    let c_final_ticket = cmds.read_texture(&c)?;

    // 5. Draw with samplers: presentVertex/presentFragment, c -> 333x187, linear (s1) and nearest (s2).
    let (rw, rh) = (333u32, 187u32); // no pixel center lands exactly on a texel edge
    let present = gpu.render_pipeline(RenderKey {
        module: "Present",
        vertex: "presentVertex",
        fragment: "presentFragment",
        format: F16,
        blend: Blend::Replace,
        primitive: Primitive::Triangles,
    })?;
    let mut tickets = Vec::new();
    for nearest in [0u32, 1] {
        let target = gpu.texture(rw, rh, F16);
        let pu = Bytes(Vec::new())
            .f(&[1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0])
            .f(&[0.0, 1.0, 0.8, 1.0])
            .u(&[nearest, 0, 0, 0])
            .0
            .clone();
        {
            let mut pass = cmds.render(&target, Some([0.0; 4]));
            pass.set_pipeline(&present);
            pass.set_input(&c, 0)?;
            pass.set_constants(&pu, 0)?;
            pass.draw(3, 1)?;
        }
        tickets.push(cmds.read_texture(&target)?);
    }
    gpu.submit_and_wait(cmds)?;

    let c_before = to_u16(&c_ticket.wait(&gpu)?);
    let a_px = to_u16(&a_ticket.wait(&gpu)?);
    let counts_raw = counts_ticket.wait(&gpu)?;
    let c_px = to_u16(&c_final_ticket.wait(&gpu)?);
    let r_lin = to_u16(&tickets.remove(0).wait(&gpu)?);
    let r_near = to_u16(&tickets.remove(0).wait(&gpu)?);

    // Self checks, the same on every backend.
    for (name, px) in [("colorChain", &a_px), ("blur", &c_before), ("inPlace", &c_px)] {
        assert!(px.iter().all(|&v| f16_to_f32(v).is_finite()), "{name} has non-finite values");
    }
    assert_ne!(a_px, c_px);
    // The blur reads the colorChain output; both GPUs round toward zero when storing half floats.
    let hb = cpu_blur(&a_px, w, h, [1, 0], &wts, false, true);
    let vb = cpu_blur(&hb, w, h, [0, 1], &wts, true, true);
    let d = diff16(&vb, &c_before);
    eprintln!("blur vs CPU (rtz): {d}");
    assert!(d.max8 <= 1 && d.ch_over1_8 == 0, "blur vs CPU: {d}");
    let cu = to_u32(&counts_raw);
    assert_eq!(
        cu[..off_par as usize].iter().map(|&x| u64::from(x)).sum::<u64>(),
        u64::from(w * h),
        "waveform luma total"
    );
    assert_eq!(
        cu[off_hist as usize..].iter().map(|&x| u64::from(x)).sum::<u64>(),
        u64::from(w * h * 4),
        "histogram total"
    );
    assert_eq!(cu.iter().filter(|&&x| x == 0xEFEF_EFEF).count(), 0, "untouched counters");
    assert!(diff16(&r_lin, &r_near).max8 > 1, "linear and nearest present must differ (samplers s1/s2)");

    let bytes = |v: &[u16]| v.iter().flat_map(|x| x.to_le_bytes()).collect::<Vec<u8>>();
    for (name, data, compared) in [
        (format!("1_colorChain_{w}x{h}.f16"), bytes(&a_px), true),
        (format!("2_blur_{w}x{h}.f16"), bytes(&c_before), true),
        (format!("3_colorChainInPlace_{w}x{h}.f16"), bytes(&c_px), true),
        (format!("5_present_linear_{rw}x{rh}.f16"), bytes(&r_lin), true),
        (format!("5_present_nearest_{rw}x{rh}.f16"), bytes(&r_near), false),
        ("4_scopes.u32".to_string(), counts_raw.clone(), true),
    ] {
        dump(&name, &data)?;
        golden(&name, &data, compared)?;
    }
    Ok(())
}

#[test]
fn bad_calls_are_errors() -> R<()> {
    let Some(gpu) = gpu() else { return Ok(()) };
    assert!(matches!(gpu.compute_pipeline("Nope", "nope", F16), Err(GpuError::Pipeline(_))));
    assert!(gpu.compute_pipeline("Blur", "gaussianBlur1D", PixelFormat::Bgra8Unorm).is_err());
    let mut cmds = gpu.commands();
    let mut pass = cmds.compute();
    assert!(pass.dispatch(16, 16).is_err(), "no pipeline");
    pass.set_pipeline(&gpu.compute_pipeline("Blur", "gaussianBlur1D", F16)?);
    assert!(pass.set_constants(&[0; 5000], 0).is_err());
    assert!(pass.set_constants(&[0; 16], 2).is_err());
    assert!(pass.set_buffer(&gpu.storage_buffer(16), 1).is_err());
    let other = gpu.texture(4, 4, PixelFormat::Rgba8Unorm);
    pass.set_output(&other);
    assert!(pass.dispatch(4, 4).is_err(), "output format differs from the pipeline's");
    Ok(())
}

/// DrawQuads has its own layout (quads in a read-only raw buffer at t9/buffer(1)): one solid quad lands where it should.
#[test]
fn draw_quads_solid_rect() -> R<()> {
    let Some(gpu) = gpu() else { return Ok(()) };
    let quad = Bytes(Vec::new())
        .f(&[4.0, 4.0, 8.0, 8.0, 0.0, 0.0, 1.0, 1.0, 1.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 16.0, 16.0])
        .0
        .clone();
    let quads = gpu.storage_buffer(quad.len() as u64);
    gpu.queue().write_buffer(&quads, 0, &quad);
    let target = gpu.texture(16, 16, PixelFormat::Rgba8Unorm);
    let pipeline = gpu.render_pipeline(RenderKey {
        module: "DrawQuads",
        vertex: "quadVertex",
        fragment: "quadFragment",
        format: PixelFormat::Rgba8Unorm,
        blend: Blend::Replace,
        primitive: Primitive::Triangles,
    })?;
    let mut cmds = gpu.commands();
    {
        let mut pass = cmds.render(&target, Some([0.0; 4]));
        pass.set_pipeline(&pipeline);
        pass.set_constants(&Bytes(Vec::new()).f(&[16.0, 16.0, 0.0, 0.0, 1.0, 1.0, 0.0, 0.0]).0, 0)?;
        pass.set_buffer(&quads, 2)?;
        pass.draw(6, 1)?;
    }
    let ticket = cmds.read_texture(&target)?;
    gpu.submit_and_wait(cmds)?;
    let px = ticket.wait(&gpu)?;
    let at = |x: usize, y: usize| px[(y * 16 + x) * 4..(y * 16 + x) * 4 + 4].to_vec();
    assert_eq!(at(8, 8), [255, 0, 0, 255], "inside the quad");
    assert_eq!(at(1, 1), [0, 0, 0, 0], "outside the quad");
    assert_eq!(at(14, 8), [0, 0, 0, 0], "right of the quad");
    Ok(())
}
