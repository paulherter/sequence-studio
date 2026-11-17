//! Port of `SQUIKit/Sources/SQUIKit/Mascot/SQMascotModel.swift`.
//! The animation data is `resources/Mascot/pip-anim.json` (design source of truth, copied unchanged); `SQMascotLibrary::shared`
//! reads it from the binary.

// SQMascot (Pip): pose model, easings and key-pose animations. Pure value math, no drawing, no clock. The rules follow the
// `ease` notes of the JSON.

use crate::controls_grid::CGRect;
use serde_json::{Map, Value};
use std::collections::HashMap;
use std::fmt;
use std::ops::{Index, IndexMut, RangeInclusive};
use std::sync::OnceLock;

/// Numeric pose channels. The raw JSON key is the Swift case name (`json_key`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
#[repr(usize)]
pub enum SQMascotKey {
    Tx,
    Ty,
    Sx,
    Sy,
    Rot,
    Fx,
    Fy,
    Ex,
    Ey,
    Esp,
    Bl,
    Bly,
    Bldx,
    Hd,
    HL,
    Mgx,
    Mgy,
    Mgs,
    Mgo,
    Bs,
    Dpx,
    Dpy,
    Dps,
    D1,
    D2,
    D3,
    Z1,
    Z2,
    Z3,
    Z1y,
    Z2y,
    Z3y,
    Sp,
    H1,
    H2,
    Hide,
    Bcy,
    Btilt,
    Bbow,
    Bhl,
    Bsw,
    Bdx,
    BaL,
    BaR,
}

impl SQMascotKey {
    pub const ALL: [SQMascotKey; 44] = [
        Self::Tx,
        Self::Ty,
        Self::Sx,
        Self::Sy,
        Self::Rot,
        Self::Fx,
        Self::Fy,
        Self::Ex,
        Self::Ey,
        Self::Esp,
        Self::Bl,
        Self::Bly,
        Self::Bldx,
        Self::Hd,
        Self::HL,
        Self::Mgx,
        Self::Mgy,
        Self::Mgs,
        Self::Mgo,
        Self::Bs,
        Self::Dpx,
        Self::Dpy,
        Self::Dps,
        Self::D1,
        Self::D2,
        Self::D3,
        Self::Z1,
        Self::Z2,
        Self::Z3,
        Self::Z1y,
        Self::Z2y,
        Self::Z3y,
        Self::Sp,
        Self::H1,
        Self::H2,
        Self::Hide,
        Self::Bcy,
        Self::Btilt,
        Self::Bbow,
        Self::Bhl,
        Self::Bsw,
        Self::Bdx,
        Self::BaL,
        Self::BaR,
    ];

    const JSON_KEYS: [&'static str; 44] = [
        "tx", "ty", "sx", "sy", "rot", "fx", "fy", "ex", "ey", "esp", "bl", "bly", "bldx", "hd", "hL", "mgx", "mgy",
        "mgs", "mgo", "bs", "dpx", "dpy", "dps", "d1", "d2", "d3", "z1", "z2", "z3", "z1y", "z2y", "z3y", "sp", "h1",
        "h2", "hide", "bcy", "btilt", "bbow", "bhl", "bsw", "bdx", "baL", "baR",
    ];

    /// The channel's index in `SQMascotPose::n`.
    pub fn raw_value(self) -> usize {
        self as usize
    }

    pub fn json_key(self) -> &'static str {
        Self::JSON_KEYS[self as usize]
    }

    /// Brow shape channels: taken from the side that has brows when only one side does.
    const BROW: [SQMascotKey; 6] = [Self::Bcy, Self::Btilt, Self::Bbow, Self::Bhl, Self::Bsw, Self::Bdx];
}

/// An eye or mouth shape: kind plus its numeric parameters (JSON order, kind removed).
#[derive(Clone, Debug, PartialEq)]
pub struct SQMascotShape {
    pub kind: String,
    pub a: Vec<f64>,
}

impl SQMascotShape {
    pub fn new(kind: &str, a: Vec<f64>) -> SQMascotShape {
        SQMascotShape { kind: kind.to_string(), a }
    }
}

