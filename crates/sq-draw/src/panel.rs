//! The shared panel protocol (design `session-ui-design.md` section 3): every drawn panel lays itself out, draws into a
//! [`Canvas`], handles input and, while assistive tech is active, pushes accessibility nodes.

use crate::canvas::Canvas;
use crate::input::InputEvent;
use crate::text_measure::TextMeasure;
use crate::theme::DrawTheme;
use crate::ui_cx::UiCx;
pub use accesskit::{Node, NodeId, Role};
use sq_uikit::controls_grid::CGRect;

/// Collects accessibility nodes for one frame. Panels push nodes only while [`A11y::is_active`]; node ids are
/// `hash(panel id, role, key)`, so the same control keeps its id across frames and actions route back by id.
#[derive(Debug, Default)]
pub struct A11y {
    active: bool,
    nodes: Vec<(NodeId, Node)>,
}

impl A11y {
    /// A collector; `active` is whether assistive tech listens.
    pub fn new(active: bool) -> A11y {
        A11y { active, nodes: Vec::new() }
    }
    /// Whether assistive tech is active (panels skip the work when not).
    pub fn is_active(&self) -> bool {
        self.active
    }
    /// The stable id of the control `key` of `panel` with `role` (FNV-1a over the three parts).
    pub fn node_id(panel: &str, role: Role, key: &str) -> NodeId {
        let mut h: u64 = 0xcbf2_9ce4_8422_2325;
        for part in [panel, &format!("{role:?}"), key] {
            for b in part.bytes().chain([0xFF]) {
                h = (h ^ b as u64).wrapping_mul(0x0100_0000_01b3);
            }
        }
        NodeId(h)
    }
    /// Adds a node and returns its id (nothing is stored while inactive).
    pub fn push(&mut self, panel: &str, role: Role, key: &str, node: Node) -> NodeId {
        let id = Self::node_id(panel, role, key);
        if self.active {
            self.nodes.push((id, node));
        }
        id
    }
    /// The nodes pushed this frame.
    pub fn nodes(&self) -> &[(NodeId, Node)] {
        &self.nodes
    }
    /// Takes the nodes, leaving the collector empty.
    pub fn take(&mut self) -> Vec<(NodeId, Node)> {
        std::mem::take(&mut self.nodes)
    }
}

/// A drawn panel.
pub trait Panel {
    /// Places the panel in `frame` (points) and measures what it needs.
    fn layout(&mut self, frame: CGRect, m: &TextMeasure);
    /// Draws the panel.
    fn draw(&mut self, c: &mut Canvas, t: &DrawTheme);
    /// Handles one input event; true when the panel took it.
    fn handle(&mut self, e: &InputEvent, cx: &mut UiCx) -> bool;
    /// Pushes accessibility nodes (only while `a11y.is_active()`).
    fn a11y(&self, _a11y: &mut A11y) {}
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Block {
        frame: CGRect,
        clicks: u32,
    }

    impl Panel for Block {
        fn layout(&mut self, frame: CGRect, _m: &TextMeasure) {
            self.frame = frame;
        }
        fn draw(&mut self, c: &mut Canvas, t: &DrawTheme) {
            c.fill(self.frame, t.panel());
        }
        fn handle(&mut self, e: &InputEvent, _cx: &mut UiCx) -> bool {
            match *e {
                InputEvent::MouseDown { x, y, .. }
                    if self.frame.contains(sq_uikit::controls_grid::CGPoint { x: x as f64, y: y as f64 }) =>
                {
                    self.clicks += 1;
                    true
                }
                _ => false,
            }
        }
        fn a11y(&self, a: &mut A11y) {
            let mut n = Node::new(Role::Button);
            n.set_label("Block");
            a.push("block", Role::Button, "main", n);
        }
    }

    #[test]
    fn a_panel_lays_out_draws_and_handles() {
        let mut p = Block { frame: CGRect::default(), clicks: 0 };
        p.layout(CGRect::new(10.0, 10.0, 20.0, 20.0), &TextMeasure::new(None, 1.0));
        let mut c = Canvas::with_size(100.0, 100.0, None, 1.0);
        p.draw(&mut c, &DrawTheme::default());
        assert_eq!(c.list.quads().len(), 1);
        let mut cx = UiCx::new();
        let down = |x| InputEvent::MouseDown { x, y: 15.0, modifiers: Default::default() };
        assert!(p.handle(&down(15.0), &mut cx) && !p.handle(&down(50.0), &mut cx));
        assert_eq!(p.clicks, 1);
    }

    #[test]
    fn nodes_are_pushed_only_while_assistive_tech_is_active() {
        let p = Block { frame: CGRect::default(), clicks: 0 };
        let mut off = A11y::new(false);
        p.a11y(&mut off);
        assert!(off.nodes().is_empty());
        let mut on = A11y::new(true);
        p.a11y(&mut on);
        assert_eq!(on.nodes().len(), 1);
        assert_eq!(on.nodes()[0].0, A11y::node_id("block", Role::Button, "main"));
        assert_eq!(on.take().len(), 1);
        assert!(on.nodes().is_empty());
    }

    #[test]
    fn ids_depend_on_panel_role_and_key() {
        let a = A11y::node_id("timeline", Role::Button, "play");
        assert_eq!(a, A11y::node_id("timeline", Role::Button, "play"));
        assert_ne!(a, A11y::node_id("monitor", Role::Button, "play"));
        assert_ne!(a, A11y::node_id("timeline", Role::Slider, "play"));
        assert_ne!(a, A11y::node_id("timeline", Role::Button, "pause"));
        assert_ne!(A11y::node_id("ab", Role::Button, "c"), A11y::node_id("a", Role::Button, "bc"));
    }
}
