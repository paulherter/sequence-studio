// Source transfer functions and map3 (was ColorShaderSource.transferMSL in SQRender; mirrors TransferFunctions.swift):
// decode 0...9 and 20...26, encode +10; the index is ColorPipelineGPU.shaderIndex. Included by modules that convert
// source frames (Parts/Convert.slang) or grade.

static const float kSlog3CutEncoded = 171.2102946929f / 1023.0f;
static const float kSlog3CutLinear = 0.01125f;

float slog3Decode(float x) {
    if (x >= kSlog3CutEncoded) { return pow(10.0f, (x * 1023.0f - 420.0f) / 261.5f) * (0.18f + 0.01f) - 0.01f; }
    return (x * 1023.0f - 95.0f) * 0.01125f / (171.2102946929f - 95.0f);
}
float slog3Encode(float y) {
    if (y >= kSlog3CutLinear) { return (420.0f + log10((y + 0.01f) / (0.18f + 0.01f)) * 261.5f) / 1023.0f; }
    return (y * (171.2102946929f - 95.0f) / 0.01125f + 95.0f) / 1023.0f;
}
float slog3DecodeLegal(float v) { return slog3Decode((v * 876.0f + 64.0f) / 1023.0f); }
float slog3EncodeLegal(float y) { return (slog3Encode(y) * 1023.0f - 64.0f) / 876.0f; }

static const float kHlgA = 0.17883277f;
static const float kHlgB = 0.28466892f;
static const float kHlgC = 0.55991073f;
static const float kHlgGamma = 1.2f;
static const float3 kHlgLuma = float3(0.2627f, 0.6780f, 0.0593f);

float hlgInverseOETF(float e) {
    e = max(e, 0.0f);
    if (e <= 0.5f) { return e * e / 3.0f; }
    return (exp((e - kHlgC) / kHlgA) + kHlgB) / 12.0f;
}
float hlgOETF(float s) {
    s = max(s, 0.0f);
    if (s <= 1.0f / 12.0f) { return sqrt(3.0f * s); }
    return kHlgA * log(12.0f * s - kHlgB) + kHlgC;
}
// Non-separable HLG OOTF (TransferFunctions.hlgDecode / hlgEncode). Scale is derived: 1 / E75^gamma.
float hlgScale() {
    float e = hlgInverseOETF(0.75f);
    return 1.0f / (e * pow(e, kHlgGamma - 1.0f));
}
float3 hlgDecode3(float3 v) {
    float3 e = float3(hlgInverseOETF(v.x), hlgInverseOETF(v.y), hlgInverseOETF(v.z));
    float ys = dot(kHlgLuma, e);
    float gain = ys > 0.0f ? pow(ys, kHlgGamma - 1.0f) : 0.0f;
    return e * gain * hlgScale();
}
float3 hlgEncode3(float3 v) {
    float3 fd = v / hlgScale();
    float yd = dot(kHlgLuma, fd);
    if (!(yd > 0.0f)) { return float3(hlgOETF(0.0f)); }
    float ys = pow(yd, 1.0f / kHlgGamma);
    float3 e = fd / pow(ys, kHlgGamma - 1.0f);
    return float3(hlgOETF(e.x), hlgOETF(e.y), hlgOETF(e.z));
}

static const float kTfBt709Alpha = 1.09929682680944f;
static const float kTfBt709Beta = 0.018053968510807f;

float tfBt709OETF(float l) {
    if (l < kTfBt709Beta) { return 4.5f * l; }
    return kTfBt709Alpha * pow(l, 0.45f) - (kTfBt709Alpha - 1.0f);
}
float tfBt709InverseOETF(float v) {
    if (v < 4.5f * kTfBt709Beta) { return v / 4.5f; }
    return pow((v + kTfBt709Alpha - 1.0f) / kTfBt709Alpha, 1.0f / 0.45f);
}

// V-Log, D-Log: CV/1023 code fractions like S-Log3. Apple Log, PQ: the range-expanded value is the signal.
static const float kVlogB = 0.00873f, kVlogC = 0.241514f, kVlogD = 0.598206f;
float vlogDecode(float x) { return x < 0.181f ? (x - 0.125f) / 5.6f : pow(10.0f, (x - kVlogD) / kVlogC) - kVlogB; }
float vlogEncode(float y) { return y < 0.01f ? 5.6f * y + 0.125f : kVlogC * log10(y + kVlogB) + kVlogD; }
float vlogDecodeLegal(float v) { return vlogDecode((v * 876.0f + 64.0f) / 1023.0f); }
float vlogEncodeLegal(float y) { return (vlogEncode(y) * 1023.0f - 64.0f) / 876.0f; }

