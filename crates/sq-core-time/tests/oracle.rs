// SPDX-License-Identifier: GPL-3.0-or-later
//! Replays the Swift goldens in `oracle/sq-core-time/golden` (format: that folder's README and file headers).
//! Ops without a Rust port yet are counted as "not covered" and listed by the test output.

// `cfg(test)` makes the helpers test code for clippy (unwrap on golden input is fine here).
#[cfg(test)]
mod replay {
    use sq_core_time::ease_names::ease_name;
    use sq_core_time::easing_spring::interpolated_time;
    use sq_core_time::keyframes_model::keyframe_math;
    use sq_core_time::text::{ci_contains, graphemes, standard_compare};
    use sq_core_time::text_search::matches;
    use sq_core_time::*;
    use sq_core_time::{step_status, word_segmentation};
    use std::collections::BTreeMap;
    use std::path::PathBuf;

    fn golden(name: &str) -> String {
        let p = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../oracle/sq-core-time/golden").join(name);
        std::fs::read_to_string(&p).unwrap_or_else(|e| panic!("{}: {e}", p.display()))
    }

    fn time(s: &str) -> Time {
        let (v, t) = s.split_once('/').unwrap_or_else(|| panic!("bad time {s}"));
        Time::new(v.parse().unwrap(), t.parse().unwrap())
    }

    fn ft(t: Time) -> String {
        format!("{}/{}", t.value(), t.timescale())
    }

    fn hex(s: &str) -> f64 {
        f64::from_bits(u64::from_str_radix(s, 16).unwrap())
    }

    fn hx(d: f64) -> String {
        format!("{:016x}", d.to_bits())
    }

    fn b(v: bool) -> String {
        if v { "1" } else { "0" }.to_string()
    }

    /// Unquotes a golden string: `\u{hex}` escapes, everything else literal.
    fn unq(s: &str) -> String {
        let inner = &s[1..s.len() - 1];
        let mut out = String::new();
        let mut rest = inner;
        while let Some(i) = rest.find("\\u{") {
            out.push_str(&rest[..i]);
            let end = rest[i..].find('}').unwrap() + i;
            out.push(char::from_u32(u32::from_str_radix(&rest[i + 3..end], 16).unwrap()).unwrap());
            rest = &rest[end + 1..];
        }
        out.push_str(rest);
        out
    }

    fn interp(s: &str) -> Interpolation {
        match s {
            "linear" => Interpolation::Linear,
            "hold" => Interpolation::Hold,
            "bezier" => Interpolation::Bezier,
            "holdAhead" => Interpolation::HoldAhead,
            _ => panic!("bad interpolation {s}"),
        }
    }

    fn quote(s: &str) -> String {
        let mut out = String::from("\"");
        for c in s.chars() {
            if (' '..='~').contains(&c) && c != '\\' && c != '"' {
                out.push(c);
            } else {
                out.push_str(&format!("\\u{{{:x}}}", u32::from(c)));
            }
        }
        out.push('"');
        out
    }

    /// The Swift oracle still speaks the old easing words; redesign #35 renamed them for display only.
    fn swift_name(s: &str) -> String {
        match s {
            "Linear" => "Steady",
            "Ease In & Out" => "Smooth",
            "Ease In" => "Smooth In",
            "Ease Out" => "Smooth Out",
            "Ease In 100%" => "Smooth In 100%",
            "Ease Out 100%" => "Smooth Out 100%",
            other => other,
        }
        .to_string()
    }

    fn quoted_list(items: &[String]) -> String {
        items.iter().map(|s| quote(s)).collect::<Vec<_>>().join(",")
    }

    fn hex_list(v: &[f64]) -> String {
        v.iter().map(|d| hx(*d)).collect::<Vec<_>>().join(",")
    }

    /// Splits a golden list of quoted strings (`"a","b"`; quotes inside are always escapes, so `","` is the seam).
    fn unq_list(s: &str) -> Vec<String> {
        if s.is_empty() {
            return Vec::new();
        }
        s[1..s.len() - 1].split("\",\"").map(|p| unq(&format!("\"{p}\""))).collect()
    }

