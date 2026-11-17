// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: StyleEffects, MotionEffects, TemporalEffects, EffectTransformStage, DynamicZoom, Stabilize*, RollingShutter, ShapeGenerator, DateStamp, PosterizeTime, TrackMaskEffect, ColorGradeEffect, ColorGraph, Grouping (kind and parameter key strings of `extension ClipEffect`; stored strings: never rename)

use crate::ClipEffect;

impl ClipEffect {
    // StyleEffects.swift
    /// Stored kind string `vignette`.
    pub const VIGNETTE_KIND: &'static str = "vignette";
    /// Stored key string `vignetteAmount`.
    pub const VIGNETTE_AMOUNT_KEY: &'static str = "vignetteAmount";
    /// Stored key string `vignetteMidpoint`.
    pub const VIGNETTE_MIDPOINT_KEY: &'static str = "vignetteMidpoint";
    /// Stored key string `vignetteRoundness`.
    pub const VIGNETTE_ROUNDNESS_KEY: &'static str = "vignetteRoundness";
    /// Stored key string `vignetteFeather`.
    pub const VIGNETTE_FEATHER_KEY: &'static str = "vignetteFeather";
    /// Stored kind string `filmGrain`.
    pub const GRAIN_KIND: &'static str = "filmGrain";
    /// Stored key string `grainAmount`.
    pub const GRAIN_AMOUNT_KEY: &'static str = "grainAmount";
    /// Stored key string `grainSize`.
    pub const GRAIN_SIZE_KEY: &'static str = "grainSize";
    /// Stored key string `grainColor`.
    pub const GRAIN_COLOR_KEY: &'static str = "grainColor";
    /// Stored key string `grainResponse`.
    pub const GRAIN_RESPONSE_KEY: &'static str = "grainResponse";
    /// Stored key string `grainSoftness`.
    pub const GRAIN_SOFTNESS_KEY: &'static str = "grainSoftness";
    /// Stored key string `grainAnimate`.
    pub const GRAIN_ANIMATE_KEY: &'static str = "grainAnimate";
    /// Stored kind string `rgbSplit`.
    pub const RGB_SPLIT_KIND: &'static str = "rgbSplit";
    /// Stored key string `splitAmount`.
    pub const RGB_SPLIT_AMOUNT_KEY: &'static str = "splitAmount";
    /// Stored key string `splitAngle`.
    pub const RGB_SPLIT_ANGLE_KEY: &'static str = "splitAngle";
    /// Stored key string `splitMode`.
    pub const RGB_SPLIT_MODE_KEY: &'static str = "splitMode";
    /// Stored key string `splitBlend`.
    pub const RGB_SPLIT_BLEND_KEY: &'static str = "splitBlend";
    /// Stored kind string `radialBlur`.
    pub const RADIAL_BLUR_KIND: &'static str = "radialBlur";
    /// Stored key string `radialAmount`.
    pub const RADIAL_AMOUNT_KEY: &'static str = "radialAmount";
    /// Stored key string `radialCenter`.
    pub const RADIAL_CENTER_KEY: &'static str = "radialCenter";
    /// Stored key string `radialType`.
    pub const RADIAL_TYPE_KEY: &'static str = "radialType";
    /// Stored key string `radialQuality`.
    pub const RADIAL_QUALITY_KEY: &'static str = "radialQuality";
    /// Stored kind string `horizontalFlip`.
    pub const HORIZONTAL_FLIP_KIND: &'static str = "horizontalFlip";
    /// Stored kind string `verticalFlip`.
    pub const VERTICAL_FLIP_KIND: &'static str = "verticalFlip";
    /// Stored kind string `invert`.
    pub const INVERT_KIND: &'static str = "invert";
    /// Stored key string `invertChannel`.
    pub const INVERT_CHANNEL_KEY: &'static str = "invertChannel";
    /// Stored key string `invertBlend`.
    pub const INVERT_BLEND_KEY: &'static str = "invertBlend";
    /// Stored kind string `posterize`.
    pub const POSTERIZE_KIND: &'static str = "posterize";
    /// Stored key string `posterizeLevel`.
    pub const POSTERIZE_LEVEL_KEY: &'static str = "posterizeLevel";
    /// Stored kind string `tint`.
    pub const TINT_KIND: &'static str = "tint";
    /// Stored key string `mapBlackTo`.
    pub const TINT_BLACK_KEY: &'static str = "mapBlackTo";
    /// Stored key string `mapWhiteTo`.
    pub const TINT_WHITE_KEY: &'static str = "mapWhiteTo";
    /// Stored key string `amountToTint`.
    pub const TINT_AMOUNT_KEY: &'static str = "amountToTint";
    /// Stored kind string `blackAndWhite`.
    pub const BLACK_AND_WHITE_KIND: &'static str = "blackAndWhite";
    /// Stored kind string `brightnessContrast`.
    pub const BRIGHTNESS_CONTRAST_KIND: &'static str = "brightnessContrast";
    /// Stored key string `brightness`.
    pub const BRIGHTNESS_KEY: &'static str = "brightness";
    /// Stored key string `contrast`.
    pub const CONTRAST_KEY: &'static str = "contrast";
    /// Stored kind string `twirl`.
    pub const TWIRL_KIND: &'static str = "twirl";
    /// Stored key string `twirlAngle`.
    pub const TWIRL_ANGLE_KEY: &'static str = "twirlAngle";
    /// Stored key string `twirlRadius`.
    pub const TWIRL_RADIUS_KEY: &'static str = "twirlRadius";
    /// Stored key string `twirlCenter`.
    pub const TWIRL_CENTER_KEY: &'static str = "twirlCenter";
    /// Stored kind string `cornerPin`.
    pub const CORNER_PIN_KIND: &'static str = "cornerPin";
    /// Stored key string `cornerPinTopLeft`.
    pub const CORNER_PIN_TOP_LEFT_KEY: &'static str = "cornerPinTopLeft";
    /// Stored key string `cornerPinTopRight`.
    pub const CORNER_PIN_TOP_RIGHT_KEY: &'static str = "cornerPinTopRight";
    /// Stored key string `cornerPinBottomRight`.
    pub const CORNER_PIN_BOTTOM_RIGHT_KEY: &'static str = "cornerPinBottomRight";
    /// Stored key string `cornerPinBottomLeft`.
    pub const CORNER_PIN_BOTTOM_LEFT_KEY: &'static str = "cornerPinBottomLeft";
    /// Stored kind string `waveWarp`.
    pub const WAVE_WARP_KIND: &'static str = "waveWarp";
    /// Stored key string `waveType`.
    pub const WAVE_TYPE_KEY: &'static str = "waveType";
    /// Stored key string `waveHeight`.
    pub const WAVE_HEIGHT_KEY: &'static str = "waveHeight";
    /// Stored key string `waveWidth`.
    pub const WAVE_WIDTH_KEY: &'static str = "waveWidth";
    /// Stored key string `waveDirection`.
    pub const WAVE_DIRECTION_KEY: &'static str = "waveDirection";
    /// Stored key string `waveSpeed`.
    pub const WAVE_SPEED_KEY: &'static str = "waveSpeed";
    /// Stored key string `wavePinning`.
    pub const WAVE_PINNING_KEY: &'static str = "wavePinning";
    /// Stored key string `wavePhase`.
    pub const WAVE_PHASE_KEY: &'static str = "wavePhase";
    /// Stored kind string `spherize`.
    pub const SPHERIZE_KIND: &'static str = "spherize";
    /// Stored key string `spherizeRadius`.
    pub const SPHERIZE_RADIUS_KEY: &'static str = "spherizeRadius";
    /// Stored key string `spherizeCenter`.
    pub const SPHERIZE_CENTER_KEY: &'static str = "spherizeCenter";
    /// Stored key string `spherizeStrength`.
    pub const SPHERIZE_STRENGTH_KEY: &'static str = "spherizeStrength";
    /// Stored kind string `strobeLight`.
    pub const STROBE_KIND: &'static str = "strobeLight";
    /// Stored key string `strobeColor`.
    pub const STROBE_COLOR_KEY: &'static str = "strobeColor";
    /// Stored key string `strobeBlend`.
    pub const STROBE_BLEND_KEY: &'static str = "strobeBlend";
    /// Stored key string `strobeDuration`.
    pub const STROBE_DURATION_KEY: &'static str = "strobeDuration";
    /// Stored key string `strobePeriod`.
    pub const STROBE_PERIOD_KEY: &'static str = "strobePeriod";
    /// Stored key string `strobeRandom`.
    pub const STROBE_RANDOM_KEY: &'static str = "strobeRandom";
    /// Stored key string `strobeMode`.
    pub const STROBE_MODE_KEY: &'static str = "strobeMode";
    /// Stored key string `strobeOperator`.
    pub const STROBE_OPERATOR_KEY: &'static str = "strobeOperator";
    /// Stored kind string `alphaAdjust`.
    pub const ALPHA_ADJUST_KIND: &'static str = "alphaAdjust";
    /// Stored key string `alphaOpacity`.
    pub const ALPHA_OPACITY_KEY: &'static str = "alphaOpacity";
    /// Stored key string `ignoreAlpha`.
    pub const ALPHA_IGNORE_KEY: &'static str = "ignoreAlpha";
    /// Stored key string `invertAlpha`.
    pub const ALPHA_INVERT_KEY: &'static str = "invertAlpha";
    /// Stored key string `maskOnly`.
    pub const ALPHA_MASK_ONLY_KEY: &'static str = "maskOnly";
    /// Stored kind string `lensDistortion`.
    pub const LENS_DISTORTION_KIND: &'static str = "lensDistortion";
    /// Stored key string `curvature`.
    pub const LENS_CURVATURE_KEY: &'static str = "curvature";
    /// Stored key string `verticalDecentering`.
    pub const LENS_V_DECENTER_KEY: &'static str = "verticalDecentering";
    /// Stored key string `horizontalDecentering`.
    pub const LENS_H_DECENTER_KEY: &'static str = "horizontalDecentering";
    /// Stored key string `fillAlpha`.
    pub const LENS_FILL_ALPHA_KEY: &'static str = "fillAlpha";
    /// Stored key string `fillColor`.
    pub const LENS_FILL_COLOR_KEY: &'static str = "fillColor";
    /// Stored key string `autoScale`.
    pub const LENS_AUTO_SCALE_KEY: &'static str = "autoScale";
    /// Stored key string `lensModel`.
    pub const LENS_MODEL_KEY: &'static str = "lensModel";
    /// Stored kind string `lightLeak`.
    pub const LIGHT_LEAK_KIND: &'static str = "lightLeak";
    /// Stored key string `leakColor1`.
    pub const LEAK_COLOR1_KEY: &'static str = "leakColor1";
    /// Stored key string `leakColor2`.
    pub const LEAK_COLOR2_KEY: &'static str = "leakColor2";
    /// Stored key string `leakIntensity`.
    pub const LEAK_INTENSITY_KEY: &'static str = "leakIntensity";
    /// Stored key string `leakAngle`.
    pub const LEAK_ANGLE_KEY: &'static str = "leakAngle";
    /// Stored key string `leakSize`.
    pub const LEAK_SIZE_KEY: &'static str = "leakSize";
    /// Stored key string `leakSpeed`.
    pub const LEAK_SPEED_KEY: &'static str = "leakSpeed";
    /// Stored key string `leakSeed`.
    pub const LEAK_SEED_KEY: &'static str = "leakSeed";
    /// Stored kind string `gradient`.
    pub const GRADIENT_KIND: &'static str = "gradient";
    /// Stored key string `gradientColor1`.
    pub const GRADIENT_COLOR1_KEY: &'static str = "gradientColor1";
    /// Stored key string `gradientColor2`.
    pub const GRADIENT_COLOR2_KEY: &'static str = "gradientColor2";
    /// Stored key string `gradientStart`.
    pub const GRADIENT_START_KEY: &'static str = "gradientStart";
    /// Stored key string `gradientEnd`.
    pub const GRADIENT_END_KEY: &'static str = "gradientEnd";
    /// Stored key string `gradientType`.
    pub const GRADIENT_TYPE_KEY: &'static str = "gradientType";
    /// Stored key string `gradientBlend`.
    pub const GRADIENT_BLEND_KEY: &'static str = "gradientBlend";
    /// Stored kind string `halftone`.
    pub const HALFTONE_KIND: &'static str = "halftone";
    /// Stored key string `halftoneSize`.
    pub const HALFTONE_SIZE_KEY: &'static str = "halftoneSize";
    /// Stored key string `halftoneAngle`.
    pub const HALFTONE_ANGLE_KEY: &'static str = "halftoneAngle";
    /// Stored key string `halftoneSoftness`.
    pub const HALFTONE_SOFTNESS_KEY: &'static str = "halftoneSoftness";
    /// Stored key string `halftoneMode`.
    pub const HALFTONE_MODE_KEY: &'static str = "halftoneMode";
    /// Stored key string `halftoneBlend`.
    pub const HALFTONE_BLEND_KEY: &'static str = "halftoneBlend";
    /// Stored kind string `tile`.
    pub const TILE_KIND: &'static str = "tile";
    /// Stored key string `tileColumns`.
    pub const TILE_COLUMNS_KEY: &'static str = "tileColumns";
    /// Stored key string `tileRows`.
    pub const TILE_ROWS_KEY: &'static str = "tileRows";
    /// Stored key string `tileOffsetX`.
    pub const TILE_OFFSET_X_KEY: &'static str = "tileOffsetX";
    /// Stored key string `tileOffsetY`.
    pub const TILE_OFFSET_Y_KEY: &'static str = "tileOffsetY";
    /// Stored key string `tileMirror`.
    pub const TILE_MIRROR_KEY: &'static str = "tileMirror";
    /// Stored kind string `kaleidoscope`.
    pub const KALEIDOSCOPE_KIND: &'static str = "kaleidoscope";
    /// Stored key string `kaleidoCenter`.
    pub const KALEIDO_CENTER_KEY: &'static str = "kaleidoCenter";
    /// Stored key string `kaleidoSegments`.
    pub const KALEIDO_SEGMENTS_KEY: &'static str = "kaleidoSegments";
    /// Stored key string `kaleidoAngle`.
    pub const KALEIDO_ANGLE_KEY: &'static str = "kaleidoAngle";
    /// Stored key string `kaleidoZoom`.
    pub const KALEIDO_ZOOM_KEY: &'static str = "kaleidoZoom";
    /// Stored kind string `edgeFeather`.
    pub const EDGE_FEATHER_KIND: &'static str = "edgeFeather";
    /// Stored key string `edgeFeatherAmount`.
    pub const EDGE_FEATHER_AMOUNT_KEY: &'static str = "edgeFeatherAmount";
    /// Stored kind string `glitchDisplace`.
    pub const GLITCH_KIND: &'static str = "glitchDisplace";
    /// Stored key string `glitchAmount`.
    pub const GLITCH_AMOUNT_KEY: &'static str = "glitchAmount";
    /// Stored key string `glitchBlock`.
    pub const GLITCH_BLOCK_KEY: &'static str = "glitchBlock";
    /// Stored key string `glitchSplit`.
    pub const GLITCH_SPLIT_KEY: &'static str = "glitchSplit";
    /// Stored key string `glitchDensity`.
    pub const GLITCH_DENSITY_KEY: &'static str = "glitchDensity";
    /// Stored key string `glitchRate`.
    pub const GLITCH_RATE_KEY: &'static str = "glitchRate";
    /// Stored key string `glitchSeed`.
    pub const GLITCH_SEED_KEY: &'static str = "glitchSeed";
    /// Stored kind string `alphaOutline`.
    pub const OUTLINE_KIND: &'static str = "alphaOutline";
    /// Stored key string `outlineWidth`.
    pub const OUTLINE_WIDTH_KEY: &'static str = "outlineWidth";
    /// Stored key string `outlineColor`.
    pub const OUTLINE_COLOR_KEY: &'static str = "outlineColor";
    /// Stored key string `outlineSoftness`.
    pub const OUTLINE_SOFTNESS_KEY: &'static str = "outlineSoftness";
    /// Stored key string `outlinePosition`.
    pub const OUTLINE_POSITION_KEY: &'static str = "outlinePosition";
    /// Stored kind string `longShadow`.
    pub const LONG_SHADOW_KIND: &'static str = "longShadow";
    /// Stored key string `longShadowAngle`.
    pub const LONG_SHADOW_ANGLE_KEY: &'static str = "longShadowAngle";
    /// Stored key string `longShadowLength`.
    pub const LONG_SHADOW_LENGTH_KEY: &'static str = "longShadowLength";
    /// Stored key string `longShadowColor`.
    pub const LONG_SHADOW_COLOR_KEY: &'static str = "longShadowColor";
    /// Stored key string `longShadowFade`.
    pub const LONG_SHADOW_FADE_KEY: &'static str = "longShadowFade";
    /// Stored key string `longShadowOpacity`.
    pub const LONG_SHADOW_OPACITY_KEY: &'static str = "longShadowOpacity";