/// One full pose. `k_eye_l`/`k_eye_r`/`k_mouth` are runtime squeeze factors for a shape swap in progress, `blink` the idle
/// blink openness (1 open); they are not part of the data.
#[derive(Clone, Debug, PartialEq)]
pub struct SQMascotPose {
    pub n: Vec<f64>,
    pub e_l: SQMascotShape,
    pub e_r: SQMascotShape,
    pub m: SQMascotShape,
    pub k_eye_l: f64,
    pub k_eye_r: f64,
    pub k_mouth: f64,
    pub blink: f64,
}

impl Index<SQMascotKey> for SQMascotPose {
    type Output = f64;
    fn index(&self, k: SQMascotKey) -> &f64 {
        &self.n[k.raw_value()]
    }
}

impl IndexMut<SQMascotKey> for SQMascotPose {
    fn index_mut(&mut self, k: SQMascotKey) -> &mut f64 {
        &mut self.n[k.raw_value()]
    }
}

impl SQMascotPose {
    /// A pose with all channels 0 and the given shapes.
    pub fn new(e_l: SQMascotShape, e_r: SQMascotShape, m: SQMascotShape) -> SQMascotPose {
        SQMascotPose {
            n: vec![0.0; SQMascotKey::ALL.len()],
            e_l,
            e_r,
            m,
            k_eye_l: 1.0,
            k_eye_r: 1.0,
            k_mouth: 1.0,
            blink: 1.0,
        }
    }

    /// Mixes `a` toward `b` by `u` (may overshoot). Shapes of the same kind blend; different kinds swap in the middle
    /// while squeezed shut (as the design player does).
    pub fn mix(a: &SQMascotPose, b: &SQMascotPose, u: f64) -> SQMascotPose {
        let mut o = a.clone();
        for i in 0..a.n.len() {
            o.n[i] = a.n[i] + (b.n[i] - a.n[i]) * u;
        }
        let a_brow = a[SQMascotKey::BaL] + a[SQMascotKey::BaR];
        let b_brow = b[SQMascotKey::BaL] + b[SQMascotKey::BaR];
        if a_brow == 0.0 {
            for k in SQMascotKey::BROW {
                o[k] = b[k];
            }
        } else if b_brow == 0.0 {
            for k in SQMascotKey::BROW {
                o[k] = a[k];
            }
        }
        (o.e_l, o.k_eye_l) = Self::shape(&a.e_l, &b.e_l, u);
        (o.e_r, o.k_eye_r) = Self::shape(&a.e_r, &b.e_r, u);
        (o.m, o.k_mouth) = Self::shape(&a.m, &b.m, u);
        o[SQMascotKey::Hide] = if u.clamp(0.0, 1.0) < 1.0 { a[SQMascotKey::Hide] } else { b[SQMascotKey::Hide] };
        o.blink = 1.0;
        o
    }

    fn shape(a: &SQMascotShape, b: &SQMascotShape, u: f64) -> (SQMascotShape, f64) {
        if a.kind == b.kind && a.a.len() == b.a.len() {
            let blended = a.a.iter().zip(&b.a).map(|(x, y)| x + (y - x) * u).collect();
            return (SQMascotShape { kind: a.kind.clone(), a: blended }, 1.0);
        }
        let c = u.clamp(0.0, 1.0);
        (if c < 0.5 { a.clone() } else { b.clone() }, (1.0 - 2.0 * c).abs())
    }
}

/// Easings by the JSON `ease` names.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SQMascotEase {
    Lin,
    Io,
    In,
    Out,
    Back,
    Pop,
    Spring,
}

impl SQMascotEase {
    /// The ease for a JSON name (`lin`, `io`, `in`, `out`, `back`, `pop`, `spring`).
    pub fn from_raw(raw: &str) -> Option<SQMascotEase> {
        Some(match raw {
            "lin" => Self::Lin,
            "io" => Self::Io,
            "in" => Self::In,
            "out" => Self::Out,
            "back" => Self::Back,
            "pop" => Self::Pop,
            "spring" => Self::Spring,
            _ => return None,
        })
    }