float dlogDecode(float x) { return x <= 0.14f ? (x - 0.0929f) / 6.025f : (pow(10.0f, 3.89616f * x - 2.27752f) - 0.0108f) / 0.9892f; }
float dlogEncode(float y) { return y <= 0.0078f ? 6.025f * y + 0.0929f : log10(y * 0.9892f + 0.0108f) * 0.256663f + 0.584555f; }
float dlogDecodeLegal(float v) { return dlogDecode((v * 876.0f + 64.0f) / 1023.0f); }
float dlogEncodeLegal(float y) { return (dlogEncode(y) * 1023.0f - 64.0f) / 876.0f; }

// Canon Log, Canon Log 2, Canon Log 3 (TransferFunctions.canonLog*): CV/1023 code fractions, linear = reflection / 0.9.
float canonMirroredDecode(float x, float a, float k, float c) {
    return (x < c ? -(pow(10.0f, (c - x) / a) - 1.0f) / k : (pow(10.0f, (x - c) / a) - 1.0f) / k) * 0.9f;
}
float canonMirroredEncode(float y, float a, float k, float c) {
    float l = y / 0.9f;
    return l < 0.0f ? -(a * log10(-l * k + 1.0f) - c) : a * log10(l * k + 1.0f) + c;
}
float canonLogDecodeLegal(float v) { return canonMirroredDecode((v * 876.0f + 64.0f) / 1023.0f, 0.45310179f, 10.1596f, 0.12512248f); }
float canonLogEncodeLegal(float y) { return (canonMirroredEncode(y, 0.45310179f, 10.1596f, 0.12512248f) * 1023.0f - 64.0f) / 876.0f; }
float canonLog2DecodeLegal(float v) { return canonMirroredDecode((v * 876.0f + 64.0f) / 1023.0f, 0.24136077f, 87.09937546f, 0.092864125f); }
float canonLog2EncodeLegal(float y) { return (canonMirroredEncode(y, 0.24136077f, 87.09937546f, 0.092864125f) * 1023.0f - 64.0f) / 876.0f; }
static const float kCanon3A = 0.36726845f, kCanon3K = 14.98325f;
float canonLog3Decode(float x) {
    float l;
    if (x < 0.097465473f) { l = -(pow(10.0f, (0.12783901f - x) / kCanon3A) - 1.0f) / kCanon3K; }
    else if (x <= 0.15277891f) { l = (x - 0.12512219f) / 1.9754798f; }
    else { l = (pow(10.0f, (x - 0.12240537f) / kCanon3A) - 1.0f) / kCanon3K; }
    return l * 0.9f;
}
float canonLog3Encode(float y) {
    float l = y / 0.9f;
    if (l < -0.014f) { return -kCanon3A * log10(-l * kCanon3K + 1.0f) + 0.12783901f; }
    if (l <= 0.014f) { return 1.9754798f * l + 0.12512219f; }
    return kCanon3A * log10(l * kCanon3K + 1.0f) + 0.12240537f;
}
float canonLog3DecodeLegal(float v) { return canonLog3Decode((v * 876.0f + 64.0f) / 1023.0f); }
float canonLog3EncodeLegal(float y) { return (canonLog3Encode(y) * 1023.0f - 64.0f) / 876.0f; }

static const float kAppleR0 = -0.05641088f, kAppleRt = 0.01f, kAppleC = 47.28711236f;
static const float kAppleBeta = 0.00964052f, kAppleGamma = 0.08550479f, kAppleDelta = 0.69336945f;
float appleLogDecode(float p) {
    float pt = kAppleC * (kAppleRt - kAppleR0) * (kAppleRt - kAppleR0);
    if (p >= pt) { return pow(2.0f, (p - kAppleDelta) / kAppleGamma) - kAppleBeta; }
    if (p >= 0.0f) { return sqrt(p / kAppleC) + kAppleR0; }
    return kAppleR0;
}
float appleLogEncode(float x) {
    if (x >= kAppleRt) { return kAppleGamma * log2(x + kAppleBeta) + kAppleDelta; }
    if (x >= kAppleR0) { return kAppleC * (x - kAppleR0) * (x - kAppleR0); }
    return 0.0f;
}

