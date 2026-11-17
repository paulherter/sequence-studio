// Swift: TimelinePanel+Header.swift (draw and hit part), TimelinePanel+MixRow.swift
//! Track headers, translated from `TrackHeaderView`: the target chip, the name, and the button slots (eye + lock on video,
//! M + S on audio; sync lock is menu-only), with the Mac's slot math and colors. The slot math is
//! [`TrackHeaderLayout`](crate::header::TrackHeaderLayout).

use crate::geom::RectExt as _;
use crate::header::TrackHeaderLayout;
use crate::lanes::MixRow;
use crate::panel::TimelinePanel;
use sq_core_model::{Track, TrackKind};
use sq_draw::{Canvas, Color, TextAlign};
use sq_editor_session::TrackToggle;
use sq_timeline_ui::{TimelineGeometry, TrackRow};
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::design_tokens::sq_tokens::{radius, type_size};
use sq_uikit::sqicon::SQIcon;

const ZERO: CGRect = CGRect { x: 0.0, y: 0.0, width: 0.0, height: 0.0 };

impl TimelinePanel {
    /// The padlock of a track head: closed while the track is locked, the open outline while it is not.
    pub(crate) fn lock_icon(locked: bool) -> SQIcon {
        if locked { SQIcon::TrackLock } else { SQIcon::TrackUnlock }
    }

    /// The header button under a panel point, as the toggle it fires.
    pub(crate) fn header_hit(&self, p: CGPoint) -> Option<(sq_core_time::Id, TrackToggle)> {
        if !(p.x >= TimelineGeometry::TOOL_COLUMN_WIDTH
            && p.x < TimelineGeometry::CONTENT_ORIGIN_X
            && p.y >= TimelineGeometry::RULER_HEIGHT)
        {
            return None;
        }
        let rows = self.rows();
        let row = rows.iter().find(|r| p.y >= r.y && p.y < r.max_y())?;
        let track = self.timeline.tracks.iter().find(|t| t.id == row.track)?;
        let local = CGPoint { x: p.x - TimelineGeometry::TOOL_COLUMN_WIDTH, y: p.y - row.y };
        let sl = TrackHeaderLayout::layout(
            track,
            TimelineGeometry::HEADER_WIDTH,
            row.height,
            self.hover_track == Some(track.id),
        );
        if self.target_chip_rect(row.height).has(local) {
            return Some((track.id, TrackToggle::Target));
        }
        let buttons: [(Option<CGRect>, TrackToggle); 5] = [
            (sl.eye, TrackToggle::Visible),
            (sl.mute, TrackToggle::Mute),
            (sl.solo, TrackToggle::Solo),
            (Some(sl.lock), TrackToggle::Lock),
            (Some(sl.sync), TrackToggle::SyncLock),
        ];
        for (r, t) in buttons {
            if let Some(r) = r
                && r != ZERO
                && r.has(local)
            {
                return Some((track.id, t));
            }
        }
        None
    }

