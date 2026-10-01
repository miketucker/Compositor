import CoreGraphics
import Foundation
import Metal

/// Shared pipeline, with stroke-local tile storage. No full-canvas GPU allocation.
final class MetalBrushCoverage {
    static let shared: MetalBrushCoverage? = try? MetalBrushCoverage()
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState

    struct Tile {
        let permanent: MTLBuffer
        let preview: MTLBuffer
    }
    /// A straight piece of a stroke, in document pixels, and the tip's radius and strength at either end, which differ
    /// where the Pencil's pressure changed along it. Laid out as the shader's `BrushSegment`.
    struct Segment {
        var ends: SIMD4<Float>
        var dynamics: SIMD4<Float>
    }
    private struct Uniforms {
        var mapping: SIMD4<Float>
        var geometry: SIMD4<Float>
        var canvas: SIMD4<Float>
        var counts: SIMD4<UInt32>
        var ink: SIMD4<UInt32>
    }
    private init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let function = try device.makeLibrary(source: Self.source, options: nil).makeFunction(name: "continuousBrush") else { throw ExportError.render }
        self.device = device
        self.queue = queue
        pipeline = try device.makeComputePipelineState(function: function)
    }
    func tile(width: Int, height: Int) throws -> Tile {
        guard let permanent = device.makeBuffer(length: width * height * MemoryLayout<Float>.stride, options: .storageModeShared),
              let preview = device.makeBuffer(length: width * height, options: .storageModeShared) else { throw ExportError.render }
        memset(permanent.contents(), 0, width * height * MemoryLayout<Float>.stride)
        return Tile(permanent: permanent, preview: preview)
    }
    func render(_ tiles: [(Tile, CGRect, CGContext)], settled: [Segment], tail: [Segment],
                mapping: CGAffineTransform, settings: BrushSettings, canvas: CGSize) throws {
        guard !tiles.isEmpty else { return }
        // A dummy segment supplies a valid buffer for tail removal with no new geometry.
        let segments = settled + tail
        let storage = segments.isEmpty ? [Segment(ends: .zero, dynamics: .zero)] : segments
        guard let buffer = storage.withUnsafeBytes({ bytes in
            device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
        }), let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else { throw ExportError.render }
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(buffer, offset: 0, index: 3)
        let pattern = settings.patternInk
        for (tile, rect, _) in tiles {
            let origin = rect.origin.applying(mapping)
            var uniforms = Uniforms(
                mapping: SIMD4(Float(mapping.a), Float(mapping.b), Float(mapping.c), Float(mapping.d)),
                geometry: SIMD4(Float(origin.x), Float(origin.y), Float(settings.diameter / 2), Float(settings.hardness)),
                canvas: SIMD4(Float(canvas.width), Float(canvas.height), Float(max(0.001, min(hypot(mapping.a, mapping.b), hypot(mapping.c, mapping.d)))), Float(max(0.25, settings.diameter * BrushStroke.spacingFraction(settings.hardness)))),
                counts: SIMD4(UInt32(rect.width), UInt32(rect.height), UInt32(settled.count), UInt32(segments.count)),
                ink: SIMD4(pattern == nil ? 0 : 1, pattern?.colors == .foregroundToBackground ? 1 : 0, 0, 0))
            encoder.setBuffer(tile.permanent, offset: 0, index: 0)
            encoder.setBuffer(tile.preview, offset: 0, index: 1)
            encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 2)
            encoder.dispatchThreads(MTLSize(width: Int(rect.width), height: Int(rect.height), depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        }
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { throw command.error ?? ExportError.render }
        for (tile, rect, context) in tiles {
            // CGContext owns its memory so makeImage's copy-on-write snapshots stay immutable.
            guard let destination = context.data else { throw ExportError.render }
            memcpy(destination, tile.preview.contents(), Int(rect.width * rect.height))
        }
    }

    // Compile once with the system Metal compiler; no optional Xcode Metal toolchain required.
    private static let source = """
#include <metal_stdlib>
using namespace metal;

struct BrushUniforms {
    float4 mapping; // a, b, c, d
    float4 geometry; // document origin of tile, radius as set, hardness
    float4 canvas; // width, height, antialias width, deposition spacing at the radius as set
    uint4 counts; // tile width, height, committed segment count, total segment count
    uint4 ink; // a pattern brush, and whether its latest segment wins over earlier ones rather than the densest
};

struct BrushSegment {
    float4 ends; // x0, y0, x1, y1
    float4 dynamics; // radius at either end, then strength at either end: the Pencil's pressure
};

float brushCoverage(float distanceSquared, float radius, constant BrushUniforms &u) {
    float distance = sqrt(distanceSquared);
    if (u.geometry.w >= 1.0f) {
        return clamp((radius - distance) / u.canvas.z + 0.5f, 0.0f, 1.0f);
    }
    float t = clamp((distance / radius - u.geometry.w) / (1.0f - u.geometry.w), 0.0f, 1.0f);
    constexpr float k = \(Float(BrushRaster.falloffExponent))f;
    return max(0.0f, (exp(-k * t) - exp(-k)) / (1.0f - exp(-k)));
}

// A hard tip's coverage from one segment: the radius and strength where p is nearest along it.
float segmentCoverage(float2 p, BrushSegment segment, constant BrushUniforms &u) {
    float2 v = segment.ends.zw - segment.ends.xy;
    float t = clamp(dot(p - segment.ends.xy, v) / max(dot(v, v), 1e-12f), 0.0f, 1.0f);
    float2 delta = p - (segment.ends.xy + t * v);
    float radius = mix(segment.dynamics.x, segment.dynamics.y, t);
    return mix(segment.dynamics.z, segment.dynamics.w, t) * brushCoverage(dot(delta, delta), radius, u);
}

// A pattern brush's tip on one segment, which has no soft or antialiased edge: 1 + the density where p is nearest along
// it, for pixels whose centers the tip reaches, and 0 for the rest.
float segmentPattern(float2 p, BrushSegment segment) {
    float2 v = segment.ends.zw - segment.ends.xy;
    float t = clamp(dot(p - segment.ends.xy, v) / max(dot(v, v), 1e-12f), 0.0f, 1.0f);
    float2 delta = p - (segment.ends.xy + t * v);
    float radius = mix(segment.dynamics.x, segment.dynamics.y, t);
    return dot(delta, delta) <= radius * radius ? 1.0f + mix(segment.dynamics.z, segment.dynamics.w, t) : 0.0f;
}

// Integrate paint deposition by distance travelled, not pointer-event count or
// spline subdivision count. Optical density adds; coverage is 1 - exp(-density).
// This is the continuous form of source-over soft dabs at the shared deposition spacing.
float tipDensity(float distanceSquared, float radius, float strength, constant BrushUniforms &u) {
    return -log(max(1.0f - strength * brushCoverage(distanceSquared, radius, u), 0.001f));
}

float segmentDensity(float2 p, BrushSegment segment, constant BrushUniforms &u) {
    float2 v = segment.ends.zw - segment.ends.xy;
    float length = metal::length(v);
    if (length < 1e-6f) { // a dab where the stroke starts
        float2 offset = p - segment.ends.xy;
        return tipDensity(dot(offset, offset), segment.dynamics.x, segment.dynamics.z, u);
    }
    float2 direction = v / length;
    float projection = dot(p - segment.ends.xy, direction);
    float2 perpendicular = p - segment.ends.xy - projection * direction;
    float perpendicularSquared = dot(perpendicular, perpendicular);
    float widest = max(segment.dynamics.x, segment.dynamics.y);
    float radiusSquared = widest * widest;
    if (perpendicularSquared >= radiusSquared) return 0.0f;
    float reach = sqrt(radiusSquared - perpendicularSquared);
    float lo = max(0.0f, projection - reach), hi = min(length, projection + reach);
    if (hi <= lo) return 0.0f;
    float midpoint = (lo + hi) * 0.5f, halfLength = (hi - lo) * 0.5f;
    // Eight-point Gauss-Legendre quadrature, clipped to the tip's support.
    // Long sparse events and short dense events produce the same paint coverage.
    constexpr float nodes[4] = {0.1834346425f, 0.5255324099f, 0.7966664774f, 0.9602898565f};
    constexpr float weights[4] = {0.3626837834f, 0.3137066459f, 0.2223810345f, 0.1012285363f};
    float integral = 0.0f;
    for (uint i = 0; i < 4; ++i) {
        float x[2] = {midpoint - halfLength * nodes[i], midpoint + halfLength * nodes[i]};
        for (uint j = 0; j < 2; ++j) {
            float a = x[j] - projection, t = x[j] / length;
            float radius = mix(segment.dynamics.x, segment.dynamics.y, t);
            // Dabs are spaced by the tip's size, so a smaller tip lays them closer: weighted by the spacing at the
            // radius as set over the spacing here, which is 1 while the radius is as set.
            float spacing = max(0.25f, u.canvas.w * (radius / u.geometry.z));
            integral += weights[i] * tipDensity(perpendicularSquared + a * a, radius,
                                                mix(segment.dynamics.z, segment.dynamics.w, t), u) * (u.canvas.w / spacing);
        }
    }
    return integral * halfLength / u.canvas.w;
}

// Permanent paint and the replaceable tail are separate. Tail previews are never
// accumulated into permanent paint, including at self-intersections.
kernel void continuousBrush(device float *permanent [[buffer(0)]],
                            device uchar *preview [[buffer(1)]],
                            constant BrushUniforms &u [[buffer(2)]],
                            device const BrushSegment *segments [[buffer(3)]],
                            uint2 pixel [[thread_position_in_grid]]) {
    if (pixel.x >= u.counts.x || pixel.y >= u.counts.y) return;
    uint index = pixel.y * u.counts.x + pixel.x;
    float2 local = float2(pixel) + 0.5f;
    float2 p = u.geometry.xy + local.x * u.mapping.xy + local.y * u.mapping.zw;
    if (any(p < 0.0f) || any(p >= u.canvas.xy)) { preview[index] = 0; return; }
    if (u.ink.x != 0) {
        // A pattern brush keeps the density laid at each pixel it reaches, as 1 + density so 0 is outside: the
        // densest, or the latest, as the brush paints its gaps or not. The pattern itself is applied as the tile is
        // painted.
        bool latest = u.ink.y != 0;
        float value = permanent[index], tail = 0.0f;
        for (uint i = 0; i < u.counts.z; ++i) {
            float here = segmentPattern(p, segments[i]);
            if (here > 0.0f) value = latest ? here : max(value, here);
        }
        for (uint i = u.counts.z; i < u.counts.w; ++i) {
            float here = segmentPattern(p, segments[i]);
            if (here > 0.0f) tail = latest ? here : max(tail, here);
        }
        permanent[index] = value;
        float shown = tail > 0.0f && (latest || tail > value) ? tail : value;
        preview[index] = shown > 0.0f ? uchar(1.0f + round(254.0f * clamp(shown - 1.0f, 0.0f, 1.0f))) : 0;
        return;
    }
    if (u.geometry.w >= 1.0f) {
        // Hard tips already have a solid interior. Preserve pixel-edge antialiasing.
        float settled = 0.0f, tail = 0.0f;
        for (uint i = 0; i < u.counts.z; ++i) settled = max(settled, segmentCoverage(p, segments[i], u));
        for (uint i = u.counts.z; i < u.counts.w; ++i) tail = max(tail, segmentCoverage(p, segments[i], u));
        float value = max(permanent[index], settled);
        permanent[index] = value;
        preview[index] = uchar(round(255.0f * max(value, tail)));
    } else {
        float value = permanent[index], tail = 0.0f;
        for (uint i = 0; i < u.counts.z; ++i) value += segmentDensity(p, segments[i], u);
        for (uint i = u.counts.z; i < u.counts.w; ++i) tail += segmentDensity(p, segments[i], u);
        permanent[index] = min(value, 20.0f);
        preview[index] = uchar(round(255.0f * (1.0f - exp(-min(value + tail, 20.0f)))));
    }
}
"""
}
