// Swift: LottieRenderer.swift is the Mac side (CoreVideo buffers) and is not ported; its byte-budget frame cache is `lottie_document::FrameCache`. What
// stands here is the seam it and the portable path both draw through: the rasterizer that ThorVG implements in Swift.
//! The rasterizer seam: one Lottie document opened in a software renderer, drawn frame by frame.

/// Opens Lottie documents in a software rasterizer (ThorVG's software renderer in the product).
pub trait LottieEngine: Send + Sync {
    /// The drawing handle for the document in `json`, or `None` when the engine cannot read it.
    fn open(&self, json: &[u8]) -> Option<Box<dyn LottieDrawing>>;
}

/// One opened document. Drawing is single-threaded and deterministic: the same frame and size give the same pixels.
pub trait LottieDrawing: Send {
    /// Straight (not premultiplied) display-encoded RGBA8 pixels of `frame` at `width` x `height`, top row first, or `None`
    /// when the draw fails.
    fn render(&mut self, frame: f32, width: usize, height: usize) -> Option<Vec<u8>>;
}
