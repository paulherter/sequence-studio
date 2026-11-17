//! A tiny sandboxed interpreter for the expression subset Lottie exports use. No I/O, no loops, no user functions: just
//! arithmetic on numbers and vectors, `time`, `index`, `value`, `wiggle`, `loopOut` / `loopIn` (cycle, pingpong, offset,
//! continue), `linear` / `ease*`, `clamp`, `Math.*`, the `$bm_*` helpers bodymovin writes, and
//! `thisComp.layer(name | index).transform.position | scale | rotation | opacity | anchorPoint` (also `.valueAtTime`).
//! Anything else makes `run` return `None`; the caller keeps the static value and a log line says which expression.
//!
//! Matches Swift: its ThorVG build has no expressions at all (config.h), so this subset is already a superset and `if`, `for`,
//! `function` and string methods stay unparsed.

use crate::lottie_props::{eval_raw, num};
use serde_json::Value;
use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::rc::Rc;

/// What an expression sees besides its own property.
#[derive(Default)]
pub struct Env {
    /// Frame rate of the composition being drawn.
    pub fps: f64,
    /// `ind` of the layer being drawn.
    pub index: f64,
    /// The layers array of the composition being drawn (for `thisComp.layer`).
    pub layers: Option<Rc<Value>>,
    depth: u32,
}

thread_local! {
    static ENV: RefCell<Env> = RefCell::new(Env { fps: 30.0, ..Env::default() });
    static LOGGED: RefCell<HashSet<String>> = RefCell::new(HashSet::new());
}

/// Sets the composition (frame rate and layers); returns the previous one for `restore_comp`.
pub fn set_comp(fps: f64, layers: Option<Rc<Value>>) -> (f64, Option<Rc<Value>>) {
    ENV.with(|e| {
        let mut e = e.borrow_mut();
        (std::mem::replace(&mut e.fps, fps), std::mem::replace(&mut e.layers, layers))
    })
}

/// Puts back what `set_comp` returned.
pub fn restore_comp(prev: (f64, Option<Rc<Value>>)) {
    ENV.with(|e| {
        let mut e = e.borrow_mut();
        e.fps = prev.0;
        e.layers = prev.1;
    });
}

/// Sets the `index` of the layer being drawn; returns the previous one.
pub fn set_index(i: f64) -> f64 {
    ENV.with(|e| std::mem::replace(&mut e.borrow_mut().index, i))
}

#[derive(Clone, Debug)]
enum Tok {
    Num(f64),
    Str(String),
    Id(String),
    Op(String),
    Sep,
}

fn lex(src: &str) -> Option<Vec<Tok>> {
    let c: Vec<char> = src.chars().collect();
    let mut out = Vec::new();
    let mut i = 0;
    while i < c.len() {
        let ch = c[i];
        if ch == '\n' || ch == ';' {
            out.push(Tok::Sep);
            i += 1;
        } else if ch.is_whitespace() {
            i += 1;
        } else if ch == '/' && c.get(i + 1) == Some(&'/') {
            while i < c.len() && c[i] != '\n' {
                i += 1;
            }
        } else if ch == '/' && c.get(i + 1) == Some(&'*') {
            i += 2;
            while i + 1 < c.len() && !(c[i] == '*' && c[i + 1] == '/') {
                i += 1;
            }
            i += 2;
        } else if ch.is_ascii_digit() || (ch == '.' && c.get(i + 1).is_some_and(char::is_ascii_digit)) {
            let s = i;
            while i < c.len() && (c[i].is_ascii_digit() || c[i] == '.') {
                i += 1;
            }
            if i < c.len() && (c[i] == 'e' || c[i] == 'E') {
                i += 1;
                if i < c.len() && (c[i] == '+' || c[i] == '-') {
                    i += 1;
                }
                while i < c.len() && c[i].is_ascii_digit() {
                    i += 1;
                }
            }
            out.push(Tok::Num(c[s..i].iter().collect::<String>().parse().ok()?));
        } else if ch.is_alphabetic() || ch == '_' || ch == '$' {
            let s = i;
            while i < c.len() && (c[i].is_alphanumeric() || c[i] == '_' || c[i] == '$') {
                i += 1;
            }
            out.push(Tok::Id(c[s..i].iter().collect()));
        } else if ch == '"' || ch == '\'' {
            let s = i + 1;
            i += 1;
            while i < c.len() && c[i] != ch {
                i += 1;
            }
            out.push(Tok::Str(c.get(s..i)?.iter().collect()));
            i += 1;
        } else {
            let three: String = c[i..(i + 3).min(c.len())].iter().collect();
            let two: String = c[i..(i + 2).min(c.len())].iter().collect();
            let op = if three == "===" || three == "!==" {
                three
            } else if ["==", "!=", "<=", ">=", "&&", "||"].contains(&two.as_str()) {
                two
            } else {
                ch.to_string()
            };
            if !"+-*/%()[],.?:<>=!&|".contains(&op[..1]) {
                return None;
            }
            i += op.chars().count();
            out.push(Tok::Op(op));
        }
    }
    Some(out)
}

