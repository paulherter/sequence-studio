// Swift: AutoTone.swift
//! Basic Correction "Auto Tone" on a frame as the Program monitor shows it (working-linear Rec.709). Tone (Exposure,
//! Contrast, Whites, Blacks) comes from `sq_core_color::auto_tone_solver`; a conservative white balance from its near-gray
//! sample and [`WhiteBalanceSolver`]. Both are absolute or stop at a dead band, so pressing twice changes nothing more.

use sq_core_color::auto_tone_solver;
use sq_core_model::BasicCorrection;

use super::gamut::Gamut;
use super::stages::PreparedBasic;
use super::transfer::bt709_oetf;
use super::vec::Vec3;
use super::white_balance::WhiteBalanceSolver;

const LUMA: Vec3 = Vec3::new(0.2126, 0.7152, 0.0722);

/// Auto Tone entry points.
pub struct AutoTone;

impl AutoTone {
    /// New Basic Correction from working-linear pixels, or `None` when there is nothing to do.
    pub fn solve(linear: &[Vec3], current: &BasicCorrection) -> Option<BasicCorrection> {
        let luma: Vec<f32> = linear.iter().map(|p| bt709_oetf(LUMA.dot(*p).clamp(0.0, 4.0))).collect();
        // White balance first: its matrix acts on linear light before Exposure and moves gray luminance, so the tone solve
        // sees that change as a linear gain (measured on the gray it neutralises).
        let (mut temperature, mut tint) = (current.temperature, current.tint);
        let mut gain = 1.0f32;
        let raw: Vec<[f32; 3]> = linear.iter().map(|p| (*p).into()).collect();
        if let Some(grey) = auto_tone_solver::neutral_sample(&raw).map(Vec3::from)
            && let Some(wb) = WhiteBalanceSolver::solve(grey, current.temperature, current.tint)
        {
            temperature = wb.temperature;
            tint = wb.tint;
            let next = BasicCorrection { temperature, tint, ..*current };
            let change = PreparedBasic::new(&next, Gamut::rec709())
                .wb
                .mul_mat(&PreparedBasic::new(current, Gamut::rec709()).wb.inverse());
            let before = LUMA.dot(grey);
            if before > 1e-6 {
                gain = LUMA.dot(change.mul_vec(grey)) / before;
            }
        }
        let mut b = auto_tone_solver::solve_tone(&luma, current, gain).unwrap_or(*current);
        b.temperature = temperature;
        b.tint = tint;
        if b == *current { None } else { Some(b) }
    }

    /// Tone only, from display-encoded luma.
    pub fn solve_luma(luma: &[f32], current: &BasicCorrection) -> Option<BasicCorrection> {
        auto_tone_solver::solve_tone(luma, current, 1.0)
    }
}