    // MotionEffects.swift
    /// Stored kind string `motionMove`.
    pub const MOVE_KIND: &'static str = "motionMove";
    /// Stored kind string `motionZoom`.
    pub const ZOOM_KIND: &'static str = "motionZoom";
    /// Stored kind string `motionPop`.
    pub const POP_KIND: &'static str = "motionPop";
    /// Stored kind string `motionFade`.
    pub const FADE_KIND: &'static str = "motionFade";
    /// Stored kind string `motionShake`.
    pub const SHAKE_KIND: &'static str = "motionShake";
    /// Stored kind string `motionBounce`.
    pub const BOUNCE_KIND: &'static str = "motionBounce";
    /// Stored kind string `motionPulse`.
    pub const PULSE_KIND: &'static str = "motionPulse";
    /// Stored kind string `motionWiggle`.
    pub const WIGGLE_KIND: &'static str = "motionWiggle";
    /// Stored key string `mode`.
    pub const MOTION_MODE_KEY: &'static str = "mode";
    /// Stored key string `curve`.
    pub const MOTION_CURVE_KEY: &'static str = "curve";
    /// Stored key string `duration`.
    pub const MOTION_DURATION_KEY: &'static str = "duration";
    /// Stored key string `outDuration`.
    pub const MOTION_OUT_DURATION_KEY: &'static str = "outDuration";
    /// Stored key string `direction`.
    pub const MOVE_DIRECTION_KEY: &'static str = "direction";
    /// Stored key string `distance`.
    pub const MOVE_DISTANCE_KEY: &'static str = "distance";
    /// Stored key string `rotation`.
    pub const MOVE_ROTATION_KEY: &'static str = "rotation";
    /// Stored key string `fade`.
    pub const MOVE_FADE_KEY: &'static str = "fade";
    /// Stored key string `fadeLength`.
    pub const MOVE_FADE_LENGTH_KEY: &'static str = "fadeLength";
    /// Stored key string `side`.
    pub const MOVE_SIDE_KEY: &'static str = "side";
    /// Stored key string `spin`.
    pub const MOVE_SPIN_KEY: &'static str = "spin";
    /// Stored key string `edgeScale`.
    pub const MOVE_SCALE_KEY: &'static str = "edgeScale";
    /// Stored key string `from`.
    pub const ZOOM_FROM_KEY: &'static str = "from";
    /// Stored key string `to`.
    pub const ZOOM_TO_KEY: &'static str = "to";
    /// Stored key string `from`.
    pub const POP_FROM_KEY: &'static str = "from";
    /// Stored key string `peak`.
    pub const POP_PEAK_KEY: &'static str = "peak";
    /// Stored key string `settle`.
    pub const POP_SETTLE_KEY: &'static str = "settle";
    /// Stored key string `peakAt`.
    pub const POP_PEAK_AT_KEY: &'static str = "peakAt";
    /// Stored key string `start`.
    pub const FADE_START_KEY: &'static str = "start";
    /// Stored key string `period`.
    pub const LOOP_PERIOD_KEY: &'static str = "period";
    /// Stored key string `phase`.
    pub const LOOP_PHASE_KEY: &'static str = "phase";
    /// Stored key string `height`.
    pub const BOUNCE_HEIGHT_KEY: &'static str = "height";
    /// Stored key string `direction`.
    pub const BOUNCE_DIRECTION_KEY: &'static str = "direction";
    /// Stored key string `squash`.
    pub const BOUNCE_SQUASH_KEY: &'static str = "squash";
    /// Stored key string `from`.
    pub const PULSE_FROM_KEY: &'static str = "from";
    /// Stored key string `to`.
    pub const PULSE_TO_KEY: &'static str = "to";
    /// Stored key string `fadeDepth`.
    pub const PULSE_FADE_KEY: &'static str = "fadeDepth";
    /// Stored key string `angle`.
    pub const WIGGLE_ANGLE_KEY: &'static str = "angle";
    /// Stored key string `shift`.
    pub const WIGGLE_SHIFT_KEY: &'static str = "shift";
    /// Stored key string `strength`.
    pub const SHAKE_STRENGTH_KEY: &'static str = "strength";
    /// Stored key string `rotation`.
    pub const SHAKE_ROTATION_KEY: &'static str = "rotation";
    /// Stored key string `speed`.
    pub const SHAKE_SPEED_KEY: &'static str = "speed";
    /// Stored key string `seed`.
    pub const SHAKE_SEED_KEY: &'static str = "seed";

