#ifndef BrushPixels_h
#define BrushPixels_h
#include <stdint.h>
#include <stddef.h>
// Undithered round-tip coverage, shared with the Metal falloff.
void brush_soft_tip(uint8_t *bytes, size_t size, size_t stride, double hardness, double exponent);
// Half-open bounds of nonzero alpha in premultiplied RGBA. Empty returns all zero.
void brush_alpha_bounds(const uint8_t *bytes, size_t width, size_t height, size_t stride, size_t bounds[4]);
void layer_extract_alpha(const uint8_t *rgba, size_t rgbaStride, uint8_t *gray, size_t grayStride, size_t width, size_t height);
void layer_unpremultiply_opaque(uint8_t *rgba, size_t stride, size_t width, size_t height);
void layer_restore_alpha(uint8_t *rgba, size_t stride, const uint8_t *alpha, size_t alphaStride, size_t width, size_t height);
#endif