    pub fn value(self, t: f64) -> f64 {
        match self {
            Self::Lin => t,
            Self::Io => {
                if t < 0.5 {
                    4.0 * t * t * t
                } else {
                    1.0 - (-2.0 * t + 2.0).powf(3.0) / 2.0
                }
            }
            Self::In => t * t,
            Self::Out => 1.0 - (1.0 - t) * (1.0 - t),
            Self::Back => {
                let v = t - 1.0;
                1.0 + 2.3 * v * v * v + 1.3 * v * v
            }
            Self::Pop => {
                let v = t - 1.0;
                1.0 + 3.4 * v * v * v + 2.4 * v * v
            }
            Self::Spring => {
                if t >= 1.0 {
                    return 1.0;
                }
                1.0 - (-6.0 * t).exp() * ((7.0 * t).cos() + 0.86 * (7.0 * t).sin()) * (1.0 - t * t * t * t)
            }
        }
    }
}

/// Move to `to` in `duration` ms with `ease`, then hold `hold` ms.
#[derive(Clone, Debug, PartialEq)]
pub struct SQMascotStep {
    pub to: SQMascotPose,
    pub duration: f64,
    pub ease: SQMascotEase,
    pub hold: f64,
}

/// Named animations. The raw value is the key in `pip-anim.json`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum SQMascotAnim {
    Wink,
    Peek,
    Sleep,
    Search,
    Work,
    Cheer,
    Oops,
    Think,
    Proud,
    Sad,
    /// Reactions (parts, played on demand): M3 wake and hop away, R2 one eye opens and falls shut again.
    DragWake,
    DragAway,
    HoverOpen,
    HoverClose,
}

impl SQMascotAnim {
    pub const ALL: [SQMascotAnim; 14] = [
        Self::Wink,
        Self::Peek,
        Self::Sleep,
        Self::Search,
        Self::Work,
        Self::Cheer,
        Self::Oops,
        Self::Think,
        Self::Proud,
        Self::Sad,
        Self::DragWake,
        Self::DragAway,
        Self::HoverOpen,
        Self::HoverClose,
    ];

