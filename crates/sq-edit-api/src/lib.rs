//! Local edit API (state, commands, discovery) for tools and agents.

pub mod clip_params;
pub mod edit_apirouter;
pub mod edit_apiserver_network;
pub mod edit_apiserver_winsock;
pub mod edit_diff;
pub mod edit_operation;
pub mod edit_transaction;
pub mod http;
pub(crate) mod param_ops;
pub mod perceive;
pub mod project_state;
pub mod text_layers;
pub mod time_limits;

#[cfg(test)]
mod param_tests;
