//! The Create tool's items on the Program monitor (Swift `MonitorHost+PictureTools.swift` `createItem`): a dragged shape or
//! stroke becomes a layer of the selected or targeted Graphic, else a new Graphic clip at the playhead.

use sq_core_model::{ClipTransform, EffectColor, GraphicsLayer, ShapeKind};
use sq_core_time::{IdSource, Time, Vec2};
use sq_draw_monitor::monitor_panel::PanelEvent;
use sq_editor_session::EditorSession;
use sq_inspector_ui::graphics::canvas_mapping::{GraphicsCanvasMapping, created_shape, menu_shape_drag};
use sq_inspector_ui::graphics::editor::GraphicsEditor;
use std::collections::BTreeSet;

/// The stroke the Create tool's Draw makes: white, 8 px (`GraphicsEditor.strokeLayer` defaults).
pub(super) const STROKE_WIDTH: f64 = 8.0;

/// Runs a Create tool event; `None` when `event` is not one. `Some(Err(line))`: the status line to show.
/// `seconds`: the stored New Text Length for a new Graphic clip.
pub fn run_create_event(
    session: &mut EditorSession,
    editor: Option<&mut GraphicsEditor>,
    seconds: i64,
    event: &PanelEvent,
) -> Option<Result<(), String>> {
    match event {
        PanelEvent::CreateShape(kind, a, b) => Some(create_shape(session, editor, seconds, *kind, *a, *b)),
        PanelEvent::CreateStroke(points, tolerance) => {
            Some(create_item(session, editor, seconds, "Draw", |ids, map, _| {
                let scale = map.transform.scale.x.abs().max(1e-6);
                let pts: Vec<Vec2> = points.iter().map(|p| map.canvas_point_from_sequence(*p)).collect();
                GraphicsEditor::stroke_layer(ids, &pts, false, EffectColor::WHITE, STROKE_WIDTH, tolerance / scale)
            }))
        }
        _ => None,
    }
}

/// A shape from `a` to `b` (sequence px from the picture center).
pub fn create_shape(
    session: &mut EditorSession,
    editor: Option<&mut GraphicsEditor>,
    seconds: i64,
    kind: ShapeKind,
    a: Vec2,
    b: Vec2,
) -> Result<(), String> {
    create_item(session, editor, seconds, &format!("Add {}", kind.title()), |ids, map, canvas| {
        Some(created_shape(ids, kind, a, b, map, canvas))
    })
}

/// Sequence > New Shape: the centered default drag through the same path.
pub fn create_shape_at_center(
    session: &mut EditorSession,
    editor: Option<&mut GraphicsEditor>,
    seconds: i64,
    kind: ShapeKind,
) -> Result<(), String> {
    create_item(session, editor, seconds, &format!("Add {}", kind.title()), |ids, map, canvas| {
        let (a, b) = menu_shape_drag(kind, canvas);
        Some(created_shape(ids, kind, a, b, map, canvas))
    })
}

/// Adds the item `make` builds as one undo step: into the selected or targeted Graphic, else a new Graphic clip at the
/// playhead on the first free video track (never over footage).
fn create_item(
    session: &mut EditorSession,
    mut editor: Option<&mut GraphicsEditor>,
    seconds: i64,
    name: &str,
    make: impl FnOnce(&mut dyn IdSource, &GraphicsCanvasMapping, Vec2) -> Option<GraphicsLayer>,
) -> Result<(), String> {
    session.stop_playback();
    let mut make = Some(make);
    if let Some(g) = editor.as_deref_mut()
        && g.add_created_item(session, name, |ids, m, c| make.take().and_then(|f| f(ids, m, c)))
    {
        session.seek(session.playhead());
        return Ok(());
    }
    let Some(make) = make else { return Ok(()) };
    let Some(timeline) = session.active_timeline() else { return Ok(()) };
    let canvas = Vec2::new(timeline.format.width as f64, timeline.format.height as f64);
    let canvas = editor.as_deref().map_or(canvas, |g| g.canvas(session));
    let Some(layer) = make(&mut *session.ids, &GraphicsCanvasMapping::new(ClipTransform::IDENTITY), canvas) else {
        return Ok(());
    };
    let id = layer.id;
    if session.add_graphics_clip(None, None, Time::new(seconds, 1), vec![layer], true).is_none() {
        return Err(session.last_error().unwrap_or("Could not add the graphic.").to_string());
    }
    session.seek(session.playhead());
    if let Some(g) = editor {
        g.sync(session);
        g.select(session, BTreeSet::from([id]));
    }
    Ok(())
}