    /// The key in `pip-anim.json`.
    pub fn raw_value(self) -> &'static str {
        match self {
            Self::Wink => "wink",
            Self::Peek => "peek",
            Self::Sleep => "schlaf",
            Self::Search => "suche",
            Self::Work => "arbeit",
            Self::Cheer => "jubel",
            Self::Oops => "ups",
            Self::Think => "denkt",
            Self::Proud => "stolz",
            Self::Sad => "still-traurig",
            Self::DragWake => "m3wach",
            Self::DragAway => "m3weg",
            Self::HoverOpen => "m5blinzel",
            Self::HoverClose => "m5wieder",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SQMascotKind {
    Loop,
    Rest,
    Once,
    Part,
}

impl SQMascotKind {
    fn from_raw(raw: &str) -> Option<SQMascotKind> {
        Some(match raw {
            "loop" => Self::Loop,
            "rest" => Self::Rest,
            "once" => Self::Once,
            "part" => Self::Part,
            _ => return None,
        })
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct SQMascotAnimation {
    pub kind: SQMascotKind,
    /// Tight art: viewBox 125 268 774 774, no hand, magnifier, badge or floating marks (also used for <= 24 pt).
    pub tight: bool,
    pub view_box: CGRect,
    /// Art-space y below which nothing is drawn (peek behind a card edge).
    pub clip_bottom: Option<f64>,
    /// Strength of idle breathing and sway (0 asleep).
    pub breath: f64,
    /// Seconds of rest between repeats (`rest` kind only).
    pub pause: Option<RangeInclusive<f64>>,
    pub rest: SQMascotPose,
    pub still: SQMascotPose,
    pub from: Option<SQMascotPose>,
    pub steps: Vec<SQMascotStep>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct SQMascotIdleConfig {
    pub breath_height: f64,
    pub breath_width: f64,
    pub breath_period: f64,
    pub sway_degrees: f64,
    pub sway_period: f64,
    pub blink_every: RangeInclusive<f64>,
    pub blink_close: f64,
    pub blink_shut: f64,
    pub blink_open: f64,
    pub blink_gap: f64,
    /// Every n-th blink is a double blink.
    pub double_every: i64,
    /// Breathing and sway fade in over this long after an animation.
    pub fade_in: f64,
    /// Walk back to the rest pose before idling.
    pub settle: f64,
}

impl Default for SQMascotIdleConfig {
    fn default() -> SQMascotIdleConfig {
        SQMascotIdleConfig {
            breath_height: 0.012,
            breath_width: 0.006,
            breath_period: 3800.0,
            sway_degrees: 0.9,
            sway_period: 7600.0,
            blink_every: 2600.0..=6400.0,
            blink_close: 110.0,
            blink_shut: 50.0,
            blink_open: 150.0,
            blink_gap: 130.0,
            double_every: 5,
            fade_in: 900.0,
            settle: 420.0,
        }
    }
}

/// M3: eyes, face and tilt follow a point (the file being dragged). Per step of `rx` points sideways (at most 3 steps)
/// and `ry` points up or down (at most 1 step) the channels in `x` and `y` move by their value; `lag` is the low-pass
/// time constant in ms.
#[derive(Clone, Debug, PartialEq)]
pub struct SQMascotLook {
    pub base: SQMascotPose,
    pub x: HashMap<SQMascotKey, f64>,
    pub y: HashMap<SQMascotKey, f64>,
    pub rx: f64,
    pub ry: f64,
    pub lag: f64,
}

impl SQMascotLook {
    pub const MAX_X: f64 = 3.0;
    pub const MAX_Y: f64 = 1.0;

    /// A look with the default reach (55 / 42 points) and lag (130 ms).
    pub fn new(base: SQMascotPose, x: HashMap<SQMascotKey, f64>, y: HashMap<SQMascotKey, f64>) -> SQMascotLook {
        SQMascotLook { base, x, y, rx: 55.0, ry: 42.0, lag: 130.0 }
    }

    /// Steps (sideways, vertical) for an offset of the point from Pip's center, in points.
    pub fn target(&self, dx: f64, dy: f64) -> (f64, f64) {
        ((dx / self.rx).clamp(-Self::MAX_X, Self::MAX_X), (dy / self.ry).clamp(-Self::MAX_Y, Self::MAX_Y))
    }

    /// The pose at `gx` sideways and `gy` vertical steps.
    pub fn pose(&self, gx: f64, gy: f64) -> SQMascotPose {
        let mut p = self.base.clone();
        for (k, v) in &self.x {
            p[*k] += v * gx;
        }
        for (k, v) in &self.y {
            p[*k] += v * gy;
        }
        p
    }
}

/// The low-pass state of a follow in progress.
#[derive(Clone, Debug, PartialEq)]
pub struct SQMascotFollower {
    pub look: SQMascotLook,
    gx: f64,
    gy: f64,
}

impl SQMascotFollower {
    pub fn new(look: SQMascotLook) -> SQMascotFollower {
        SQMascotFollower { look, gx: 0.0, gy: 0.0 }
    }

    pub fn gx(&self) -> f64 {
        self.gx
    }

    pub fn gy(&self) -> f64 {
        self.gy
    }

    /// Moves toward the target for the offset (`dx`, `dy` in points from the center) by `dt` ms; returns the pose.
    pub fn advance(&mut self, dt: f64, dx: f64, dy: f64) -> SQMascotPose {
        let t = self.look.target(dx, dy);
        let k = 1.0 - (-dt / self.look.lag).exp();
        self.gx += (t.0 - self.gx) * k;
        self.gy += (t.1 - self.gy) * k;
        self.look.pose(self.gx, self.gy)
    }
}

/// The JSON could not be read.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SQMascotParseError {
    pub detail: String,
}

impl fmt::Display for SQMascotParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "pip-anim.json: {}", self.detail)
    }
}

impl std::error::Error for SQMascotParseError {}

fn parse_error(detail: &str) -> SQMascotParseError {
    SQMascotParseError { detail: detail.to_string() }
}

#[derive(Clone, Debug)]
pub struct SQMascotLibrary {
    pub idle: SQMascotIdleConfig,
    pub look: SQMascotLook,
    pub default_pose: SQMascotPose,
    /// The `look` base pose (amazed face).
    pub amazed: SQMascotPose,
    anims: HashMap<String, SQMascotAnimation>,
}

impl SQMascotLibrary {
    /// The design animation of `a`; every `SQMascotAnim` is in `pip-anim.json`.
    pub fn animation(&self, a: SQMascotAnim) -> &SQMascotAnimation {
        &self.anims[a.raw_value()]
    }

