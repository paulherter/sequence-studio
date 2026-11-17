use super::*;
use crate::draw_list::QuadKind;
use crate::motion;

fn h(c: Color) -> [u8; 4] {
    [c.r, c.g, c.b, c.a].map(|v| (v.clamp(0.0, 1.0) * 255.0).round() as u8)
}
fn row() -> CGRect {
    CGRect::new(0.0, 40.0, 300.0, 24.0)
}

#[test]
fn offline_pill_never_passes_the_name_column_at_any_width() {
    for end in (0..400).map(f64::from) {
        let l = offline_layout(30.0, end, 38.0, row(), true);
        if let Some(p) = l.pill {
            assert!(p.max_x() <= end, "pill {} past name end {end}", p.max_x());
            assert!(p.min_x() >= 30.0 + l.name_w, "pill overlaps the name at {end}");
        }
        assert!(30.0 + l.name_w <= end.max(30.0), "name past the cell at {end}");
    }
}

#[test]
fn narrow_cell_drops_the_pill_and_keeps_the_name() {
    let l = offline_layout(30.0, 100.0, 38.0, row(), true);
    assert_eq!(l.pill, None);
    assert_eq!(l.name_w, 66.0);
}

#[test]
fn wide_cell_truncates_the_name_before_the_pill() {
    let l = offline_layout(30.0, 330.0, 38.0, row(), true);
    let p = l.pill.expect("pill");
    assert_eq!(p.max_x(), 326.0);
    assert!(l.name_w < 300.0 - 4.0);
    let online = offline_layout(30.0, 330.0, 38.0, row(), false);
    assert_eq!((online.name_w, online.pill), (296.0, None));
}

#[test]
fn selected_row_uses_current_and_hover_row_uses_hover() {
    let t = DrawTheme::default();
    assert_eq!(row_pill_fill(true, 1.0, &t).map(h), Some(h(t.current())));
    assert_eq!(row_pill_fill(false, 1.0, &t).map(h), Some(h(t.hover())));
    assert_eq!(row_pill_fill(false, 0.0, &t), None);
    let half = row_pill_fill(false, 0.5, &t).unwrap();
    assert!((half.a - t.hover().a * 0.5).abs() < 1e-4);
}

#[test]
fn the_pill_is_painted_with_the_kit_fill() {
    motion::set_snap(true);
    let t = DrawTheme::default();
    let mut c = Canvas::with_size(300.0, 100.0, None, 1.0);
    motion::begin_frame(1.0);
    let p = c.stone_row_pill(row(), true, false, &t);
    assert_eq!(p, row().inset_by(4.0, 1.0));
    let n = c.list.quads().iter().filter(|q| q.kind == QuadKind::Shape && q.stroke == 0.0).count();
    assert_eq!(n, 1);
    motion::set_snap(false);
}
