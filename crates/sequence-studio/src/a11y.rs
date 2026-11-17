//! Turns the panels' accessibility nodes into one accesskit tree: a window root over the nodes in draw order.
//! The platform adapter (accesskit_winit) feeds on these updates; see PORTING-NOTES Escalations.

use accesskit::{Action, ActionData, ActionRequest, Node, NodeId, Role, TreeId, TreeInfo, TreeUpdate};
use sq_app_shell::A11yAction;

/// The id of the window root; panel ids are 64-bit hashes, so a collision is as unlikely as between panels.
const ROOT: NodeId = NodeId(0);

/// The full tree for one frame. Focus stays on the root until panels report a focused node.
pub fn tree_update(title: &str, nodes: Vec<(NodeId, Node)>) -> TreeUpdate {
    let nodes = unique_ids(nodes);
    let mut root = Node::new(Role::Window);
    root.set_label(title);
    root.set_children(nodes.iter().map(|(id, _)| *id).collect::<Vec<_>>());
    let mut all = Vec::with_capacity(nodes.len() + 1);
    all.push((ROOT, root));
    all.extend(nodes);
    TreeUpdate { nodes: all, tree: Some(TreeInfo::new(ROOT)), tree_id: TreeId::ROOT, focus: ROOT }
}

/// Two panels can push the same role and key (same hash); accesskit panics on a repeated id, so a repeat gets a new id.
fn unique_ids(nodes: Vec<(NodeId, Node)>) -> Vec<(NodeId, Node)> {
    let mut seen = std::collections::HashSet::from([ROOT.0]);
    nodes
        .into_iter()
        .map(|(id, node)| {
            let mut v = id.0;
            while !seen.insert(v) {
                v = v.wrapping_mul(0x0100_0000_01b3).wrapping_add(1);
            }
            (NodeId(v), node)
        })
        .collect()
}

/// The node and the host action an accesskit request asks for; `None` for actions no panel offers yet (scroll, text).
pub fn action_of(request: &ActionRequest) -> Option<(NodeId, A11yAction)> {
    let action = match (request.action, &request.data) {
        (Action::Click, _) => A11yAction::Click,
        (Action::Focus, _) => A11yAction::Focus,
        (Action::Increment, _) => A11yAction::Increment,
        (Action::Decrement, _) => A11yAction::Decrement,
        (Action::SetValue, Some(ActionData::NumericValue(v))) => A11yAction::SetValue(*v),
        (Action::SetValue, Some(ActionData::Value(text))) => match text.trim().parse() {
            Ok(v) => A11yAction::SetValue(v),
            Err(_) => A11yAction::SetText(text.to_string()),
        },
        _ => return None,
    };
    Some((request.target_node, action))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(action: Action, data: Option<ActionData>) -> ActionRequest {
        ActionRequest { action, target_tree: TreeId::ROOT, target_node: NodeId(9), data }
    }

    #[test]
    fn requests_map_to_host_actions() {
        let set = request(Action::SetValue, Some(ActionData::Value("42.5".into())));
        assert_eq!(action_of(&set), Some((NodeId(9), A11yAction::SetValue(42.5))));
        let num = request(Action::SetValue, Some(ActionData::NumericValue(3.0)));
        assert_eq!(action_of(&num), Some((NodeId(9), A11yAction::SetValue(3.0))));
        assert_eq!(action_of(&request(Action::Increment, None)).map(|r| r.1), Some(A11yAction::Increment));
        assert_eq!(action_of(&request(Action::SetValue, None)), None);
        assert_eq!(action_of(&request(Action::ScrollDown, None)), None);
    }

    #[test]
    fn root_lists_every_node_in_draw_order() {
        let ids = [NodeId(7), NodeId(3)];
        let nodes = ids.iter().map(|id| (*id, Node::new(Role::Button))).collect();
        let update = tree_update("Sequence Studio", nodes);
        assert_eq!(update.nodes.len(), 3);
        assert_eq!(update.nodes[0].1.children(), &ids);
        assert_eq!(update.nodes[0].1.label(), Some("Sequence Studio"));
        assert_eq!(update.tree.map(|t| t.root), Some(ROOT));
        assert_eq!(update.focus, ROOT);
    }

    #[test]
    fn repeated_ids_get_new_ones() {
        let nodes = vec![
            (NodeId(5), Node::new(Role::Button)),
            (NodeId(5), Node::new(Role::Tab)),
            (NodeId(0), Node::new(Role::Tab)),
        ];
        let update = tree_update("Sequence Studio", nodes);
        let mut ids: Vec<u64> = update.nodes.iter().map(|n| n.0.0).collect();
        ids.sort_unstable();
        ids.dedup();
        assert_eq!(ids.len(), 4);
        assert_eq!(update.nodes[0].1.children().len(), 3);
    }
}