    /// The library of the bundled `pip-anim.json`.
    pub fn shared() -> &'static SQMascotLibrary {
        static SHARED: OnceLock<SQMascotLibrary> = OnceLock::new();
        SHARED.get_or_init(|| match SQMascotLibrary::from_json(include_str!("../resources/Mascot/pip-anim.json")) {
            Ok(lib) => lib,
            Err(e) => panic!("pip-anim.json is broken: {e}"),
        })
    }

    pub fn from_json(json: &str) -> Result<SQMascotLibrary, SQMascotParseError> {
        let root: Value = serde_json::from_str(json).map_err(|_| parse_error("root"))?;
        let (Some(def), Some(raw_anims)) =
            (root.get("default").and_then(Value::as_object), root.get("anims").and_then(Value::as_object))
        else {
            return Err(parse_error("root"));
        };
        let base = Self::pose(def, None)?;
        let mut idle = SQMascotIdleConfig::default();
        if let Some(i) = root.get("idle").and_then(Value::as_object) {
            if let Some(b) = i.get("breath").and_then(Value::as_object) {
                idle.breath_height = number(b, "sy").unwrap_or(idle.breath_height);
                idle.breath_width = number(b, "sx").unwrap_or(idle.breath_width);
                idle.breath_period = number(b, "period").unwrap_or(idle.breath_period);
            }
            if let Some(s) = i.get("sway").and_then(Value::as_object) {
                idle.sway_degrees = number(s, "rot").unwrap_or(idle.sway_degrees);
                idle.sway_period = number(s, "period").unwrap_or(idle.sway_period);
            }
            if let Some(b) = i.get("blink").and_then(Value::as_object) {
                if let Some(e) = pair(b.get("every")) {
                    idle.blink_every = e;
                }
                idle.blink_close = number(b, "close").unwrap_or(idle.blink_close);
                idle.blink_shut = number(b, "shut").unwrap_or(idle.blink_shut);
                idle.blink_open = number(b, "open").unwrap_or(idle.blink_open);
            }
        }
        let look_root = root.get("look").and_then(Value::as_object);
        let amazed = match look_root.and_then(|l| l.get("base")).and_then(Value::as_object) {
            Some(look_base) => Self::pose(look_base, Some(&base))?,
            None => base.clone(),
        };
        let deltas = |any: Option<&Value>| -> HashMap<SQMascotKey, f64> {
            let mut out = HashMap::new();
            for (name, v) in any.and_then(Value::as_object).into_iter().flatten() {
                if let (Some(k), Some(d)) = (SQMascotKey::ALL.iter().find(|k| k.json_key() == name), v.as_f64()) {
                    out.insert(*k, d);
                }
            }
            out
        };
        let mut look = SQMascotLook::new(
            amazed.clone(),
            deltas(look_root.and_then(|l| l.get("x"))),
            deltas(look_root.and_then(|l| l.get("y"))),
        );
        look.rx = look_root.and_then(|l| number(l, "rx")).unwrap_or(look.rx);
        look.ry = look_root.and_then(|l| number(l, "ry")).unwrap_or(look.ry);
        look.lag = look_root.and_then(|l| number(l, "lag")).unwrap_or(look.lag);
        let mut out: HashMap<String, SQMascotAnimation> = HashMap::new();
        for (name, any) in raw_anims {
            let Some(a) = any.as_object() else { continue };
            let Some(kind) = a.get("kind").and_then(Value::as_str).and_then(SQMascotKind::from_raw) else { continue };
            let Some(vb) = a.get("vb").and_then(Value::as_str) else { continue };
            let view: Vec<f64> = vb.split(' ').filter(|s| !s.is_empty()).filter_map(|s| s.parse().ok()).collect();
            if view.len() != 4 {
                return Err(parse_error(&format!("vb {name}")));
            }
            let mut steps = Vec::new();
            for s in a.get("steps").and_then(Value::as_array).into_iter().flatten() {
                let Some(s) = s.as_object() else { continue };
                let ease = s.get("e").and_then(Value::as_str).unwrap_or("io");
                let empty = Map::new();
                steps.push(SQMascotStep {
                    to: Self::pose(s.get("p").and_then(Value::as_object).unwrap_or(&empty), Some(&base))?,
                    duration: number(s, "d").unwrap_or(0.0).max(1.0),
                    ease: SQMascotEase::from_raw(ease).unwrap_or(SQMascotEase::Io),
                    hold: number(s, "h").unwrap_or(0.0),
                });
            }
            let empty = Map::new();
            let rest = Self::pose(a.get("rest").and_then(Value::as_object).unwrap_or(&empty), Some(&base))?;
            let clip_bottom = match a.get("clip").and_then(Value::as_str) {
                Some("pipfloor2") => Some(833.0),
                Some("pipfloor") => Some(1102.0),
                _ => None,
            };
            let still_dict = a
                .get("still")
                .and_then(Value::as_object)
                .or_else(|| a.get("rest").and_then(Value::as_object))
                .unwrap_or(&empty);
            let from = match a.get("from").and_then(Value::as_object) {
                Some(f) => Some(Self::pose(f, Some(&base))?),
                None => None,
            };
            out.insert(
                name.clone(),
                SQMascotAnimation {
                    kind,
                    tight: a.get("tight").and_then(Value::as_bool).unwrap_or(false),
                    view_box: CGRect::new(view[0], view[1], view[2], view[3]),
                    clip_bottom,
                    breath: number(a, "breath").unwrap_or(1.0),
                    pause: pair(a.get("pause")),
                    rest,
                    still: Self::pose(still_dict, Some(&base))?,
                    from,
                    steps,
                },
            );
        }
        Ok(SQMascotLibrary { idle, look, default_pose: base, amazed, anims: out })
    }