#[derive(Debug)]
enum Ex {
    Num(f64),
    Str(String),
    Id(String),
    Arr(Vec<Ex>),
    Un(char, Box<Ex>),
    Bin(String, Box<Ex>, Box<Ex>),
    Tern(Box<Ex>, Box<Ex>, Box<Ex>),
    Member(Box<Ex>, String),
    Index(Box<Ex>, Box<Ex>),
    Call(Box<Ex>, Vec<Ex>),
    Assign(String, Box<Ex>),
}

struct Parser {
    t: Vec<Tok>,
    i: usize,
}

impl Parser {
    fn peek_op(&self) -> Option<&str> {
        match self.t.get(self.i) {
            Some(Tok::Op(o)) => Some(o),
            _ => None,
        }
    }

    fn eat(&mut self, op: &str) -> bool {
        if self.peek_op() == Some(op) {
            self.i += 1;
            true
        } else {
            false
        }
    }

    fn statement(&mut self) -> Option<Ex> {
        if let Some(Tok::Id(k)) = self.t.get(self.i)
            && ["var", "let", "const"].contains(&k.as_str())
        {
            self.i += 1;
        }
        if let (Some(Tok::Id(name)), Some(Tok::Op(o))) = (self.t.get(self.i), self.t.get(self.i + 1))
            && o == "="
        {
            let name = name.clone();
            self.i += 2;
            return Some(Ex::Assign(name, Box::new(self.ternary()?)));
        }
        self.ternary()
    }

    fn ternary(&mut self) -> Option<Ex> {
        let c = self.binary(1)?;
        if self.eat("?") {
            let a = self.ternary()?;
            if !self.eat(":") {
                return None;
            }
            let b = self.ternary()?;
            return Some(Ex::Tern(Box::new(c), Box::new(a), Box::new(b)));
        }
        Some(c)
    }

    fn binary(&mut self, min: u8) -> Option<Ex> {
        let mut l = self.unary()?;
        while let Some(op) = self.peek_op().map(str::to_owned) {
            let prec = match op.as_str() {
                "||" => 1,
                "&&" => 2,
                "==" | "!=" | "===" | "!==" => 3,
                "<" | ">" | "<=" | ">=" => 4,
                "+" | "-" => 5,
                "*" | "/" | "%" => 6,
                _ => break,
            };
            if prec < min {
                break;
            }
            self.i += 1;
            let r = self.binary(prec + 1)?;
            l = Ex::Bin(op, Box::new(l), Box::new(r));
        }
        Some(l)
    }

    fn unary(&mut self) -> Option<Ex> {
        for u in ['-', '+', '!'] {
            if self.eat(&u.to_string()) {
                return Some(Ex::Un(u, Box::new(self.unary()?)));
            }
        }
        self.postfix()
    }

    fn postfix(&mut self) -> Option<Ex> {
        let mut e = self.primary()?;
        loop {
            if self.eat(".") {
                let Some(Tok::Id(n)) = self.t.get(self.i).cloned() else { return None };
                self.i += 1;
                e = Ex::Member(Box::new(e), n);
            } else if self.eat("[") {
                let i = self.ternary()?;
                if !self.eat("]") {
                    return None;
                }
                e = Ex::Index(Box::new(e), Box::new(i));
            } else if self.eat("(") {
                let mut args = Vec::new();
                if !self.eat(")") {
                    loop {
                        args.push(self.ternary()?);
                        if self.eat(")") {
                            break;
                        }
                        if !self.eat(",") {
                            return None;
                        }
                    }
                }
                e = Ex::Call(Box::new(e), args);
            } else {
                return Some(e);
            }
        }
    }

