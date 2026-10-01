#include "BrushPixels.h"
#include <math.h>

void brush_soft_tip(uint8_t *bytes, size_t size, size_t stride, double hardness, double exponent) {
    float radius = (float)size / 2, h = (float)hardness, k = (float)exponent;
    float edge = expf(-k), scale = 255 / (1 - edge);
    for (size_t y = 0; y < size; ++y) {
        float dy = (float)y + 0.5f - radius;
        for (size_t x = 0; x < size; ++x) {
            float dx = (float)x + 0.5f - radius;
            float u = fminf(1, fmaxf(0, (sqrtf(dx * dx + dy * dy) / radius - h) / (1 - h)));
            bytes[y * stride + x] = (uint8_t)lroundf(fmaxf(0, (expf(-k * u) - edge) * scale));
        }
    }
}

void brush_alpha_bounds(const uint8_t *bytes, size_t width, size_t height, size_t stride, size_t bounds[4]) {
    size_t left = width, right = 0, top = height, bottom = 0;
    for (size_t y = 0; y < height; ++y) {
        const uint8_t *row = bytes + y * stride;
        size_t first = 0;
        while (first < width && row[first * 4 + 3] == 0) ++first;
        if (first == width) continue;
        size_t last = width;
        while (last > first && row[(last - 1) * 4 + 3] == 0) --last;
        if (first < left) left = first;
        if (last > right) right = last;
        if (y < top) top = y;
        bottom = y + 1;
    }
    bounds[0] = right ? left : 0;
    bounds[1] = right ? top : 0;
    bounds[2] = right;
    bounds[3] = bottom;
}

void layer_unpremultiply_opaque(uint8_t *rgba, size_t stride, size_t width, size_t height) {
    for (size_t y = 0; y < height; ++y) {
        uint8_t *p = rgba + y * stride;
        for (size_t x = 0; x < width; ++x, p += 4) {
            unsigned a = p[3];
            for (int c = 0; c < 3; ++c) {
                unsigned v = a ? (p[c] * 255u + a / 2) / a : 0;
                p[c] = v > 255 ? 255 : v;
            }
            p[3] = 255;
        }
    }
}
void layer_restore_alpha(uint8_t *rgba, size_t stride, const uint8_t *alpha, size_t alphaStride, size_t width, size_t height) {
    for (size_t y = 0; y < height; ++y) {
        uint8_t *p = rgba + y * stride;
        for (size_t x = 0; x < width; ++x, p += 4) {
            unsigned a = alpha[y * alphaStride + x];
            for (int c = 0; c < 3; ++c) p[c] = (p[c] * a + 127) / 255;
            p[3] = a;
        }
    }
}
void layer_extract_alpha(const uint8_t *rgba, size_t rgbaStride, uint8_t *gray, size_t grayStride, size_t width, size_t height) {
    for (size_t y = 0; y < height; ++y)
        for (size_t x = 0; x < width; ++x)
            gray[y * grayStride + x] = rgba[y * rgbaStride + x * 4 + 3];
}