    // TemporalEffects.swift
    /// Stored kind string `videoDenoise`.
    pub const VIDEO_DENOISE_KIND: &'static str = "videoDenoise";
    /// Stored kind string `deflicker`.
    pub const DEFLICKER_KIND: &'static str = "deflicker";
    /// Stored kind string `motionBlurFX`.
    pub const MOTION_BLUR_KIND: &'static str = "motionBlurFX";
    /// Stored key string `framesEachSide`.
    pub const FRAMES_EACH_SIDE_KEY: &'static str = "framesEachSide";
    /// Stored key string `quality`.
    pub const QUALITY_KEY: &'static str = "quality";
    /// Stored key string `motionSearch`.
    pub const MOTION_SEARCH_KEY: &'static str = "motionSearch";
    /// Stored key string `lumaStrength`.
    pub const LUMA_STRENGTH_KEY: &'static str = "lumaStrength";
    /// Stored key string `colorStrength`.
    pub const COLOR_STRENGTH_KEY: &'static str = "colorStrength";
    /// Stored key string `motionLimit`.
    pub const MOTION_LIMIT_KEY: &'static str = "motionLimit";
    /// Stored key string `detailSize`.
    pub const DETAIL_SIZE_KEY: &'static str = "detailSize";
    /// Stored key string `spatialLuma`.
    pub const SPATIAL_LUMA_KEY: &'static str = "spatialLuma";
    /// Stored key string `spatialColor`.
    pub const SPATIAL_COLOR_KEY: &'static str = "spatialColor";
    /// Stored key string `keepOriginal`.
    pub const KEEP_ORIGINAL_KEY: &'static str = "keepOriginal";
    /// Stored key string `analysis`.
    pub const ANALYSIS_KEY: &'static str = "analysis";
    /// Stored key string `strength`.
    pub const STRENGTH_KEY: &'static str = "strength";
    /// Stored key string `blurSide`.
    pub const BLUR_DIRECTION_MODE_KEY: &'static str = "blurSide";
    /// Stored key string `smoothness`.
    pub const SMOOTHNESS_KEY: &'static str = "smoothness";
    /// Stored kind string `trails`.
    pub const TRAILS_KIND: &'static str = "trails";
    /// Stored key string `trailCount`.
    pub const TRAIL_COUNT_KEY: &'static str = "trailCount";
    /// Stored key string `trailSpacing`.
    pub const TRAIL_SPACING_KEY: &'static str = "trailSpacing";
    /// Stored key string `trailDecay`.
    pub const TRAIL_DECAY_KEY: &'static str = "trailDecay";
    /// Stored key string `trailBlend`.
    pub const TRAIL_BLEND_KEY: &'static str = "trailBlend";