    fn primary(&mut self) -> Option<Ex> {
        let t = self.t.get(self.i)?.clone();
        self.i += 1;
        match t {
            Tok::Num(n) => Some(Ex::Num(n)),
            Tok::Str(s) => Some(Ex::Str(s)),
            Tok::Id(s) => Some(Ex::Id(s)),
            Tok::Op(o) if o == "(" => {
                let e = self.ternary()?;
                self.eat(")").then_some(e)
            }
            Tok::Op(o) if o == "[" => {
                let mut items = Vec::new();
                if !self.eat("]") {
                    loop {
                        items.push(self.ternary()?);
                        if self.eat("]") {
                            break;
                        }
                        if !self.eat(",") {
                            return None;
                        }
                    }
                }
                Some(Ex::Arr(items))
            }
            _ => None,
        }
    }
}

fn parse(src: &str) -> Option<Vec<Ex>> {
    let mut p = Parser { t: lex(src)?, i: 0 };
    let mut out = Vec::new();
    while p.i < p.t.len() {
        if matches!(p.t[p.i], Tok::Sep) {
            p.i += 1;
            continue;
        }
        out.push(p.statement()?);
        if p.i < p.t.len() && !matches!(p.t[p.i], Tok::Sep) {
            return None;
        }
    }
    (!out.is_empty()).then_some(out)
}

#[derive(Clone, Debug)]
enum V {
    N(f64),
    A(Vec<f64>),
    S(String),
    Math,
    Comp,
    Layer(usize),
    LProp(usize, String),
    This,
}

fn vecv(v: Vec<f64>) -> V {
    if v.len() == 1 { V::N(v[0]) } else { V::A(v) }
}

fn hash(n: i64, seed: u32) -> f64 {
    let mut h = (n as u64).wrapping_mul(0x9E37_79B9_7F4A_7C15) ^ u64::from(seed).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    h ^= h >> 30;
    h = h.wrapping_mul(0xBF58_476D_1CE4_E5B9);
    h ^= h >> 27;
    h = h.wrapping_mul(0x94D0_49BB_1331_11EB);
    h ^= h >> 31;
    (h >> 11) as f64 / (1u64 << 53) as f64 * 2.0 - 1.0
}

/// Smooth value noise in -1..1.
fn noise(x: f64, seed: u32) -> f64 {
    let i = x.floor();
    let f = x - i;
    let s = f * f * (3.0 - 2.0 * f);
    let (a, b) = (hash(i as i64, seed), hash(i as i64 + 1, seed));
    a + (b - a) * s
}

struct Cx<'a> {
    p: &'a Value,
    t: f64,
    fps: f64,
    index: f64,
    layers: Option<Rc<Value>>,
    value: Vec<f64>,
    vars: HashMap<String, V>,
}

fn zip(a: &[f64], b: &[f64], f: impl Fn(f64, f64) -> f64) -> Vec<f64> {
    (0..a.len().max(b.len())).map(|i| f(a.get(i).copied().unwrap_or(0.0), b.get(i).copied().unwrap_or(0.0))).collect()
}

