//! The drawn timeline (Swift `SQDrawTimeline`): one `AppHost` that draws and routes input for the timeline panel.
//! `TimelinePanel+X.swift` is `x.rs` (the extension files whose Swift names clash with a control are
//! `caption_lanes` (`+Captions`), `caption_search_panel` (`+CaptionSearch`), `band_gestures` (`+Bands`) and
//! `track_headers` (`+Header`)); the controls (`captions`, `bands`, `header`, `lanes`, `menus`, `tool_strip`, `trim_bar`)
//! are panel-free.

pub mod action;
pub mod app_host;
mod cursor;
#[cfg(test)]
mod cursor_tests;
mod draw;
mod drop;
#[cfg(test)]
mod drop_tests;
mod follow;
mod geom;
pub mod host;
mod host_defaults;
mod input;
#[cfg(test)]
mod interaction_tests;
#[cfg(test)]
mod key_tests;
mod lane_cache;
#[cfg(test)]
mod mac_parity_tests;
pub mod media;
mod overlays;
pub mod panel;
#[cfg(test)]
mod panel_state_tests;
#[cfg(test)]
mod panel_tests;
#[cfg(test)]
mod perf_tests;
mod ruler;
pub mod session_bridge;
#[cfg(test)]
mod ship_a_tests;
mod skimmer;
pub mod skin;
#[cfg(test)]
mod tests;
pub mod thumbnail_atlas;
mod wheel;
mod zoom_bar;

mod band_gestures;
pub mod bands;
mod caption_lanes;
mod caption_search_panel;
mod caption_words;
pub mod captions;
pub mod clip_menu_groups;
mod fast_cut;
pub mod header;
mod item_lanes;
mod key_lanes;
mod keystones;
pub mod lanes;
pub mod menus;
mod source_patch;
mod speed_band;
mod speed_commands;
pub mod timeline_menus;
pub mod tool_strip;
mod track_headers;
mod transition_layer;
pub mod trim_bar;
mod view_commands;

pub use action::TimelineAction;
pub use app_host::TimelineAppHost;
pub use drop::{EffectDrop, TimelineDropSource, drop_items, drop_replace};
pub use host::{TimelineEditorRequest, TimelineHost, TimelinePrompt};
pub use media::{TimelineMediaSource, TimelinePicture};
pub use panel::{SessionView, TimelinePanel};
pub use thumbnail_atlas::{ThumbnailAtlas, ThumbnailKey};
pub use timeline_menus::{MenuEffect, MenuOutbox, TimelineMenus, new_outbox};
