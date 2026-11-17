//! The color space tag of the window surface. wgpu configures the CAMetalLayer of an sRGB surface with `colorspace =
//! nil`, and an untagged layer is not color managed: the window server shows its code values as raw display values,
//! which on a Display P3 screen are more saturated and harder than sRGB (docs/rust/COLOR-DISPLAY.md). Tagging the layer
//! sRGB, like the Swift app's UI layer, makes macOS convert to the actual display.

use objc2_core_graphics::{CGColorSpace, kCGColorSpaceDisplayP3, kCGColorSpaceSRGB};

/// Tags the CAMetalLayer behind `surface` as sRGB. Call after every `surface.configure` (wgpu resets the tag there) on
/// the main thread. Does nothing on a surface that is not a Metal one.
pub fn tag_surface_srgb(surface: &wgpu::Surface<'_>) {
    // SAFETY: the guard only lends the layer; nothing here destroys it or touches GPU work. `kCGColorSpaceSRGB` is an
    // immutable CoreGraphics constant.
    unsafe {
        let Some(hal) = surface.as_hal::<wgpu::hal::api::Metal>() else { return };
        let layer = hal.render_layer().lock();
        let srgb = CGColorSpace::with_name(Some(kCGColorSpaceSRGB));
        layer.setColorspace(srgb.as_deref());
    }
}

/// Tags the CAMetalLayer behind `surface` as Display P3 (sRGB transfer): the 8-bit surface of the Display P3 view. Same
/// rules as [`tag_surface_srgb`].
pub fn tag_surface_display_p3(surface: &wgpu::Surface<'_>) {
    // SAFETY: as `tag_surface_srgb`; `kCGColorSpaceDisplayP3` is an immutable CoreGraphics constant.
    unsafe {
        let Some(hal) = surface.as_hal::<wgpu::hal::api::Metal>() else { return };
        let layer = hal.render_layer().lock();
        let p3 = CGColorSpace::with_name(Some(kCGColorSpaceDisplayP3));
        layer.setColorspace(p3.as_deref());
    }
}

/// What the CAMetalLayer behind `surface` is set to: Metal pixel format (80 = bgra8Unorm, 115 = rgba16Float), the
/// color space name and the extended-range (EDR) flag. For the log line after a configure; `None` on a non-Metal surface.
pub fn layer_report(surface: &wgpu::Surface<'_>) -> Option<String> {
    // SAFETY: read-only getters on the layer under the guard.
    unsafe {
        let hal = surface.as_hal::<wgpu::hal::api::Metal>()?;
        let layer = hal.render_layer().lock();
        let space = layer.colorspace();
        let name = space.as_deref().and_then(|s| CGColorSpace::name(Some(s))).map_or_else(
            || if space.is_some() { "unnamed".to_string() } else { "none".to_string() },
            |n| n.to_string(),
        );
        Some(format!(
            "layer pixel format {}, colorspace {name}, wantsExtendedDynamicRangeContent {}",
            layer.pixelFormat().0,
            layer.wantsExtendedDynamicRangeContent()
        ))
    }
}