impl Cx<'_> {
    fn vec_of(&self, v: &V) -> Option<Vec<f64>> {
        match v {
            V::N(n) => Some(vec![*n]),
            V::A(a) => Some(a.clone()),
            V::This => Some(self.value.clone()),
            V::LProp(l, name) => self.layer_prop(*l, name, self.t),
            _ => None,
        }
    }

    fn scalar(&self, v: &V) -> Option<f64> {
        self.vec_of(v)?.first().copied()
    }

    fn layer_prop(&self, layer: usize, name: &str, t: f64) -> Option<Vec<f64>> {
        let layers = self.layers.as_ref()?;
        let l = layers.as_array()?.get(layer)?;
        let key = match name {
            "position" => "p",
            "scale" => "s",
            "rotation" => "r",
            "opacity" => "o",
            "anchorPoint" | "anchor_point" => "a",
            _ => return None,
        };
        let ks = &l["ks"];
        let prop = if key == "r" && ks.get("r").is_none() { &ks["rz"] } else { &ks[key] };
        let v = if key == "p" && prop.get("s").and_then(Value::as_bool) == Some(true) {
            vec![crate::lottie_props::scalar(&prop["x"], t, 0.0), crate::lottie_props::scalar(&prop["y"], t, 0.0)]
        } else {
            crate::lottie_props::eval(prop, t)
        };
        Some(v)
    }

    fn find_layer(&self, arg: &V) -> Option<usize> {
        let layers = self.layers.as_ref()?.as_array()?;
        match arg {
            V::S(name) => layers.iter().position(|l| l.get("nm").and_then(Value::as_str) == Some(name)),
            V::N(n) => {
                let n = *n as i64;
                layers
                    .iter()
                    .position(|l| l.get("ind").and_then(Value::as_i64) == Some(n))
                    .or_else(|| usize::try_from(n - 1).ok().filter(|i| *i < layers.len()))
            }
            _ => None,
        }
    }

    fn eval(&mut self, e: &Ex) -> Option<V> {
        Some(match e {
            Ex::Num(n) => V::N(*n),
            Ex::Str(s) => V::S(s.clone()),
            Ex::Id(n) => match n.as_str() {
                _ if self.vars.contains_key(n) => self.vars.get(n)?.clone(),
                "time" => V::N(self.t / self.fps),
                "index" => V::N(self.index),
                "value" => vecv(self.value.clone()),
                "thisComp" => V::Comp,
                "thisLayer" => V::This,
                "thisProperty" => V::This,
                "Math" => V::Math,
                "PI" => V::N(std::f64::consts::PI),
                _ => return None,
            },
            Ex::Arr(items) => {
                let mut out = Vec::new();
                for i in items {
                    let v = self.eval(i)?;
                    out.extend(self.vec_of(&v)?);
                }
                V::A(out)
            }
            Ex::Un(op, x) => {
                let v = self.eval(x)?;
                let a = self.vec_of(&v)?;
                match op {
                    '-' => vecv(a.iter().map(|x| -x).collect()),
                    '!' => V::N(f64::from(a.first().copied().unwrap_or(0.0) == 0.0)),
                    _ => vecv(a),
                }
            }
            Ex::Bin(op, l, r) => {
                let (lv, rv) = (self.eval(l)?, self.eval(r)?);
                let (a, b) = (self.vec_of(&lv)?, self.vec_of(&rv)?);
                self.binop(op, &a, &b)?
            }
            Ex::Tern(c, a, b) => {
                let cv = self.eval(c)?;
                if self.scalar(&cv)? != 0.0 { self.eval(a)? } else { self.eval(b)? }
            }
            Ex::Assign(name, x) => {
                let v = self.eval(x)?;
                self.vars.insert(name.clone(), v.clone());
                v
            }
            Ex::Member(obj, name) => {
                let o = self.eval(obj)?;
                match (&o, name.as_str()) {
                    (V::Math, "PI") => V::N(std::f64::consts::PI),
                    (V::Math, "E") => V::N(std::f64::consts::E),
                    (V::Comp, "frameDuration") => V::N(1.0 / self.fps),
                    (V::Layer(_), "transform") => o,
                    (V::Layer(l), p) => V::LProp(*l, p.to_owned()),
                    _ => return None,
                }
            }
            Ex::Index(obj, i) => {
                let (o, iv) = (self.eval(obj)?, self.eval(i)?);
                let a = self.vec_of(&o)?;
                V::N(*a.get(self.scalar(&iv)? as usize)?)
            }
            Ex::Call(callee, args) => {
                let mut av = Vec::new();
                for a in args {
                    av.push(self.eval(a)?);
                }
                match &**callee {
                    Ex::Member(obj, name) => {
                        let o = self.eval(obj)?;
                        self.method(&o, name, &av)?
                    }
                    Ex::Id(name) => self.func(name, &av)?,
                    _ => return None,
                }
            }
        })
    }

    fn binop(&self, op: &str, a: &[f64], b: &[f64]) -> Option<V> {
        let cmp = |f: fn(f64, f64) -> bool| {
            V::N(f64::from(f(a.first().copied().unwrap_or(0.0), b.first().copied().unwrap_or(0.0))))
        };
        Some(match op {
            "+" => vecv(zip(a, b, |x, y| x + y)),
            "-" => vecv(zip(a, b, |x, y| x - y)),
            "*" | "/" | "%" => {
                let f = |x: f64, y: f64| match op {
                    "*" => x * y,
                    "/" => x / y,
                    _ => x % y,
                };
                match (a.len(), b.len()) {
                    (1, _) => vecv(b.iter().map(|y| f(a[0], *y)).collect()),
                    (_, 1) => vecv(a.iter().map(|x| f(*x, b[0])).collect()),
                    _ => vecv(zip(a, b, f)),
                }
            }
            "<" => cmp(|x, y| x < y),
            ">" => cmp(|x, y| x > y),
            "<=" => cmp(|x, y| x <= y),
            ">=" => cmp(|x, y| x >= y),
            "==" | "===" => cmp(|x, y| (x - y).abs() < 1e-12),
            "!=" | "!==" => cmp(|x, y| (x - y).abs() >= 1e-12),
            "&&" => cmp(|x, y| x != 0.0 && y != 0.0),
            "||" => cmp(|x, y| x != 0.0 || y != 0.0),
            _ => return None,
        })
    }

    fn method(&mut self, obj: &V, name: &str, args: &[V]) -> Option<V> {
        match (obj, name) {
            (V::Comp, "layer") => self.find_layer(args.first()?).map(V::Layer),
            (V::LProp(l, p), "valueAtTime") => {
                let t = self.scalar(args.first()?)? * self.fps;
                Some(vecv(self.layer_prop(*l, p, t)?))
            }
            (V::This, "valueAtTime") => {
                let t = self.scalar(args.first()?)? * self.fps;
                Some(vecv(eval_raw(self.p, t)))
            }
            (V::Math, n) | (_, n @ ("wiggle" | "loopOut" | "loopIn")) => self.func(n, args),
            _ => None,
        }
    }

    fn func(&mut self, name: &str, args: &[V]) -> Option<V> {
        let n = |i: usize| -> Option<f64> { self.scalar(args.get(i)?) };
        let one = |f: fn(f64) -> f64| -> Option<V> { Some(V::N(f(n(0)?))) };
        match name {
            "sin" => one(f64::sin),
            "cos" => one(f64::cos),
            "tan" => one(f64::tan),
            "asin" => one(f64::asin),
            "acos" => one(f64::acos),
            "atan" => one(f64::atan),
            "sqrt" => one(f64::sqrt),
            "abs" => one(f64::abs),
            "floor" => one(f64::floor),
            "ceil" => one(f64::ceil),
            "round" => one(f64::round),
            "exp" => one(f64::exp),
            "log" => one(f64::ln),
            "degreesToRadians" => one(f64::to_radians),
            "radiansToDegrees" => one(f64::to_degrees),
            "atan2" => Some(V::N(n(0)?.atan2(n(1)?))),
            "pow" => Some(V::N(n(0)?.powf(n(1)?))),
            "min" => Some(V::N(n(0)?.min(n(1)?))),
            "max" => Some(V::N(n(0)?.max(n(1)?))),
            "random" => {
                let seed = (self.t * 1000.0) as i64;
                let u = (hash(seed, 7) + 1.0) / 2.0;
                Some(V::N(match args.len() {
                    0 => u,
                    1 => u * n(0)?,
                    _ => n(0)? + u * (n(1)? - n(0)?),
                }))
            }
            "clamp" => Some(V::N(n(0)?.clamp(n(1)?.min(n(2)?), n(1)?.max(n(2)?)))),
            "length" => {
                let a = self.vec_of(args.first()?)?;
                let b = args.get(1).and_then(|v| self.vec_of(v)).unwrap_or_default();
                let d = if args.len() > 1 { zip(&a, &b, |x, y| x - y) } else { a };
                Some(V::N(d.iter().map(|x| x * x).sum::<f64>().sqrt()))
            }
            "linear" | "ease" | "easeIn" | "easeOut" => {
                let (t, t0, t1, v0, v1) = if args.len() >= 5 {
                    (n(0)?, n(1)?, n(2)?, self.vec_of(&args[3])?, self.vec_of(&args[4])?)
                } else {
                    (n(0)?, 0.0, 1.0, self.vec_of(args.get(1)?)?, self.vec_of(args.get(2)?)?)
                };
                let x = if t1 == t0 { 1.0 } else { ((t - t0) / (t1 - t0)).clamp(0.0, 1.0) };
                let y = match name {
                    "ease" => x * x * (3.0 - 2.0 * x),
                    "easeIn" => x * x,
                    "easeOut" => 1.0 - (1.0 - x) * (1.0 - x),
                    _ => x,
                };
                Some(vecv(zip(&v0, &v1, |a, b| a + (b - a) * y)))
            }
            "$bm_sum" | "add" => self.binop("+", &self.vec_of(args.first()?)?, &self.vec_of(args.get(1)?)?),
            "$bm_sub" | "sub" => self.binop("-", &self.vec_of(args.first()?)?, &self.vec_of(args.get(1)?)?),
            "$bm_mul" | "mul" => self.binop("*", &self.vec_of(args.first()?)?, &self.vec_of(args.get(1)?)?),
            "$bm_div" | "div" => self.binop("/", &self.vec_of(args.first()?)?, &self.vec_of(args.get(1)?)?),
            "$bm_mod" => self.binop("%", &self.vec_of(args.first()?)?, &self.vec_of(args.get(1)?)?),
            "wiggle" => {
                let (freq, amp) = (n(0)?, n(1)?);
                let octaves = n(2).unwrap_or(1.0).clamp(1.0, 8.0) as i32;
                let mult = n(3).unwrap_or(0.5);
                let time = n(4).unwrap_or(self.t / self.fps);
                let out = self
                    .value
                    .iter()
                    .enumerate()
                    .map(|(d, v)| {
                        let mut add = 0.0;
                        for o in 0..octaves {
                            add += noise(time * freq * f64::from(1 << o), d as u32 * 31 + 5) * amp * mult.powi(o);
                        }
                        v + add
                    })
                    .collect();
                Some(vecv(out))
            }
            "loopOut" | "loopIn" => {
                let kind = match args.first() {
                    Some(V::S(s)) => s.as_str(),
                    _ => "cycle",
                };
                Some(vecv(self.looped(name == "loopOut", kind)))
            }
            _ => None,
        }
    }

    /// The property repeated outside its first / last keyframe.
    fn looped(&self, out: bool, kind: &str) -> Vec<f64> {
        let kfs = self.p["k"].as_array().filter(|a| a.first().is_some_and(|f| f.get("t").is_some()));
        let Some(kfs) = kfs.filter(|k| k.len() >= 2) else { return self.value.clone() };
        let (t0, t1) = (num(&kfs[0], "t", 0.0), num(&kfs[kfs.len() - 1], "t", 0.0));
        let dur = t1 - t0;
        let inside = if out { self.t <= t1 } else { self.t >= t0 };
        if dur <= 0.0 || inside {
            return self.value.clone();
        }
        let rel = if out { self.t - t0 } else { t1 - self.t };
        let cycles = (rel / dur).floor();
        let r = rel - cycles * dur;
        let ping = kind == "pingpong" && cycles as i64 % 2 != 0;
        // Local position inside the keyframe range, counted from the end that is being extended.
        let local = if ping { dur - r } else { r };
        let t = if out { t0 + local } else { t1 - local };
        let base = eval_raw(self.p, t);
        match kind {
            "offset" => {
                let (a, b) = (eval_raw(self.p, t0), eval_raw(self.p, t1));
                let delta = zip(&b, &a, |x, y| x - y);
                let sign = if out { 1.0 } else { -1.0 };
                zip(&base, &delta, |v, d| v + sign * d * cycles)
            }
            "continue" => self.value.clone(),
            _ => base,
        }
    }
}