static const float kPqM1 = 2610.0f / 16384.0f, kPqM2 = 2523.0f / 4096.0f * 128.0f;
static const float kPqC1 = 3424.0f / 4096.0f, kPqC2 = 2413.0f / 4096.0f * 32.0f, kPqC3 = 2392.0f / 4096.0f * 32.0f;
static const float kPqRefWhite = 203.0f;
float pqDecode(float e) {
    float p = pow(max(e, 0.0f), 1.0f / kPqM2);
    float y = pow(max(p - kPqC1, 0.0f) / (kPqC2 - kPqC3 * p), 1.0f / kPqM1);
    return y * 10000.0f / kPqRefWhite;
}
float pqEncode(float l) {
    float y = pow(max(l, 0.0f) * kPqRefWhite / 10000.0f, kPqM1);
    return pow((kPqC1 + kPqC2 * y) / (1.0f + kPqC3 * y), kPqM2);
}

// Vendor logs (TransferFunctions+Vendor.swift): ARRI LogC3 / LogC4, RED Log3G10, Blackmagic Film Gen 5, Nikon N-Log,
// Fujifilm F-Log2, ACEScct. The LogC4 constants are TransferFunctions.logC4A...logC4T rounded to Float.
float legalToCode(float v) { return (v * 876.0f + 64.0f) / 1023.0f; }
float codeToLegal(float x) { return (x * 1023.0f - 64.0f) / 876.0f; }
float logC3Decode(float x) { return x > 5.367655f * 0.010591f + 0.092809f ? (pow(10.0f, (x - 0.385537f) / 0.247190f) - 0.052272f) / 5.555556f : (x - 0.092809f) / 5.367655f; }
float logC3Encode(float y) { return y > 0.010591f ? 0.247190f * log10(5.555556f * y + 0.052272f) + 0.385537f : 5.367655f * y + 0.092809f; }
static const float kC4A = 2231.826416015625f, kC4B = 0.9071359038352966f, kC4C = 0.09286412596702576f;
static const float kC4S = 0.11359720677137375f, kC4T = -0.018056996166706085f;
float logC4Decode(float x) { return x >= 0.0f ? (pow(2.0f, 14.0f * (x - kC4C) / kC4B + 6.0f) - 64.0f) / kC4A : x * kC4S + kC4T; }
float logC4Encode(float y) { return y >= kC4T ? (log2(kC4A * y + 64.0f) - 6.0f) / 14.0f * kC4B + kC4C : (y - kC4T) / kC4S; }
float log3G10Decode(float y) { return y < 0.0f ? y / 15.1927f - 0.01f : (pow(10.0f, y / 0.224282f) - 1.0f) / 155.975327f - 0.01f; }
float log3G10Encode(float x) { float s = x + 0.01f; return s < 0.0f ? s * 15.1927f : 0.224282f * log10(s * 155.975327f + 1.0f); }
float bmdDecode(float y) { return y < 8.283605932402494f * 0.005f + 0.09246575342465753f ? (y - 0.09246575342465753f) / 8.283605932402494f : exp((y - 0.5300133392291939f) / 0.08692876065491224f) - 0.005494072432257808f; }
float bmdEncode(float x) { return x < 0.005f ? 8.283605932402494f * x + 0.09246575342465753f : 0.08692876065491224f * log(x + 0.005494072432257808f) + 0.5300133392291939f; }
float nLogDecode(float x) {
    float cv = x * 1023.0f;
    if (cv < 150.0f * log(0.328f) + 619.0f) { float t = cv / 650.0f; return t * t * t - 0.0075f; }
    return exp((cv - 619.0f) / 150.0f);
}
float nLogEncode(float y) { return y < 0.328f ? 650.0f * pow(max(y + 0.0075f, 0.0f), 1.0f / 3.0f) / 1023.0f : (150.0f * log(y) + 619.0f) / 1023.0f; }
float fLog2Decode(float x) { return x >= 0.100686685370811f ? (pow(10.0f, (x - 0.384316f) / 0.245281f) - 0.064829f) / 5.555556f : (x - 0.092864f) / 8.799461f; }
float fLog2Encode(float y) { return y >= 0.000889f ? 0.245281f * log10(5.555556f * y + 0.064829f) + 0.384316f : 8.799461f * y + 0.092864f; }
float acesCCTDecode(float y) { return y <= 0.155251141552511f ? (y - 0.0729055341958355f) / 10.5402377416545f : pow(2.0f, y * 17.52f - 9.72f); }
float acesCCTEncode(float x) { return x <= 0.0078125f ? 10.5402377416545f * x + 0.0729055341958355f : (log2(x) + 9.72f) / 17.52f; }

