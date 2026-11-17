//! Guard for the Windows caption wrapper, which only compiles on Windows: its test must run on every platform.

/// `CaptionRoot` (caption_root.rs) must forward every `AppHost` method to the app root: a method left at its trait
/// default drops the call silently. J/K/L key-up was lost this way, and `wants_frames` was too: after `\` the fit glide
/// drew its first frame and then the loop slept, so the screen stayed on the old view until the next input.
#[test]
fn every_app_host_method_is_forwarded() {
    let host = include_str!("../../sq-app-shell/src/host.rs");
    let wrapper = include_str!("caption_root.rs");
    let trait_body = host.split("pub trait AppHost").nth(1).expect("trait AppHost");
    let methods: Vec<&str> = trait_body
        .lines()
        .filter_map(|l| l.trim().strip_prefix("fn "))
        .filter_map(|l| l.split(['(', '<']).next())
        .collect();
    assert!(methods.contains(&"key_up") && methods.contains(&"wants_frames") && methods.len() > 10, "{methods:?}");
    for m in methods {
        assert!(wrapper.contains(&format!("fn {m}(")), "CaptionRoot does not implement AppHost::{m}");
        assert!(wrapper.contains(&format!("self.root.{m}(")), "CaptionRoot does not forward AppHost::{m} to the root");
    }
}