    fn shape(any: Option<&Value>) -> Option<SQMascotShape> {
        let arr = any?.as_array()?;
        let kind = arr.first()?.as_str()?;
        Some(SQMascotShape::new(kind, arr.iter().skip(1).filter_map(Value::as_f64).collect()))
    }

    /// Builds a pose from a (partial) JSON dict on top of `base` (None: the dict is the complete default).
    fn pose(d: &Map<String, Value>, base: Option<&SQMascotPose>) -> Result<SQMascotPose, SQMascotParseError> {
        let mut p = match base {
            Some(b) => b.clone(),
            None => {
                let (Some(l), Some(r), Some(m)) =
                    (Self::shape(d.get("eL")), Self::shape(d.get("eR")), Self::shape(d.get("m")))
                else {
                    return Err(parse_error("default shapes"));
                };
                SQMascotPose::new(l, r, m)
            }
        };
        for k in SQMascotKey::ALL {
            if let Some(v) = number(d, k.json_key()) {
                p[k] = v;
            }
        }
        if base.is_some() {
            if let Some(s) = Self::shape(d.get("eL")) {
                p.e_l = s;
            }
            if let Some(s) = Self::shape(d.get("eR")) {
                p.e_r = s;
            }
            if let Some(s) = Self::shape(d.get("m")) {
                p.m = s;
            }
        }
        Ok(p)
    }
}

fn number(d: &Map<String, Value>, key: &str) -> Option<f64> {
    d.get(key).and_then(Value::as_f64)
}

