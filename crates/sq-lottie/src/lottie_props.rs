//! Lottie animated properties: static values and keyframes with bezier easing, read straight from the JSON.
//!
//! Spatial position paths (`to`/`ti` tangents) are followed at constant speed along the bezier, eased by the key's curve.
//! A property with an expression (`x`) runs it through `lottie_expr`; an unsupported one keeps the static value.

use serde_json::Value;

/// A number field or `default`.
pub fn num(v: &Value, key: &str, default: f64) -> f64 {
    v.get(key).and_then(Value::as_f64).unwrap_or(default)
}

fn pair(p: &Value) -> [f64; 2] {
    let a = p.as_array();
    let at = |i: usize| a.and_then(|a| a.get(i)).and_then(Value::as_f64).unwrap_or(0.0);
    [at(0), at(1)]
}

/// A bezier path object `{c, v, i, o}` as numbers: `[closed, n, v.., in.., out..]` (so it interpolates like any vector).
fn flat_path(v: &Value) -> Vec<f64> {
    let list = |k: &str| -> Vec<[f64; 2]> {
        v.get(k).and_then(Value::as_array).map(|a| a.iter().map(pair).collect()).unwrap_or_default()
    };
    let verts = list("v");
    let n = verts.len();
    let mut out = vec![if v.get("c").and_then(Value::as_bool).unwrap_or(false) { 1.0 } else { 0.0 }, n as f64];
    for key in ["v", "i", "o"] {
        let mut l = list(key);
        l.resize(n, [0.0, 0.0]);
        out.extend(l.iter().flatten());
    }
    out
}

/// A raw value (`k` or a keyframe `s`) as numbers.
pub fn flat(v: &Value) -> Vec<f64> {
    match v {
        Value::Number(n) => vec![n.as_f64().unwrap_or(0.0)],
        Value::Array(a) => match a.first() {
            Some(Value::Object(_)) => a.first().map(flat_path).unwrap_or_default(),
            _ => a.iter().filter_map(Value::as_f64).collect(),
        },
        Value::Object(_) => flat_path(v),
        _ => Vec::new(),
    }
}

fn comp(v: &Value, d: usize, default: f64) -> f64 {
    match v {
        Value::Number(n) => n.as_f64().unwrap_or(default),
        Value::Array(a) => a.get(d).or_else(|| a.first()).and_then(Value::as_f64).unwrap_or(default),
        _ => default,
    }
}

/// The y of the cubic bezier (0,0) (x1,y1) (x2,y2) (1,1) at horizontal position `x`.
pub fn ease(x1: f64, y1: f64, x2: f64, y2: f64, x: f64) -> f64 {
    let b = |a: f64, c: f64, t: f64| {
        let u = 1.0 - t;
        3.0 * u * u * t * a + 3.0 * u * t * t * c + t * t * t
    };
    let (mut lo, mut hi) = (0.0, 1.0);
    for _ in 0..32 {
        let mid = (lo + hi) / 2.0;
        if b(x1, x2, mid) < x {
            lo = mid;
        } else {
            hi = mid;
        }
    }
    b(y1, y2, (lo + hi) / 2.0)
}

/// The value of property `p` (`{a, k}`) at frame `t`, expression included; empty when the property is missing.
pub fn eval(p: &Value, t: f64) -> Vec<f64> {
    if let Some(src) = p.get("x").and_then(Value::as_str)
        && let Some(v) = crate::lottie_expr::run(src, p, t)
    {
        return v;
    }
    eval_raw(p, t)
}

/// The point at `y` (0..1 of the arc length) on the bezier from `s` to `e` with the key's tangents, if it has any.
fn spatial(a: &Value, s: &[f64], e: &[f64], y: f64) -> Option<Vec<f64>> {
    let (to, ti) = (flat(a.get("to")?), flat(a.get("ti")?));
    let n = s.len().min(e.len()).min(to.len()).min(ti.len());
    if n < 2 {
        return None;
    }
    let at = |u: f64| -> Vec<f64> {
        let v = 1.0 - u;
        (0..n)
            .map(|d| {
                v * v * v * s[d]
                    + 3.0 * v * v * u * (s[d] + to[d])
                    + 3.0 * v * u * u * (e[d] + ti[d])
                    + u * u * u * e[d]
            })
            .collect()
    };
    const N: usize = 100;
    let mut table = vec![0.0f64];
    let mut prev = at(0.0);
    for i in 1..=N {
        let cur = at(i as f64 / N as f64);
        let d = prev.iter().zip(&cur).map(|(a, b)| (a - b).powi(2)).sum::<f64>().sqrt();
        table.push(table[i - 1] + d);
        prev = cur;
    }
    let total = table[N];
    let u = if total <= 1e-9 {
        y
    } else {
        let target = y.clamp(0.0, 1.0) * total;
        let i = table.partition_point(|&l| l < target).clamp(1, N);
        let (l0, l1) = (table[i - 1], table[i]);
        let f = if l1 > l0 { (target - l0) / (l1 - l0) } else { 0.0 };
        (i as f64 - 1.0 + f) / N as f64
    };
    let mut out = at(u);
    for (d, &sd) in s.iter().enumerate().skip(n) {
        out.push(sd + (e.get(d).copied().unwrap_or(sd) - sd) * y);
    }
    Some(out)
}

