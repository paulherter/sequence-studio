// Swift: Stabilization.swift (Registration.motion(visionWarp:), matched, homography, translationalMotion)
//! Apple Vision registration of two gray frames, the Stabilizer's last fallback on the Mac (Swift
//! `Registration.matched`: homography first, translation second). The maths that turns Vision's warp into a
//! [`CameraMotion`] is portable and tested everywhere; the Vision calls exist on macOS only, every other system answers
//! "no match" so the portable analysis stays unchanged there.

use sq_analysis::registration_math::Registration;
use sq_core_masks::stabilizer::CameraMotion;
use sq_core_time::Vec2;

#[cfg(target_os = "macos")]
mod mac;

/// What Vision found between two frames, in Vision's own conventions (pixels, origin bottom left, y up; the matrix maps
/// the targeted, current image into the handler's, previous one).
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum VisionWarp {
    /// `VNImageHomographicAlignmentObservation.warpTransform`, column major: `columns[c][r]`.
    Homography { columns: [[f32; 3]; 3] },
    /// `VNImageTranslationAlignmentObservation.alignmentTransform` (a CGAffineTransform).
    Translation { a: f64, b: f64, c: f64, d: f64, tx: f64, ty: f64 },
}

/// A frame as 8-bit gray, rows top to bottom.
#[derive(Clone, Copy, Debug)]
pub struct Gray8<'a> {
    pub width: usize,
    pub height: usize,
    pub pixels: &'a [u8],
}

/// The content motion previous -> current frame from a Vision warp (Swift `Registration.motion(visionWarp:)`): points
/// of the current frame are mapped into the previous one and a similarity is fitted previous -> current. `None` when
/// the warp sends a point to infinity or the fit fails.
pub fn motion_from_warp(warp: &VisionWarp, width: usize, height: usize) -> Option<CameraMotion> {
    let m = columns_of(warp);
    let (w, h) = (width as f64, height as f64);
    let vision = |p: Vec2| Vec2::new(p.x + w / 2.0, h / 2.0 - p.y);
    let ours = |v: Vec2| Vec2::new(v.x - w / 2.0, h / 2.0 - v.y);
    let cur = [
        Vec2::new(-w / 4.0, -h / 4.0),
        Vec2::new(w / 4.0, -h / 4.0),
        Vec2::new(w / 4.0, h / 4.0),
        Vec2::new(-w / 4.0, h / 4.0),
        Vec2::ZERO,
    ];
    let mut prev = Vec::with_capacity(cur.len());
    for p in cur {
        let v = vision(p);
        let x = m[0][0] * v.x + m[1][0] * v.y + m[2][0];
        let y = m[0][1] * v.x + m[1][1] * v.y + m[2][1];
        let z = m[0][2] * v.x + m[1][2] * v.y + m[2][2];
        if z.abs() <= 1e-9 {
            return None;
        }
        prev.push(ours(Vec2::new(x / z, y / z)));
    }
    Registration::fit_similarity(&prev, &cur)
}

/// The warp as a column-major 3x3 (a translation is the affine matrix with a last row 0 0 1).
fn columns_of(warp: &VisionWarp) -> [[f64; 3]; 3] {
    match *warp {
        VisionWarp::Homography { columns } => columns.map(|c| c.map(f64::from)),
        VisionWarp::Translation { a, b, c, d, tx, ty } => [[a, b, 0.0], [c, d, 0.0], [tx, ty, 1.0]],
    }
}

/// Vision's registration of `current` against `previous` (same size), reduced to a plausible camera motion: the
/// homography first, the translation second, `None` when neither matches or the motion is not one a camera makes.
pub fn registered_motion(previous: Gray8<'_>, current: Gray8<'_>) -> Option<CameraMotion> {
    let (w, h) = (current.width, current.height);
    let usable = |warp: Option<VisionWarp>| {
        let m = motion_from_warp(&warp?, w, h)?;
        Registration::plausible(&m, w as i64, h as i64).then_some(m)
    };
    usable(register(previous, current, Kind::Homographic))
        .or_else(|| usable(register(previous, current, Kind::Translational)))
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) enum Kind {
    Homographic,
    Translational,
}

/// Runs one Vision request; `None` off the Mac or when Vision finds nothing.
pub fn register_with(previous: Gray8<'_>, current: Gray8<'_>, homographic: bool) -> Option<VisionWarp> {
    register(previous, current, if homographic { Kind::Homographic } else { Kind::Translational })
}

#[cfg(target_os = "macos")]
fn register(previous: Gray8<'_>, current: Gray8<'_>, kind: Kind) -> Option<VisionWarp> {
    mac::register(previous, current, kind)
}

#[cfg(not(target_os = "macos"))]
fn register(_previous: Gray8<'_>, _current: Gray8<'_>, _kind: Kind) -> Option<VisionWarp> {
    None
}

#[cfg(test)]
mod tests;