    fn interp_name(i: Interpolation) -> &'static str {
        match i {
            Interpolation::Linear => "linear",
            Interpolation::Hold => "hold",
            Interpolation::Bezier => "bezier",
            Interpolation::HoldAhead => "holdAhead",
        }
    }

    /// Rust outputs for one record, `None` when the op is not ported.
    fn run(op: &str, i: &[&str]) -> Option<Vec<String>> {
        let t = |k: usize| time(i[k]);
        let n = |k: usize| i[k].parse::<i64>().unwrap();
        Some(match op {
            "init" => {
                let x = Time::new(n(0), n(1));
                vec![ft(x), x.value().to_string(), x.timescale().to_string(), b(x.is_negative())]
            }
            "reducing" => vec![ft(Time::reducing(i[0].parse().unwrap(), i[1].parse().unwrap()))],
            "add" => vec![ft(t(0) + t(1))],
            "sub" => vec![ft(t(0) - t(1))],
            "neg" => vec![ft(-t(0))],
            "mul" => vec![ft(t(0) * n(1))],
            "scaled_t" => vec![ft(Time::scaled(t(0), t(1), t(2)))],
            "scaled_i" => vec![ft(Time::scaled_int(t(0), n(1), n(2)))],
            "halved" => vec![ft(t(0).halved())],
            "cmp" => {
                let (x, y) = (t(0), t(1));
                let c = match x.cmp(&y) {
                    std::cmp::Ordering::Less => "-1",
                    std::cmp::Ordering::Equal => "0",
                    std::cmp::Ordering::Greater => "1",
                };
                vec![c.to_string(), b(x < y), b(x <= y), b(x > y), b(x >= y), b(x == y)]
            }
            "frame_index" | "frame_index_any" => {
                let (x, fd) = (t(0), t(1));
                vec![x.frame_index(fd).to_string(), ft(x.snapped(fd)), ft(x.ceiled(fd))]
            }
            "frames_x" => vec![ft(Time::frames(n(0), t(1)))],
            "range" => {
                let a = TimeRange::new(t(0), t(1));
                let o = TimeRange::new(t(2), t(3));
                let inter =
                    a.intersection(&o).map_or("nil".to_string(), |r| format!("{}+{}", ft(r.start), ft(r.duration)));
                vec![ft(a.end()), b(a.is_empty()), b(a.contains(t(4))), b(a.overlaps(&o)), inter]
            }
            "seq_fd" => vec![ft(FrameRate::sequence_frame_duration(n(0), t(1)))],
            "bezier" => {
                let h = |x: usize| EaseHandle { dx: hex(i[x]), dy: hex(i[x + 1]) };
                let p = keyframe_math::bezier_progress(hex(i[0]), h(1), h(3));
                vec![hx(p), String::new()]
            }
            "track" => {
                let mut ids = SequentialIds::default();
                let keys = i[0]
                    .split(';')
                    .filter(|s| !s.is_empty())
                    .map(|d| {
                        let f: Vec<&str> = d.split('|').collect();
                        let mut k = Keyframe::new(ids.next_id(), time(f[0]), hex(f[1]));
                        k.interpolation = interp(f[2]);
                        k.in_handle = EaseHandle { dx: hex(f[3]), dy: hex(f[4]) };
                        k.out_handle = EaseHandle { dx: hex(f[5]), dy: hex(f[6]) };
                        k
                    })
                    .collect();
                let tr = KeyframeTrack::with_keys(keys);
                let vals: Vec<String> =
                    i[1].split(',').map(|p| tr.value(time(p)).map_or("nil".to_string(), hx)).collect();
                vec![vals.join(",")]
            }
            "spatial" => {
                let v = |k: usize| Vec2::new(hex(i[k]), hex(i[k + 1]));
                let path = SpatialPath::new(v(1), v(3), v(5), v(7), i[0].parse().unwrap());
                let (a, p) = (path.point_at_arc_fraction(hex(i[9])), path.point_at_parameter(hex(i[10])));
                vec![hx(path.length()), String::new(), hx(a.x), hx(a.y), hx(p.x), hx(p.y)]
            }
            "eq" => {
                let a = t(0);
                let m = n(1);
                let scaled = Time::new(a.value() * m, a.timescale() * m);
                vec![ft(scaled), b(a == scaled)]
            }
            "cmx_init" => {
                let c = CmxTimecode::from_frame_duration(t(0), i[1] == "1");
                vec![c.nominal_rate().to_string(), b(c.drop_frame())]
            }
            "cmx_str" => {
                let c = CmxTimecode::new(n(0), i[1] == "1");
                let frames = n(2);
                let s = c.string(frames);
                let back = c.frames(&s);
                vec![
                    c.nominal_rate().to_string(),
                    b(c.drop_frame()),
                    quote(&s),
                    back.map_or("nil".to_string(), |v| v.to_string()),
                    b(back == Some(frames.max(0))),
                ]
            }
            "cmx_parse" => {
                let c = CmxTimecode::new(n(0), i[1] == "1");
                vec![c.frames(&unq(i[2])).map_or("nil".to_string(), |v| v.to_string())]
            }
            "ease_names" => {
                let built_ins = EasingCurve::built_ins();
                if i[0] == "constants" {
                    use ease_name::*;
                    let names = [
                        STEADY,
                        SMOOTH,
                        SMOOTH_IN,
                        SMOOTH_OUT,
                        HOLD,
                        HOLD_AHEAD,
                        FAST_START,
                        FAST_END,
                        GENTLE,
                        SMOOTH_IN_100,
                        SMOOTH_OUT_100,
                        SOFT_LANDING,
                        CUSTOM,
                        CUSTOM_MENU,
                    ];
                    let springs: Vec<String> = EasingLibrary::spring_presets()
                        .iter()
                        .map(|p| format!("{}={}", quote(p.name), hx(p.spring.bounce())))
                        .collect();
                    vec![
                        quoted_list(&names.map(swift_name)),
                        quoted_list(&KEYFRAME_MENU.map(swift_name)),
                        springs.join(","),
                    ]
                } else if let Some(k) = i[0].strip_prefix("user:") {
                    let name = if k == "11" { "My curve" } else { "" };
                    let id = Id::parse("11111111-2222-3333-4444-555555555555").unwrap();
                    let c =
                        EasingCurve::new(id, name.into(), Interpolation::Hold, EaseHandle::LINEAR, EaseHandle::LINEAR);
                    vec![
                        c.id.to_string(),
                        quote(&c.name),
                        quote(&swift_name(c.display_name())),
                        interp_name(c.interpolation()).into(),
                    ]
                } else {
                    let c = &built_ins[n(0) as usize];
                    vec![
                        c.id.to_string(),
                        quote(&c.name),
                        quote(&swift_name(c.display_name())),
                        interp_name(c.interpolation()).into(),
                        hx(c.out_handle.dx),
                        hx(c.out_handle.dy),
                        hx(c.in_handle.dx),
                        hx(c.in_handle.dy),
                    ]
                }
            }
            "ease_preview" => vec![hex_list(&EasingCurve::built_ins()[n(0) as usize].preview_samples(n(1)))],
            "spring" => {
                let s = SpringEasing::new(hex(i[0]));
                vec![hx(s.bounce()), hx(s.progress(hex(i[1]))), String::new()]
            }
            "spring_preview" => vec![hex_list(&SpringEasing::new(hex(i[0])).preview_samples(n(1)))],
            "spring_bake" => {
                let keys = SpringEasing::new(hex(i[0])).baked_keys(
                    &mut SequentialIds::default(),
                    &hex(i[1]),
                    &hex(i[2]),
                    t(3),
                    t(4),
                    n(5),
                );
                let list: Vec<String> = keys.iter().map(|k| format!("{}={}", ft(k.time), hx(k.value))).collect();
                vec![keys.len().to_string(), list.join(",")]
            }
            "interp_time" => vec![ft(interpolated_time(t(0), t(1), n(2), n(3)))],
            "step" => vec![quote(&step_status::line(&unq(i[0]), n(1)))],
            "words" => {
                let text = unq(i[0]);
                let spans: Vec<String> =
                    word_segmentation::spans_of(&text).iter().map(|r| format!("{}..{}", r.start, r.end)).collect();
                vec![
                    word_segmentation::word_count(&text).to_string(),
                    spans.join(","),
                    quoted_list(&word_segmentation::words(&text)),
                ]
            }
            "words_join" => {
                let joined = word_segmentation::join(&unq_list(i[0]));
                vec![quote(&joined)]
            }
            "tight" => vec![b(word_segmentation::is_tight(&unq(i[0]), &unq(i[1])))],
            "search" => {
                let m = matches(&unq(i[0]), &unq(i[1]), i[2] == "1", i[3] == "1");
                let list: Vec<String> = m.iter().map(|r| format!("{}+{}", r.start, r.end - r.start)).collect();
                vec![m.len().to_string(), list.join(",")]
            }
            "standard_compare" => {
                let c = standard_compare(&unq(i[0]), &unq(i[1])) as i8;
                vec![c.to_string()]
            }
            "ci_contains" => vec![b(ci_contains(&unq(i[0]), &unq(i[1])))],
            "graphemes" => {
                let s = unq(i[0]);
                vec![
                    graphemes(&s).count().to_string(),
                    s.chars().count().to_string(),
                    s.encode_utf16().count().to_string(),
                    s.len().to_string(),
                ]
            }
            _ => return None,
        })
    }

    /// `spring_bake` uses `exp`, `sin` and `cos`, whose last bits differ between Apple libm, the Windows CRT and Rust's
    /// platform libm. Count and key times must match exactly; key values within a relative 1e-9.
    fn spring_bake_close(got: &[String], want: &[&str]) -> bool {
        if got.first().map(String::as_str) != want.first().copied() {
            return false;
        }
        let (Some(g), Some(w)) = (got.get(1), want.get(1)) else { return false };
        let (gk, wk): (Vec<&str>, Vec<&str>) = (g.split(',').collect(), w.split(',').collect());
        gk.len() == wk.len()
            && gk.iter().zip(&wk).all(|(a, b)| {
                let (Some((at, av)), Some((bt, bv))) = (a.split_once('='), b.split_once('=')) else { return false };
                let (x, y) = (hex(av), hex(bv));
                at == bt && (x - y).abs() <= 1e-9 * x.abs().max(y.abs()).max(1.0)
            })
    }

    /// Compares every record; `%.17g` columns (empty in `got`) and the cross-check columns of text tables are skipped.
    fn replay(file: &str) -> (BTreeMap<String, usize>, Vec<String>, BTreeMap<String, usize>) {
        let (mut ok, mut bad, mut uncovered) = (BTreeMap::new(), Vec::new(), BTreeMap::new());
        for line in golden(file).lines().filter(|l| !l.starts_with('#') && !l.is_empty()) {
            let f: Vec<&str> = line.split('\t').collect();
            let arrow = f.iter().position(|x| *x == "->").unwrap();
            let (op, inputs, want) = (f[0], &f[1..arrow], &f[arrow + 1..]);
            if want.first() == Some(&"skip") {
                continue;
            }
            let Some(got) = run(op, inputs) else {
                *uncovered.entry(op.to_string()).or_insert(0) += 1;
                continue;
            };
            let same = if op == "spring_bake" {
                spring_bake_close(&got, want)
            } else {
                got.iter().zip(want).all(|(g, w)| g.is_empty() || g == w)
            };
            if same {
                *ok.entry(op.to_string()).or_insert(0) += 1;
            } else {
                bad.push(format!("{line}\n    rust: {}", got.join("\t")));
            }
        }
        (ok, bad, uncovered)
    }

    fn check(file: &str) {
        let (ok, bad, uncovered) = replay(file);
        println!("{file}: matched {ok:?}");
        println!("{file}: not covered yet {uncovered:?}");
        for b in bad.iter().take(20) {
            println!("MISMATCH {b}");
        }
        assert!(bad.is_empty(), "{} mismatches in {file} (first 20 printed)", bad.len());
    }

    #[test]
    fn ops_match_swift() {
        check("ops.tsv");
    }

    #[test]
    fn text_tables_match_swift() {
        check("text-tables.tsv");
    }
}