/// `eval` without expressions.
pub fn eval_raw(p: &Value, t: f64) -> Vec<f64> {
    let k = &p["k"];
    let Some(kfs) = k.as_array().filter(|a| a.first().is_some_and(|f| f.get("t").is_some())) else {
        return flat(k);
    };
    let Some(first) = kfs.first() else { return Vec::new() };
    if t <= num(first, "t", 0.0) {
        return flat(&first["s"]);
    }
    for w in kfs.windows(2) {
        let (a, b) = (&w[0], &w[1]);
        let (t0, t1) = (num(a, "t", 0.0), num(b, "t", 0.0));
        if t >= t1 {
            continue;
        }
        let s = flat(&a["s"]);
        if num(a, "h", 0.0) == 1.0 || t1 <= t0 {
            return s;
        }
        let e = if a.get("e").is_some() { flat(&a["e"]) } else { flat(&b["s"]) };
        let x = (t - t0) / (t1 - t0);
        let ey = ease(
            comp(&a["o"]["x"], 0, 0.0),
            comp(&a["o"]["y"], 0, 0.0),
            comp(&a["i"]["x"], 0, 1.0),
            comp(&a["i"]["y"], 0, 1.0),
            x,
        );
        if let Some(v) = spatial(a, &s, &e, ey) {
            return v;
        }
        return s
            .iter()
            .enumerate()
            .map(|(d, &sv)| {
                let ev = e.get(d).copied().unwrap_or(sv);
                let y = ease(
                    comp(&a["o"]["x"], d, 0.0),
                    comp(&a["o"]["y"], d, 0.0),
                    comp(&a["i"]["x"], d, 1.0),
                    comp(&a["i"]["y"], d, 1.0),
                    x,
                );
                sv + (ev - sv) * y
            })
            .collect();
    }
    let last = kfs.last().map(|l| flat(&l["s"])).unwrap_or_default();
    if last.is_empty() && kfs.len() >= 2 { flat(&kfs[kfs.len() - 2]["e"]) } else { last }
}

/// The first number of a property, or `default`.
pub fn scalar(p: &Value, t: f64, default: f64) -> f64 {
    eval(p, t).first().copied().unwrap_or(default)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn spatial_tangents_bend_the_motion_path() {
        // From (0,0) to (100,0) with both tangents pulling up: the middle is above the straight line.
        let p = json!({"k":[
            {"t":0,"s":[0.0,0.0],"to":[0.0,-50.0],"ti":[0.0,-50.0],"o":{"x":[0.0],"y":[0.0]},"i":{"x":[1.0],"y":[1.0]}},
            {"t":10,"s":[100.0,0.0]}]});
        let mid = eval(&p, 5.0);
        assert!((mid[0] - 50.0).abs() < 1.0 && mid[1] < -30.0, "{mid:?}");
        assert_eq!(eval(&p, 10.0), vec![100.0, 0.0]);
    }

    #[test]
    fn static_and_linear_keyframes() {
        assert_eq!(eval(&json!({"a":0,"k":[1.0,2.0]}), 5.0), vec![1.0, 2.0]);
        let p = json!({"a":1,"k":[
            {"t":0,"s":[0.0],"o":{"x":[0.0],"y":[0.0]},"i":{"x":[1.0],"y":[1.0]}},
            {"t":10,"s":[100.0]}]});
        assert!((scalar(&p, 5.0, 0.0) - 50.0).abs() < 1e-6);
        assert_eq!(scalar(&p, 20.0, 0.0), 100.0);
        assert_eq!(scalar(&p, -3.0, 9.0), 0.0);
    }

    #[test]
    fn ease_in_out_is_slow_at_the_ends_and_hold_stays() {
        let p = json!({"k":[
            {"t":0,"s":[0.0],"o":{"x":0.8,"y":0.0},"i":{"x":0.2,"y":1.0}},
            {"t":10,"s":[100.0]}]});
        assert!(scalar(&p, 1.0, 0.0) < 10.0);
        assert!((scalar(&p, 5.0, 0.0) - 50.0).abs() < 1.0);
        let h = json!({"k":[{"t":0,"s":[1.0],"h":1},{"t":10,"s":[7.0]}]});
        assert_eq!(scalar(&h, 9.9, 0.0), 1.0);
    }
}
