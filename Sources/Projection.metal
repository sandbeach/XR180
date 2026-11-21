#include <metal_stdlib>
using namespace metal;

struct Params {
    float4 cameraX, cameraY, cameraZ;
    float4 optics; // tan half FOV x/y, lens FOV in radians, per-eye source aspect
    uint4 modes;   // projection, input layout, swap eyes, output layout
    uint4 options; // test pattern, flip vertically, quarter turns, reserved
};

struct Varying {
    float4 position [[position]];
    float2 uv;
};

vertex Varying fullscreen(uint id [[vertex_id]]) {
    float2 uv = float2((id << 1) & 2, id & 2);
    return {float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0, 1), uv};
}

fragment float4 project(Varying in [[stage_in]], constant Params &p [[buffer(0)]],
                        texture2d<float> source [[texture(0)]]) {
    constexpr sampler linear(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 screen = in.uv;
    uint eye = p.modes.w != 0 && screen.x >= 0.5 ? 1 : 0;
    if (p.modes.w != 0) screen.x = screen.x * 2.0 - float(eye);
    uint sourceEye = eye ^ p.modes.z;
    float2 centered = float2(2.0 * screen.x - 1.0, 1.0 - 2.0 * screen.y);
    float3 ray = normalize(float3(centered * p.optics.xy, 1.0));
    float3 direction = ray.x * p.cameraX.xyz + ray.y * p.cameraY.xyz + ray.z * p.cameraZ.xyz;
    float lon = atan2(direction.x, direction.z);
    float lat = asin(clamp(direction.y, -1.0, 1.0));
    constexpr float pi = M_PI_F;

    if (p.options.x != 0) {
        // The world grid responds to pose. The corner tags are unique to each eye.
        if (screen.y < 0.13 && (sourceEye == 0 ? screen.x < 0.15 : screen.x > 0.85)) {
            return sourceEye == 0 ? float4(0.15, 0.82, 0.93, 1) : float4(0.99, 0.61, 0.29, 1);
        }
        if (abs(lon) > pi * 0.5) return float4(0.015, 0.025, 0.038, 1);
        float2 cell = float2(lon, lat) / (pi / 12.0);
        float2 distance = abs(fract(cell + 0.5) - 0.5);
        float2 lines = 1.0 - smoothstep(float2(0.012), max(float2(0.03), fwidth(cell) * 1.15), distance);
        float crosshair = 1.0 - smoothstep(0.012, 0.022, min(abs(lon), abs(lat)));
        float shade = max(direction.z, 0.0);
        float3 base = mix(float3(0.035, 0.05, 0.08), float3(0.085, 0.15, 0.22), shade);
        float3 color = mix(base, float3(0.33, 0.55, 0.64), max(lines.x, lines.y) * 0.72);
        return float4(mix(color, float3(0.84, 0.93, 0.99), crosshair), 1);
    }

    float2 uv;
    if (p.modes.x == 3) {
        // Fit a flat stereo picture to a 16:9 eye viewport.
        float aspect = p.optics.w;
        float eyeAspect = p.optics.x / p.optics.y;
        uv = 0.5 + (screen - 0.5) * float2(max(1.0, eyeAspect / aspect),
                                             max(1.0, aspect / eyeAspect));
    } else if (p.modes.x == 0) {
        uv = float2(0.5 + lon / pi, 0.5 - lat / pi);
    } else {
        float theta = acos(clamp(direction.z, -1.0, 1.0));
        float halfLens = p.optics.z * 0.5;
        if (theta > halfLens) return float4(0, 0, 0, 1);
        float radius = p.modes.x == 1 ? theta / halfLens
                                      : sin(theta * 0.5) / sin(halfLens * 0.5);
        float2 radial = float2(direction.x, -direction.y);
        radial *= 0.5 * radius / max(length(radial), 1e-6);
        radial *= float2(min(1.0, 1.0 / p.optics.w), min(1.0, p.optics.w));
        uv = 0.5 + radial;
    }
    float2 q = uv - 0.5;
    switch (p.options.z) {
        case 1: q = float2(q.y, -q.x); break;
        case 2: q = -q; break;
        case 3: q = float2(-q.y, q.x); break;
        default: break;
    }
    uv = q + 0.5;
    if (p.options.y != 0) uv.y = 1.0 - uv.y;
    if (any(uv < 0.0) || any(uv > 1.0)) return float4(0, 0, 0, 1);

    // Clamp within the source eye, even at the center seam with linear filtering.
    float2 size = float2(source.get_width(), source.get_height());
    float2 origin = float2(0), extent = size;
    if (p.modes.y == 0) {
        extent.x = floor(size.x * 0.5);
        origin.x = extent.x * float(sourceEye);
    } else if (p.modes.y == 1) {
        extent.y = floor(size.y * 0.5);
        origin.y = extent.y * float(sourceEye);
    }
    float2 pixels = clamp(uv * extent, float2(0.5), max(float2(0.5), extent - 0.5));
    return float4(source.sample(linear, (origin + pixels) / size).rgb, 1.0);
}