    // EffectTransformStage.swift
    /// Stored kind string `transform`.
    pub const TRANSFORM_KIND: &'static str = "transform";
    /// Stored kind string `reframe`.
    pub const REFRAME_KIND: &'static str = "reframe";
    /// Stored key string `anchorX`.
    pub const STAGE_ANCHOR_X_KEY: &'static str = "anchorX";
    /// Stored key string `anchorY`.
    pub const STAGE_ANCHOR_Y_KEY: &'static str = "anchorY";
    /// Stored key string `positionX`.
    pub const STAGE_POSITION_X_KEY: &'static str = "positionX";
    /// Stored key string `positionY`.
    pub const STAGE_POSITION_Y_KEY: &'static str = "positionY";
    /// Stored key string `scale`.
    pub const STAGE_SCALE_KEY: &'static str = "scale";
    /// Stored key string `scaleY`.
    pub const STAGE_SCALE_Y_KEY: &'static str = "scaleY";
    /// Stored key string `rotation`.
    pub const STAGE_ROTATION_KEY: &'static str = "rotation";
    /// Stored key string `opacity`.
    pub const STAGE_OPACITY_KEY: &'static str = "opacity";
    /// Stored key string `shutterAngle`.
    pub const STAGE_SHUTTER_ANGLE_KEY: &'static str = "shutterAngle";