    /// The Mac `TrackHeaderView` button tips.
    pub(crate) fn header_tip_at(&self, p: CGPoint) -> Option<&'static str> {
        let (_, toggle) = self.header_hit(p)?;
        Some(match toggle {
            TrackToggle::Target => "Target Track",
            TrackToggle::Visible => "Show or Hide Track",
            TrackToggle::Mute => "Mute Track",
            TrackToggle::Solo => "Solo Track",
            TrackToggle::Lock => "Lock Track",
            TrackToggle::SyncLock => "Sync Lock",
        })
    }

    pub(crate) fn draw_headers(&self, cv: &mut Canvas, rows: &[TrackRow]) {
        let col = CGRect::new(
            TimelineGeometry::TOOL_COLUMN_WIDTH,
            TimelineGeometry::RULER_HEIGHT,
            TimelineGeometry::HEADER_WIDTH,
            (self.size.height - TimelineGeometry::RULER_HEIGHT).max(0.0),
        );
        cv.fill(col, self.theme.panel());
        cv.fill(CGRect::new(col.max_x() - 1.0, col.min_y(), 1.0, col.height), self.theme.separator());
        cv.save_gstate();
        cv.clip_to(col);
        let split = Self::split_row(rows);
        for (i, row) in rows.iter().enumerate() {
            if !(row.max_y() > col.min_y() && row.y < col.max_y()) {
                continue;
            }
            let Some(track) = self.timeline.tracks.iter().find(|t| t.id == row.track) else { continue };
            cv.save_gstate();
            cv.translate_by(col.min_x(), row.y);
            self.draw_header(cv, track, &row.label, col.width, row.height, Some(i) == split);
            cv.restore_gstate();
        }
        self.draw_caption_headers(cv);
        self.draw_mix_row(cv);
        cv.restore_gstate();
    }

    /// `drawMixRow`: the header column's Mix row.
    fn draw_mix_row(&self, cv: &mut Canvas) {
        let rows = self.rows();
        let Some(r) = MixRow::rect(&rows, self.geometry.caption_height(&self.timeline), self.track_area_height())
        else {
            return;
        };
        let chip = TrackHeaderLayout::chip_rect(r.height);
        let chip =
            CGRect::new(chip.x + r.min_x() + self.patch_column_offset(), chip.y + r.min_y(), chip.width, chip.height);
        MixRow::draw(cv, &self.theme, r, chip, TrackHeaderLayout::BUTTON_GAP);
    }

    /// `TrackHeaderView.draw` plus its buttons (`TrackHeaderButton.draw`), in header-local points.
    pub(crate) fn draw_header(
        &self,
        cv: &mut Canvas,
        track: &Track,
        label: &str,
        width: f64,
        height: f64,
        is_split_row: bool,
    ) {
        let skin = self.skin();
        cv.fill(CGRect::new(0.0, 0.0, width, height), self.theme.panel());
        if is_split_row {
            cv.fill(CGRect::new(0.0, height - 2.0, width, 2.0), self.theme.panel_ground());
        } else {
            cv.fill(CGRect::new(0.0, height - 1.0, width, 1.0), self.theme.track_row_line());
        }
        cv.fill(CGRect::new(width - 1.0, 0.0, 1.0, height), self.theme.separator());

        self.draw_patch(cv, track.id, height);
        let chip = self.target_chip_rect(height);
        let rad = f64::from(radius::SMALL);
        cv.fill_rounded(chip, rad, if track.is_targeted { self.theme.current() } else { self.theme.raised() });
        if track.is_targeted {
            cv.stroke_rounded(chip.inset(0.5, 0.5), rad, 1.0, self.theme.label2());
        }
        cv.draw_text_in(
            label,
            chip,
            10.0,
            if track.is_targeted { self.theme.label() } else { self.theme.label2() },
            TextAlign::Center,
            0.0,
            0,
        );

        let hovered = self.hover_track == Some(track.id);
        let sl = TrackHeaderLayout::layout(track, width, height, hovered);
        let row_y = self.rows().iter().find(|r| r.track == track.id).map_or(0.0, |r| r.y);
        let local = if hovered {
            self.hover_point.map(|h| CGPoint { x: h.x - TimelineGeometry::TOOL_COLUMN_WIDTH, y: h.y - row_y })
        } else {
            None
        };
        let label2 = self.theme.label2();
        let button = |cv: &mut Canvas,
                      r: Option<CGRect>,
                      icon: Option<SQIcon>,
                      letter: Option<&str>,
                      filled: bool,
                      is_on: bool,
                      tint: Color| {
            let Some(r) = r else { return };
            if r == ZERO {
                return;
            }
            let hot = local.is_some_and(|l| r.has(l));
            if filled {
                cv.fill_rounded(
                    r,
                    rad,
                    if is_on {
                        self.theme.fill_pressed()
                    } else if hot {
                        self.theme.fill_hover()
                    } else {
                        self.theme.fill()
                    },
                );
            } else {
                cv.fill_rounded_if(r, rad, self.theme.fill_hover(), hot);
            }
            let color = if hot && !is_on && tint == label2 { self.theme.label() } else { tint };
            if let Some(letter) = letter {
                cv.draw_text_in(letter, r, 10.0, color, TextAlign::Center, 0.0, 0);
            } else if let Some(icon) = icon {
                let s = f64::from(type_size::BODY); // `Theme.Typography.symbolInline` (11 pt)
                cv.draw_icon(
                    icon,
                    CGPoint { x: (r.mid_x() - s / 2.0).round(), y: (r.mid_y() - s / 2.0).round() },
                    s,
                    color,
                    None,
                );
            }
        };
        if track.kind == TrackKind::Video {
            button(
                cv,
                sl.eye,
                Some(if track.is_visible { SQIcon::Eye } else { SQIcon::EyeOff }),
                None,
                false,
                false,
                if track.is_visible { label2 } else { skin.warning() },
            );
        } else {
            button(
                cv,
                sl.mute,
                None,
                Some("M"),
                true,
                track.is_muted,
                if track.is_muted { self.theme.accent() } else { label2 },
            );
            button(
                cv,
                sl.solo,
                None,
                Some("S"),
                true,
                track.is_solo,
                if track.is_solo { self.theme.yellow() } else { label2 },
            );
        }
        button(
            cv,
            Some(sl.lock),
            Some(Self::lock_icon(track.is_locked)),
            None,
            false,
            false,
            if track.is_locked { self.theme.accent() } else { label2 },
        );
        let name = TrackHeaderLayout::display_name(&track.name, label, track.kind);
        let name_x = chip.max_x() + TrackHeaderLayout::NAME_GAP;
        let w = sl.name_right - name_x;
        if name.is_empty() || w <= 12.0 {
            return;
        }
        let h = 14.0;
        cv.draw_text(
            &name,
            CGPoint { x: name_x, y: ((height - h) / 2.0).round() },
            f64::from(sq_uikit::redesign_tokens::type_size::BODY),
            label2,
            w,
            cv.medium(),
        );
    }
}
