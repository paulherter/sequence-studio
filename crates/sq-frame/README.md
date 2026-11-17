# sq-frame

Frame buffers and pixel formats shared by decode, render and export. One module per Swift file (Apple-only files are not ported: the portable path is the reference).

Test: `cargo xtask check sq-frame`.

Port notes: `SQFrameStorage` is `Any + Send + Sync`; a frame holds an `Arc<dyn SQFrameStorage>` and `storage_as::<T>()` replaces
Swift's `storage as? T`. `sqframe_core_video` is Apple-only and not ported.
