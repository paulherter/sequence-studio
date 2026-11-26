//! Local edit API (state, commands, discovery) for tools and agents.

pub mod clip_params;
pub mod edit_apirouter;
pub mod edit_apiserver_network;
pub mod edit_apiserver_winsock;
pub mod edit_diff;
pub mod edit_operation;
pub mod edit_transaction;
pub mod gaps;
pub mod http;
pub(crate) mod mask_ops;
pub(crate) mod param_ops;
pub mod perceive;
pub mod project_state;
pub(crate) mod text_accent;
pub mod text_animators;
pub mod text_layers;
pub mod text_tracking;
pub mod time_limits;
pub mod transition_ops;
pub(crate) mod zoom_cut;

#[cfg(test)]
mod param_tests;
#[cfg(test)]
mod accent_mask_tests;
#[cfg(test)]
mod zoom_cut_tests;
