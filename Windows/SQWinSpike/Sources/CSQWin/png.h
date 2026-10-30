// Minimal PNG writer (stored deflate blocks), enough to inspect screenshots.
#pragma once
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint32_t sqCrc(uint32_t crc, const uint8_t *p, size_t n) {
    static uint32_t table[256];
    static int init = 0;
    if (!init) {
        for (uint32_t i = 0; i < 256; i++) {
            uint32_t c = i;
            for (int k = 0; k < 8; k++) c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
            table[i] = c;
        }
        init = 1;
    }
    crc = ~crc;
    for (size_t i = 0; i < n; i++) crc = table[(crc ^ p[i]) & 0xFF] ^ (crc >> 8);
    return ~crc;
}
static void sqBE(uint8_t *d, uint32_t v) { d[0] = v >> 24; d[1] = v >> 16; d[2] = v >> 8; d[3] = v; }
static void sqChunk(FILE *f, const char *type, const uint8_t *data, uint32_t n) {
    uint8_t b[4];
    sqBE(b, n); fwrite(b, 1, 4, f);
    fwrite(type, 1, 4, f);
    if (n) fwrite(data, 1, n, f);
    uint32_t c = sqCrc(0, (const uint8_t *)type, 4);
    if (n) c = sqCrc(c, data, n);
    sqBE(b, c); fwrite(b, 1, 4, f);
}
// rgb: width*height*3 bytes
static int sqWritePNG(const char *path, const uint8_t *rgb, int w, int h) {
    size_t rowLen = (size_t)w * 3 + 1, rawLen = rowLen * h;
    uint8_t *raw = (uint8_t *)malloc(rawLen);
    if (!raw) return 0;
    for (int y = 0; y < h; y++) { raw[y * rowLen] = 0; memcpy(raw + y * rowLen + 1, rgb + (size_t)y * w * 3, (size_t)w * 3); }
    size_t blocks = (rawLen + 65534) / 65535, zLen = 2 + rawLen + blocks * 5 + 4;
    uint8_t *z = (uint8_t *)malloc(zLen);
    if (!z) { free(raw); return 0; }
    size_t o = 0;
    z[o++] = 0x78; z[o++] = 0x01;
    for (size_t off = 0; off < rawLen; off += 65535) {
        size_t n = rawLen - off < 65535 ? rawLen - off : 65535;
        z[o++] = (off + n >= rawLen) ? 1 : 0;
        z[o++] = n & 0xFF; z[o++] = n >> 8; z[o++] = ~n & 0xFF; z[o++] = (~n >> 8) & 0xFF;
        memcpy(z + o, raw + off, n); o += n;
    }
    uint32_t a = 1, b = 0;
    for (size_t i = 0; i < rawLen; i++) { a = (a + raw[i]) % 65521; b = (b + a) % 65521; }
    sqBE(z + o, (b << 16) | a); o += 4;
    FILE *f = fopen(path, "wb");
    if (!f) { free(raw); free(z); return 0; }
    static const uint8_t sig[8] = {137, 80, 78, 71, 13, 10, 26, 10};
    fwrite(sig, 1, 8, f);
    uint8_t ihdr[13]; sqBE(ihdr, w); sqBE(ihdr + 4, h); ihdr[8] = 8; ihdr[9] = 2; ihdr[10] = ihdr[11] = ihdr[12] = 0;
    sqChunk(f, "IHDR", ihdr, 13);
    sqChunk(f, "IDAT", z, (uint32_t)o);
    sqChunk(f, "IEND", NULL, 0);
    fclose(f); free(raw); free(z);
    return 1;
}
