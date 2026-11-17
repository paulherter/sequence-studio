# sq-core-model ownership

Every model type is a plain value (`Clone`), like the Swift structs: no `Rc`, `Arc`, `RefCell` or `Mutex` in this crate.
Undo stays snapshot-based (clone of `Project`); a faster structure is a later design decision, not a porting one.

| field | owner | lifetime | shared-by |
|---|---|---|---|
| `Project.timelines`, `Project.media`, `Project.root_bin` | `Project` | project open | render/export read a cloned snapshot |
| `Timeline.tracks` | `Timeline` | project open | render thread via snapshot clone |
| `Track.clips` (private, sorted) | `Track` | project open | read with `Track::clips()`; writes through Track methods only |
| `Clip.*_store` (`#[doc(hidden)] pub`) | `Clip` | project open | higher `sq-core-*` crates through their `*Ext` accessors |
| `Timeline.render_cache_spans` (not saved) | `Timeline` | session | playback reads it from the snapshot |
| `GeneratorRef.payload` (opaque bytes) | `Clip` | project open | decoded by the generator's crate (`&[u8]`) |

Encoder state (project file version flags) is not model data: it lives in `sq_core_time::EncodeContext`, a scope on the
encoding thread.
