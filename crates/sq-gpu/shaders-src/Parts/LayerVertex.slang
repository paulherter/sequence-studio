// The layer quad of the compositor's draws (was CompositorShaderSource.msl in SQRender; engine SQRender Compositor). A
// module with a layer draw includes this after its `CompositeU cu : register(b0)`; the vertex reads the same block as the
// fragment. Drawn as a 4-vertex triangle strip.

struct VOut {
    float4 position : SV_Position;
    float2 local : LOCAL;   // layer px, centered
};

// Edge antialiasing (mask on the layer rect) is on for rounded or rotated layers only, so axis-aligned unrounded layers
// stay bit-exact. The quad is grown by 1 screen px then so edge pixels outside get covered.
bool hasCrop(CompositeU u) { return any(u.crop != 0.0f); }
bool edgeAA(CompositeU u) {
    return u.cornerRadius > 0.0f || u.rotSin != 0.0f || u.tilt.z > 0.0f || hasCrop(u) || u.cropFeather > 0.0f;
}

// A float written to an rgba16Float render target: Apple GPUs round toward zero there (a plain half conversion rounds to
// nearest), measured in FilmLookRenderTests. Steps one ulp back towards zero when the conversion rounded away.
float targetHalf(float x) {
    uint h = f32tof16(x);
    if (!isinf(x) && !isnan(x) && abs(f16tof32(h)) > abs(x)) { h -= 1u; }
    return f16tof32(h);
}

[shader("vertex")]
VOut compositeVertex(uint vid : SV_VertexID) {
    CompositeU u = cu;
    float2 uv = float2(float(vid & 1u), float(vid >> 1u));
    float2 local = (uv - 0.5f) * u.size;
    if (edgeAA(u)) { local += (uv * 2.0f - 1.0f) * (1.0f / max(u.scale, 1e-4f)); }
    float2 p = (local - u.anchor) * u.scale;
    float2 r = float2(u.rotCos * p.x - u.rotSin * p.y, u.rotSin * p.x + u.rotCos * p.y);
    float w = 1.0f;
    if (u.tilt.z > 0.0f) {
        // Perspective tilt (mirrors PerspectiveTilt.project): turn about X then Y, project from u.tilt.z px away.
        float ca = cos(u.tilt.x), sa = sin(u.tilt.x), cb = cos(u.tilt.y), sb = sin(u.tilt.y);
        float y1 = r.y * ca, z1 = -r.y * sa;
        float z2 = r.x * sb + z1 * cb;
        w = max((u.tilt.z + z2) / u.tilt.z, 1e-3f);
        r = float2(r.x * cb - z1 * sb, y1) / w;
    }
    float2 px = u.canvas * 0.5f + u.position + r;
    VOut o;
    // w only feeds perspective-correct interpolation of `local`: the position is already divided, so scale it back up.
    o.position = float4(float2(px.x / u.canvas.x * 2.0f - 1.0f, 1.0f - px.y / u.canvas.y * 2.0f) * w, 0.0f, w);
    o.local = local;
    return o;
}