/// A two-number JSON array as a range.
fn pair(any: Option<&Value>) -> Option<RangeInclusive<f64>> {
    let a = any?.as_array()?;
    if a.len() != 2 {
        return None;
    }
    Some(a[0].as_f64()?..=a[1].as_f64()?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keys_are_indexed_in_declaration_order_with_their_json_names() {
        assert_eq!(SQMascotKey::ALL.len(), 44);
        assert!(SQMascotKey::ALL.iter().enumerate().all(|(i, k)| k.raw_value() == i));
        assert_eq!(SQMascotKey::Tx.json_key(), "tx");
        assert_eq!(SQMascotKey::HL.json_key(), "hL");
        assert_eq!(SQMascotKey::BaR.json_key(), "baR");
        assert_eq!(SQMascotKey::Hide.raw_value(), 35);
    }

    #[test]
    fn ease_endpoints_and_midpoints() {
        for e in [
            SQMascotEase::Lin,
            SQMascotEase::Io,
            SQMascotEase::In,
            SQMascotEase::Out,
            SQMascotEase::Back,
            SQMascotEase::Pop,
        ] {
            assert!(e.value(0.0).abs() < 1e-12, "{e:?}");
            assert!((e.value(1.0) - 1.0).abs() < 1e-12, "{e:?}");
        }
        assert!((SQMascotEase::Spring.value(0.0)).abs() < 1e-12);
        assert_eq!(SQMascotEase::Spring.value(1.0), 1.0);
        assert_eq!(SQMascotEase::Io.value(0.5), 0.5);
        assert_eq!(SQMascotEase::In.value(0.5), 0.25);
        assert_eq!(SQMascotEase::Out.value(0.5), 0.75);
        assert_eq!(SQMascotEase::from_raw("pop"), Some(SQMascotEase::Pop));
        assert_eq!(SQMascotEase::from_raw("nope"), None);
    }

    #[test]
    fn the_bundled_library_has_every_named_animation() {
        let lib = SQMascotLibrary::shared();
        for a in SQMascotAnim::ALL {
            let anim = lib.animation(a);
            assert_eq!(anim.rest.n.len(), SQMascotKey::ALL.len(), "{a:?}");
        }
        let wink = lib.animation(SQMascotAnim::Wink);
        assert_eq!(wink.kind, SQMascotKind::Rest);
        assert_eq!(wink.view_box, CGRect::new(47.0, 172.0, 930.0, 930.0));
        assert_eq!(wink.pause, Some(5.0..=9.0));
        assert_eq!(wink.steps.len(), 10);
        assert_eq!(lib.idle.breath_period, 3800.0);
        assert_eq!(lib.idle.blink_every, 2600.0..=6400.0);
        assert!(lib.look.lag > 0.0 && lib.look.rx > 0.0);
    }

    #[test]
    fn mix_blends_numbers_and_swaps_unlike_shapes_when_squeezed() {
        let lib = SQMascotLibrary::shared();
        let mut a = lib.default_pose.clone();
        let mut b = lib.default_pose.clone();
        a[SQMascotKey::Tx] = 10.0;
        b[SQMascotKey::Tx] = 30.0;
        b.e_l = SQMascotShape::new("other", vec![1.0]);
        let mid = SQMascotPose::mix(&a, &b, 0.25);
        assert_eq!(mid[SQMascotKey::Tx], 15.0);
        assert_eq!(mid.e_l, a.e_l);
        assert_eq!(mid.k_eye_l, 0.5);
        assert_eq!(SQMascotPose::mix(&a, &b, 0.75).e_l, b.e_l);
        assert_eq!(SQMascotPose::mix(&a, &b, 1.0).k_eye_l, 1.0);
        assert_eq!(mid.blink, 1.0);
    }

    #[test]
    fn look_target_is_clamped_and_follower_moves_toward_it() {
        let lib = SQMascotLibrary::shared();
        let (gx, gy) = lib.look.target(1000.0, -1000.0);
        assert_eq!((gx, gy), (3.0, -1.0));
        let mut f = SQMascotFollower::new(lib.look.clone());
        let p = f.advance(1.0e9, 55.0, 0.0);
        assert!((f.gx() - 1.0).abs() < 1e-9 && f.gy().abs() < 1e-12);
        assert_eq!(p, lib.look.pose(f.gx(), f.gy()));
    }

    #[test]
    fn broken_json_reports_where() {
        assert_eq!(SQMascotLibrary::from_json("[]").map(|_| ()), Err(parse_error("root")));
        assert_eq!(
            SQMascotLibrary::from_json(r#"{"default":{},"anims":{}}"#).map(|_| ()),
            Err(parse_error("default shapes"))
        );
    }
}