    // DynamicZoom.swift
    /// Stored kind string `dynamicZoom`.
    pub const DYNAMIC_ZOOM_KIND: &'static str = "dynamicZoom";

    // StabilizeEffect.swift
    /// Stored key string `stabilizeMethod`.
    pub const STABILIZE_METHOD_KEY: &'static str = "stabilizeMethod";
    /// Stored key string `gyroSmoothness`.
    pub const GYRO_SMOOTHNESS_KEY: &'static str = "gyroSmoothness";
    /// Stored key string `gyroZoomLimit`.
    pub const GYRO_ZOOM_LIMIT_KEY: &'static str = "gyroZoomLimit";
    /// Stored key string `gyroRollingShutter`.
    pub const GYRO_ROLLING_SHUTTER_KEY: &'static str = "gyroRollingShutter";
    /// Stored key string `gyroHorizonLock`.
    pub const GYRO_HORIZON_LOCK_KEY: &'static str = "gyroHorizonLock";
    /// Stored key string `gyroFieldOfView`.
    pub const GYRO_FIELD_OF_VIEW_KEY: &'static str = "gyroFieldOfView";
    /// Stored key string `gyroLensCorrection`.
    pub const GYRO_LENS_CORRECTION_KEY: &'static str = "gyroLensCorrection";
    /// Stored key string `gyroSyncOffset`.
    pub const GYRO_SYNC_OFFSET_KEY: &'static str = "gyroSyncOffset";

