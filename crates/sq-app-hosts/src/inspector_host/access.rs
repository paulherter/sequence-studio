//! Accessibility of the inspector: every scalar Effect Controls row (Opacity, Scale, Volume, ..) is a slider node that
//! assistive tech reads and steps. An action edits the model like a scrub does and goes through [`InspectorHost::route`],
//! so it is one undo step.

use super::InspectorHost;
use accesskit::{Action, Node, NodeId, Role};
use sq_app_shell::{A11yAction, HostCx};
use sq_draw::A11y;
use sq_inspector_ui::ec::effect_controls_model::layout::EffectRowKind;
use sq_inspector_ui::ec::effect_controls_model::property::{EffectComponent, EffectProperty, EffectPropertyKind};

const PANEL: &str = "inspector";

impl InspectorHost {
    /// The scalar properties of the rows as laid out, top down.
    fn scalar_rows(&self) -> Vec<EffectProperty> {
        let rows = self.controls.rows_panel.rows();
        rows.iter()
            .filter_map(|r| match &r.kind {
                EffectRowKind::Property(p) if p.kind() == EffectPropertyKind::Scalar => Some(p.clone()),
                _ => None,
            })
            .collect()
    }

    /// Pushes one slider per scalar row: label, value and range in the units the row shows.
    pub(super) fn push_nodes(&self, a: &mut A11y) {
        if !a.is_active() {
            return;
        }
        let model = &self.controls.model;
        for p in self.scalar_rows() {
            let mut n = Node::new(Role::Slider);
            n.set_label(p.title());
            n.set_numeric_value(p.display(model.scalar_value(&p), EffectComponent::All, None));
            let range = p.display_range(None);
            n.set_min_numeric_value(*range.start());
            n.set_max_numeric_value(*range.end());
            n.set_numeric_value_step(p.display_step(None));
            for action in [Action::Increment, Action::Decrement, Action::SetValue, Action::Focus] {
                n.add_action(action);
            }
            a.push(PANEL, Role::Slider, &p.raw_value(), n);
        }
    }

    /// Steps or sets the slider `id` names; false when no row has that id or the model refused the value.
    pub(super) fn run_action(&mut self, id: NodeId, action: A11yAction, cx: &mut HostCx) -> bool {
        let Some(p) = self.scalar_rows().into_iter().find(|p| A11y::node_id(PANEL, Role::Slider, &p.raw_value()) == id)
        else {
            return false;
        };
        let model = &mut self.controls.model;
        let shown = p.display(model.scalar_value(&p), EffectComponent::All, None);
        let step = p.display_step(None);
        let target = match action {
            A11yAction::Focus => return true,
            A11yAction::Click | A11yAction::SetText(_) => return false,
            A11yAction::Increment => shown + step,
            A11yAction::Decrement => shown - step,
            A11yAction::SetValue(v) => v,
        };
        let native = p.clamped_native(p.native_from_display(target, EffectComponent::All, None), None);
        let done = model.set_value(&p, EffectComponent::All, native);
        model.end_gesture();
        self.route(cx);
        done
    }
}
