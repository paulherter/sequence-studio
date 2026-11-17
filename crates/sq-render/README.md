# sq-render

Render graph and compositor: layer requests to GPU passes, color pipeline, effects, scopes; CPU references as test oracle. Design: docs/rust/render-playback-export-design.md. Modules: passes, color, effects, compositor, gpu_effects, program.

Test: `cargo xtask check sq-render`.