    // Stabilizer.swift
    /// Stored kind string `stabilize`.
    pub const STABILIZE_KIND: &'static str = "stabilize";
    /// Stored key string `stabilizeStrength`.
    pub const STABILIZE_STRENGTH_KEY: &'static str = "stabilizeStrength";
    /// Stored key string `edgeFill`.
    pub const STABILIZE_EDGE_FILL_KEY: &'static str = "edgeFill";
    /// Stored key string `stabilizeMode`.
    pub const STABILIZE_MODE_KEY: &'static str = "stabilizeMode";
    /// Stored key string `smoothness`.
    pub const STABILIZE_SMOOTHNESS_KEY: &'static str = "smoothness";
    /// Stored key string `maxCrop`.
    pub const STABILIZE_MAX_CROP_KEY: &'static str = "maxCrop";
    /// Stored key string `analysedFrom`.
    pub const STABILIZE_FROM_KEY: &'static str = "analysedFrom";
    /// Stored key string `analysedTo`.
    pub const STABILIZE_TO_KEY: &'static str = "analysedTo";

    // RollingShutter.swift
    /// Stored key string `rollingShutter`.
    pub const ROLLING_SHUTTER_KEY: &'static str = "rollingShutter";
    /// Stored key string `rollingShutterStrength`.
    pub const ROLLING_SHUTTER_STRENGTH_KEY: &'static str = "rollingShutterStrength";
    /// Stored key string `rollingShearX`.
    pub const ROLLING_SHEAR_X_KEY: &'static str = "rollingShearX";
    /// Stored key string `rollingShearY`.
    pub const ROLLING_SHEAR_Y_KEY: &'static str = "rollingShearY";
    /// Stored key string `rollingScanAxis`.
    pub const ROLLING_SCAN_AXIS_KEY: &'static str = "rollingScanAxis";

