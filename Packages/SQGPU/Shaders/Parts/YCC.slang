// Rec.709 Y'CbCr split and join of the denoise kernels (TemporalDenoise, SpatialDenoise).

float3 toYCC(float3 c) {
    float y = dot(c, float3(0.2126f, 0.7152f, 0.0722f));
    return float3(y, (c.b - y) / 1.8556f, (c.r - y) / 1.5748f);
}
float3 fromYCC(float3 v) {
    float r = v.x + 1.5748f * v.z, b = v.x + 1.8556f * v.y;
    float g = (v.x - 0.2126f * r - 0.0722f * b) / 0.7152f;
    return float3(r, g, b);
}