/// Runs expression `src` of property `p` at frame `t`; `None` when it cannot (the caller keeps the static value).
pub fn run(src: &str, p: &Value, t: f64) -> Option<Vec<f64>> {
    let (fps, index, layers, depth) = ENV.with(|e| {
        let e = e.borrow();
        (e.fps.max(1e-6), e.index, e.layers.as_ref().map(Rc::clone), e.depth)
    });
    if depth > 4 {
        return None;
    }
    ENV.with(|e| e.borrow_mut().depth += 1);
    let result = (|| {
        let prog = parse(src)?;
        let mut cx = Cx { p, t, fps, index, layers, value: eval_raw(p, t), vars: HashMap::new() };
        let mut last = None;
        for s in &prog {
            last = Some(cx.eval(s)?);
        }
        let v = cx.vars.get("$bm_rt").cloned().or(last)?;
        let out = cx.vec_of(&v)?;
        (!out.is_empty() && out.iter().all(|x| x.is_finite())).then_some(out)
    })();
    ENV.with(|e| e.borrow_mut().depth -= 1);
    if result.is_none() {
        let first = LOGGED.with(|l| l.borrow_mut().insert(src.to_owned()));
        if first {
            log_unsupported(src);
        }
    }
    result
}

#[allow(clippy::print_stderr)]
fn log_unsupported(src: &str) {
    let short: String = src.chars().take(80).collect();
    eprintln!("sq-lottie: unsupported expression, using the static value: {short}");
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;
    use crate::lottie_props::eval;
    use serde_json::json;

    fn prop(k: Value, x: &str) -> Value {
        json!({"a": 0, "k": k, "x": x})
    }

    #[test]
    fn arithmetic_time_and_value() {
        set_comp(10.0, None);
        // 20 frames at 10 fps = 2 s.
        let p = prop(json!([100.0, 50.0]), "[value[0] * 2, value[1] + time * 10]");
        assert_eq!(eval(&p, 20.0), vec![200.0, 70.0]);
        let p = prop(json!(5.0), "$bm_rt = $bm_sum($bm_mul(value, 3), Math.sin(0)); ");
        assert_eq!(eval(&p, 0.0), vec![15.0]);
    }

    #[test]
    fn loop_out_cycle_and_pingpong() {
        set_comp(10.0, None);
        let keys = json!([
            {"t":0,"s":[0.0],"o":{"x":[0.0],"y":[0.0]},"i":{"x":[1.0],"y":[1.0]}},
            {"t":10,"s":[100.0]}]);
        let cyc = prop(keys.clone(), "loopOut(\"cycle\")");
        assert!((eval(&cyc, 15.0)[0] - 50.0).abs() < 1e-6);
        let ping = prop(keys.clone(), "loopOut(\"pingpong\")");
        assert!((eval(&ping, 15.0)[0] - 50.0).abs() < 1e-6);
        assert!((eval(&ping, 12.0)[0] - 80.0).abs() < 1e-6);
        assert!((eval(&cyc, 12.0)[0] - 20.0).abs() < 1e-6);
        let off = prop(keys, "loopOut(\"offset\")");
        assert!((eval(&off, 15.0)[0] - 150.0).abs() < 1e-6);
    }

    #[test]
    fn wiggle_stays_within_amplitude_and_is_deterministic() {
        set_comp(30.0, None);
        let p = prop(json!([100.0]), "wiggle(2, 10)");
        let a = eval(&p, 7.0)[0];
        assert!((90.0..=110.0).contains(&a));
        assert_eq!(a, eval(&p, 7.0)[0]);
        assert_ne!(a, eval(&p, 19.0)[0]);
    }

    #[test]
    fn this_comp_layer_transform_and_fallback() {
        let layers = Rc::new(json!([{"ind":1,"nm":"Ctrl","ks":{"p":{"a":0,"k":[30.0,40.0]},"r":{"a":0,"k":15.0}}}]));
        let prev = set_comp(30.0, Some(layers));
        let p = prop(json!([0.0, 0.0]), "thisComp.layer(\"Ctrl\").transform.position + [1, 1]");
        assert_eq!(eval(&p, 0.0), vec![31.0, 41.0]);
        let p = prop(json!(0.0), "thisComp.layer(1).transform.rotation * 2");
        assert_eq!(eval(&p, 0.0), vec![30.0]);
        restore_comp(prev);
        // Unsupported: keeps the static value.
        let p = prop(json!([7.0]), "for (var i = 0; i < 3; i++) {}");
        assert_eq!(eval(&p, 0.0), vec![7.0]);
    }
}