    // ShapeGenerator.swift

    // DateStamp.swift
    /// Stored kind string `dateStamp`.
    pub const DATE_STAMP_KIND: &'static str = "dateStamp";
    /// Stored key string `stampFormat`.
    pub const STAMP_FORMAT_KEY: &'static str = "stampFormat";
    /// Stored key string `stampYear`.
    pub const STAMP_YEAR_KEY: &'static str = "stampYear";
    /// Stored key string `stampMonth`.
    pub const STAMP_MONTH_KEY: &'static str = "stampMonth";
    /// Stored key string `stampDay`.
    pub const STAMP_DAY_KEY: &'static str = "stampDay";
    /// Stored key string `stampHour`.
    pub const STAMP_HOUR_KEY: &'static str = "stampHour";
    /// Stored key string `stampMinute`.
    pub const STAMP_MINUTE_KEY: &'static str = "stampMinute";
    /// Stored key string `stampPosition`.
    pub const STAMP_POSITION_KEY: &'static str = "stampPosition";
    /// Stored key string `stampSize`.
    pub const STAMP_SIZE_KEY: &'static str = "stampSize";
    /// Stored key string `stampColor`.
    pub const STAMP_COLOR_KEY: &'static str = "stampColor";
    /// Stored key string `stampBlink`.
    pub const STAMP_BLINK_KEY: &'static str = "stampBlink";

    // PosterizeTime.swift
    /// Stored kind string `posterizeTime`.
    pub const POSTERIZE_TIME_KIND: &'static str = "posterizeTime";
    /// Stored key string `posterizeRate`.
    pub const POSTERIZE_RATE_KEY: &'static str = "posterizeRate";

    // TrackMaskEffect.swift
    /// Stored kind string `trackMask`.
    pub const TRACK_MASK_KIND: &'static str = "trackMask";
    /// Stored key string `trackMaskMode`.
    pub const TRACK_MASK_MODE_KEY: &'static str = "trackMaskMode";
    /// Stored key string `trackMaskInvert`.
    pub const TRACK_MASK_INVERT_KEY: &'static str = "trackMaskInvert";

