# sq-core-graphics

Graphics, title templates, text animators, shape and format variant logic of the Sequence Studio project model. One module per Swift file; saved types are in `sq-core-model`, the logic is extension traits (`GraphicsDocumentEditingExt`, ...).

Modules: Graphic layer verbs (`graphics_create`, `graphics_editing`, `graphics_follow`, `graphics_layer_projection`, `graphics_make_graphic`, `graphics_move_out`), `text_animator_model` (also the caption hand-over animation rules), `split_layout`, `custom_animation`, `shape_generator`, `date_stamp`, `lottie_generator`, `format_variants_view`. `NOTES.md` has the `LayerHooks` wiring and what waits on other crates.

Test: `cargo xtask check sq-core-graphics`.