float3 map3(float3 v, int fn) {
    switch (fn) {
    case 0: return float3(slog3DecodeLegal(v.x), slog3DecodeLegal(v.y), slog3DecodeLegal(v.z));
    case 1: return hlgDecode3(v);
    case 2: return float3(tfBt709InverseOETF(v.x), tfBt709InverseOETF(v.y), tfBt709InverseOETF(v.z));
    case 3: return float3(vlogDecodeLegal(v.x), vlogDecodeLegal(v.y), vlogDecodeLegal(v.z));
    case 4: return float3(appleLogDecode(v.x), appleLogDecode(v.y), appleLogDecode(v.z));
    case 5: return float3(pqDecode(v.x), pqDecode(v.y), pqDecode(v.z));
    case 6: return float3(dlogDecodeLegal(v.x), dlogDecodeLegal(v.y), dlogDecodeLegal(v.z));
    case 7: return float3(canonLogDecodeLegal(v.x), canonLogDecodeLegal(v.y), canonLogDecodeLegal(v.z));
    case 8: return float3(canonLog2DecodeLegal(v.x), canonLog2DecodeLegal(v.y), canonLog2DecodeLegal(v.z));
    case 9: return float3(canonLog3DecodeLegal(v.x), canonLog3DecodeLegal(v.y), canonLog3DecodeLegal(v.z));
    case 10: return float3(slog3EncodeLegal(v.x), slog3EncodeLegal(v.y), slog3EncodeLegal(v.z));
    case 11: return hlgEncode3(v);
    case 12: return float3(tfBt709OETF(v.x), tfBt709OETF(v.y), tfBt709OETF(v.z));
    case 13: return float3(vlogEncodeLegal(v.x), vlogEncodeLegal(v.y), vlogEncodeLegal(v.z));
    case 14: return float3(appleLogEncode(v.x), appleLogEncode(v.y), appleLogEncode(v.z));
    case 15: return float3(pqEncode(v.x), pqEncode(v.y), pqEncode(v.z));
    case 16: return float3(dlogEncodeLegal(v.x), dlogEncodeLegal(v.y), dlogEncodeLegal(v.z));
    case 17: return float3(canonLogEncodeLegal(v.x), canonLogEncodeLegal(v.y), canonLogEncodeLegal(v.z));
    case 18: return float3(canonLog2EncodeLegal(v.x), canonLog2EncodeLegal(v.y), canonLog2EncodeLegal(v.z));
    case 19: return float3(canonLog3EncodeLegal(v.x), canonLog3EncodeLegal(v.y), canonLog3EncodeLegal(v.z));
    case 20: return float3(logC3Decode(legalToCode(v.x)), logC3Decode(legalToCode(v.y)), logC3Decode(legalToCode(v.z)));
    case 21: return float3(logC4Decode(legalToCode(v.x)), logC4Decode(legalToCode(v.y)), logC4Decode(legalToCode(v.z)));
    case 22: return float3(log3G10Decode(v.x), log3G10Decode(v.y), log3G10Decode(v.z));
    case 23: return float3(bmdDecode(legalToCode(v.x)), bmdDecode(legalToCode(v.y)), bmdDecode(legalToCode(v.z)));
    case 24: return float3(nLogDecode(legalToCode(v.x)), nLogDecode(legalToCode(v.y)), nLogDecode(legalToCode(v.z)));
    case 25: return float3(fLog2Decode(legalToCode(v.x)), fLog2Decode(legalToCode(v.y)), fLog2Decode(legalToCode(v.z)));
    case 26: return float3(acesCCTDecode(v.x), acesCCTDecode(v.y), acesCCTDecode(v.z));
    case 30: return float3(codeToLegal(logC3Encode(v.x)), codeToLegal(logC3Encode(v.y)), codeToLegal(logC3Encode(v.z)));
    case 31: return float3(codeToLegal(logC4Encode(v.x)), codeToLegal(logC4Encode(v.y)), codeToLegal(logC4Encode(v.z)));
    case 32: return float3(log3G10Encode(v.x), log3G10Encode(v.y), log3G10Encode(v.z));
    case 33: return float3(codeToLegal(bmdEncode(v.x)), codeToLegal(bmdEncode(v.y)), codeToLegal(bmdEncode(v.z)));
    case 34: return float3(codeToLegal(nLogEncode(v.x)), codeToLegal(nLogEncode(v.y)), codeToLegal(nLogEncode(v.z)));
    case 35: return float3(codeToLegal(fLog2Encode(v.x)), codeToLegal(fLog2Encode(v.y)), codeToLegal(fLog2Encode(v.z)));
    case 36: return float3(acesCCTEncode(v.x), acesCCTEncode(v.y), acesCCTEncode(v.z));
    default: return v;
    }
}