    // ColorGradeEffect.swift
    /// Stored kind string `color`.
    pub const COLOR_KIND: &'static str = "color";
    /// Stored key string `basicCorrectionOn`.
    pub const COLOR_BASIC_ON_KEY: &'static str = "basicCorrectionOn";
    /// Stored key string `creativeOn`.
    pub const COLOR_CREATIVE_ON_KEY: &'static str = "creativeOn";
    /// Stored key string `curvesOn`.
    pub const COLOR_CURVES_ON_KEY: &'static str = "curvesOn";
    /// Stored key string `wheelsOn`.
    pub const COLOR_WHEELS_ON_KEY: &'static str = "wheelsOn";
    /// Stored key string `vignetteOn`.
    pub const COLOR_VIGNETTE_ON_KEY: &'static str = "vignetteOn";
    /// Stored key string `temperature`.
    pub const COLOR_TEMPERATURE_KEY: &'static str = "temperature";
    /// Stored key string `tint`.
    pub const COLOR_TINT_KEY: &'static str = "tint";
    /// Stored key string `exposure`.
    pub const COLOR_EXPOSURE_KEY: &'static str = "exposure";
    /// Stored key string `contrast`.
    pub const COLOR_CONTRAST_KEY: &'static str = "contrast";
    /// Stored key string `highlights`.
    pub const COLOR_HIGHLIGHTS_KEY: &'static str = "highlights";
    /// Stored key string `shadows`.
    pub const COLOR_SHADOWS_KEY: &'static str = "shadows";
    /// Stored key string `whites`.
    pub const COLOR_WHITES_KEY: &'static str = "whites";
    /// Stored key string `blacks`.
    pub const COLOR_BLACKS_KEY: &'static str = "blacks";
    /// Stored key string `saturation`.
    pub const COLOR_SATURATION_KEY: &'static str = "saturation";
    /// Stored key string `vibrance`.
    pub const COLOR_VIBRANCE_KEY: &'static str = "vibrance";
    /// Stored key string `inputLUTIntensity`.
    pub const COLOR_INPUT_LUT_INTENSITY_KEY: &'static str = "inputLUTIntensity";
    /// Stored key string `lookIntensity`.
    pub const COLOR_LOOK_INTENSITY_KEY: &'static str = "lookIntensity";
    /// Stored key string `fadedFilm`.
    pub const COLOR_FADED_FILM_KEY: &'static str = "fadedFilm";
    /// Stored key string `creativeVibrance`.
    pub const COLOR_CREATIVE_VIBRANCE_KEY: &'static str = "creativeVibrance";
    /// Stored key string `creativeSaturation`.
    pub const COLOR_CREATIVE_SATURATION_KEY: &'static str = "creativeSaturation";
    /// Stored key string `shadowTintHue`.
    pub const COLOR_SHADOW_TINT_HUE_KEY: &'static str = "shadowTintHue";
    /// Stored key string `shadowTintAmount`.
    pub const COLOR_SHADOW_TINT_AMOUNT_KEY: &'static str = "shadowTintAmount";
    /// Stored key string `highlightTintHue`.
    pub const COLOR_HIGHLIGHT_TINT_HUE_KEY: &'static str = "highlightTintHue";
    /// Stored key string `highlightTintAmount`.
    pub const COLOR_HIGHLIGHT_TINT_AMOUNT_KEY: &'static str = "highlightTintAmount";
    /// Stored key string `tintBalance`.
    pub const COLOR_TINT_BALANCE_KEY: &'static str = "tintBalance";
    /// Stored key string `wheelShadowsHue`.
    pub const COLOR_WHEEL_SHADOWS_HUE_KEY: &'static str = "wheelShadowsHue";
    /// Stored key string `wheelShadowsAmount`.
    pub const COLOR_WHEEL_SHADOWS_AMOUNT_KEY: &'static str = "wheelShadowsAmount";
    /// Stored key string `wheelShadowsLuma`.
    pub const COLOR_WHEEL_SHADOWS_LUMA_KEY: &'static str = "wheelShadowsLuma";
    /// Stored key string `wheelMidtonesHue`.
    pub const COLOR_WHEEL_MIDTONES_HUE_KEY: &'static str = "wheelMidtonesHue";
    /// Stored key string `wheelMidtonesAmount`.
    pub const COLOR_WHEEL_MIDTONES_AMOUNT_KEY: &'static str = "wheelMidtonesAmount";
    /// Stored key string `wheelMidtonesLuma`.
    pub const COLOR_WHEEL_MIDTONES_LUMA_KEY: &'static str = "wheelMidtonesLuma";
    /// Stored key string `wheelHighlightsHue`.
    pub const COLOR_WHEEL_HIGHLIGHTS_HUE_KEY: &'static str = "wheelHighlightsHue";
    /// Stored key string `wheelHighlightsAmount`.
    pub const COLOR_WHEEL_HIGHLIGHTS_AMOUNT_KEY: &'static str = "wheelHighlightsAmount";
    /// Stored key string `wheelHighlightsLuma`.
    pub const COLOR_WHEEL_HIGHLIGHTS_LUMA_KEY: &'static str = "wheelHighlightsLuma";
    /// Stored key string `wheelSaturation`.
    pub const COLOR_WHEEL_SATURATION_KEY: &'static str = "wheelSaturation";
    /// Stored key string `vignetteAmount`.
    pub const COLOR_VIGNETTE_AMOUNT_KEY: &'static str = "vignetteAmount";
    /// Stored key string `vignetteMidpoint`.
    pub const COLOR_VIGNETTE_MIDPOINT_KEY: &'static str = "vignetteMidpoint";
    /// Stored key string `vignetteRoundness`.
    pub const COLOR_VIGNETTE_ROUNDNESS_KEY: &'static str = "vignetteRoundness";
    /// Stored key string `vignetteFeather`.
    pub const COLOR_VIGNETTE_FEATHER_KEY: &'static str = "vignetteFeather";
    /// Stored key string `basicModel`.
    pub const COLOR_BASIC_MODEL_KEY: &'static str = "basicModel";

    // ColorGraph.swift
    /// Stored kind string `colorGraph`.
    pub const COLOR_GRAPH_KIND: &'static str = "colorGraph";

    // Grouping.swift
    /// Stored kind string `groupTransform`.
    pub const GROUP_TRANSFORM_KIND: &'static str = "groupTransform";
    /// Stored key string `position`.
    pub const GROUP_POSITION_KEY: &'static str = "position";
    /// Stored key string `scale`.
    pub const GROUP_SCALE_KEY: &'static str = "scale";
    /// Stored key string `anchor`.
    pub const GROUP_ANCHOR_KEY: &'static str = "anchor";
    /// Stored key string `rotation`.
    pub const GROUP_ROTATION_KEY: &'static str = "rotation";
    /// Stored key string `opacity`.
    pub const GROUP_OPACITY_KEY: &'static str = "opacity";

    /// Every parametric motion effect kind (Move, Zoom, Pop, Fade, Shake and the N3 loop animators).
    pub const MOTION_KINDS: [&'static str; 8] = [
        Self::MOVE_KIND,
        Self::ZOOM_KIND,
        Self::POP_KIND,
        Self::FADE_KIND,
        Self::SHAKE_KIND,
        Self::BOUNCE_KIND,
        Self::PULSE_KIND,
        Self::WIGGLE_KIND,
    ];

    /// A motion preset (evaluated live on the effect transform stage).
    pub fn is_motion_preset(&self) -> bool {
        Self::MOTION_KINDS.contains(&self.kind.as_str())
    }
}
