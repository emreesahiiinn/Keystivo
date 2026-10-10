import Foundation

/// GPU backgrounds, written in the Metal Shading Language and compiled at
/// runtime by the system's Metal driver (no build-time Metal toolchain needed).
nonisolated public enum ShaderEffect: String, CaseIterable, Sendable {
    case aurora, nebula, ocean, synthwave

    var fragmentFunction: String { "fx_\(rawValue)" }

    /// Soft effects render at reduced resolution and are upscaled; nobody can
    /// tell, and the GPU does a quarter of the work.
    var renderScale: CGFloat {
        switch self {
        case .aurora, .nebula: 0.5
        case .ocean: 0.75
        case .synthwave: 1
        }
    }
}

nonisolated enum ShaderSource {
    static let code = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct VOut { float4 position [[position]]; float2 uv; };
    struct Uniforms { float2 resolution; float time; float seed; };

    vertex VOut fx_vertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        VOut out;
        out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        out.uv = p;                       // (0,0) bottom-left, y up
        return out;
    }

    // MARK: Noise

    float hash21(float2 p) {
        p = fract(p * float2(233.34, 851.73));
        p += dot(p, p + 23.45);
        return fract(p.x * p.y);
    }

    float2 hash22(float2 p) {
        float n = hash21(p);
        return float2(n, hash21(p + n + 17.17));
    }

    float vnoise(float2 p) {
        float2 i = floor(p), f = fract(p);
        float2 u = f * f * (3.0 - 2.0 * f);
        float a = hash21(i), b = hash21(i + float2(1, 0));
        float c = hash21(i + float2(0, 1)), d = hash21(i + float2(1, 1));
        return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
    }

    float fbm(float2 p, int octaves) {
        float value = 0.0, amplitude = 0.5;
        const float2x2 rotate = float2x2(1.6, 1.2, -1.2, 1.6);
        for (int i = 0; i < octaves; i++) {
            value += amplitude * vnoise(p);
            p = rotate * p;
            amplitude *= 0.5;
        }
        return value;
    }

    // Sharp mountain ridges.
    float ridged(float2 p, int octaves) {
        float value = 0.0, amplitude = 0.5;
        const float2x2 rotate = float2x2(1.6, 1.2, -1.2, 1.6);
        for (int i = 0; i < octaves; i++) {
            value += amplitude * (1.0 - abs(vnoise(p) * 2.0 - 1.0));
            p = rotate * p;
            amplitude *= 0.5;
        }
        return value;
    }

    // Twinkling stars on a jittered grid. density: 0..1 fraction of lit cells.
    float stars(float2 p, float cells, float density, float time, float size) {
        float2 g = p * cells;
        float2 id = floor(g);
        float h = hash21(id);
        if (h > density) { return 0.0; }
        float2 center = 0.2 + 0.6 * hash22(id + 3.1);
        float d = length(fract(g) - center);
        float twinkle = 0.55 + 0.45 * sin(time * (0.6 + 2.5 * hash21(id + 7.7)) + h * 60.0);
        float brightness = 0.4 + 0.6 * hash21(id + 1.3);
        return smoothstep(size, 0.0, d) * twinkle * brightness;
    }

    float3 finish(float3 color, float2 uv, float2 resolution, float time, float vignette, float exposure) {
        float2 c = uv - 0.5;
        color *= 1.0 - vignette * dot(c, c) * 1.6;
        color = exposure > 0.0 ? 1.0 - exp(-color * exposure) : color / (1.0 + max(max(color.r, color.g), color.b) * 0.12); // soft tone mapping
        color += (hash21(uv * resolution + fract(time)) - 0.5) / 255.0;   // dither: no banding
        return color;
    }

    // MARK: Aurora — curtains over a starry sky and mountains

    fragment float4 fx_aurora(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
        float2 uv = in.uv;
        float aspect = u.resolution.x / u.resolution.y;
        float2 p = float2(uv.x * aspect, uv.y);
        float t = u.time;

        float3 color = mix(float3(0.035, 0.11, 0.14), float3(0.004, 0.008, 0.03), smoothstep(0.1, 0.85, uv.y));
        float starMask = smoothstep(0.25, 0.6, uv.y);
        color += float3(0.9, 0.95, 1.0) * stars(p, 120.0, 0.18, t, 0.1) * starMask;
        color += float3(0.75, 0.85, 1.0) * stars(p + 3.7, 260.0, 0.32, t, 0.13) * 0.45 * starMask;

        // Curtains: wavy lower edges, tall faint tops, fine vertical rays.
        float3 aurora = float3(0.0);
        for (int i = 0; i < 5; i++) {
            float fi = float(i);
            float x = p.x * (0.55 + fi * 0.09) + fi * 2.3;
            float drift = t * (0.022 + fi * 0.005);
            float wave = fbm(float2(x * 1.3 + drift, fi * 4.1 + t * 0.015), 5);
            float swirl = 0.06 * sin(x * 3.5 + t * 0.2 + fi * 1.7) + 0.03 * sin(x * 9.0 - t * 0.35);
            float base = 0.34 + 0.32 * wave + swirl + fi * 0.03;
            float d = uv.y - base;
            float curtain = smoothstep(-0.035, 0.015, d) * exp(-max(d, 0.0) * (2.0 + fi * 0.8));
            float rays = 0.25 + 1.0 * pow(fbm(float2(x * 40.0, t * 0.3 + fi * 9.0), 3), 1.5);
            float intensity = curtain * rays * (0.95 - fi * 0.13);
            float3 low = float3(0.2, 1.0, 0.52);
            float3 mid = float3(0.1, 0.85, 0.78);
            float3 high = mix(float3(0.6, 0.3, 1.0), float3(1.0, 0.32, 0.62), fi / 5.0);
            float3 c = mix(low, mid, smoothstep(0.0, 0.07, d));
            c = mix(c, high, smoothstep(0.08, 0.38, d));
            aurora += c * intensity;
        }
        color += aurora * 1.1;
        float glow = dot(aurora, float3(0.3, 0.6, 0.1));

        // Far peaks lit faintly by the aurora, then a dark forest ridge.
        float far = 0.2 + 0.15 * ridged(float2(p.x * 1.5 + 11.0, 2.0), 6);
        float farMask = smoothstep(far + 0.0015, far - 0.0015, uv.y);
        float3 rock = mix(float3(0.02, 0.04, 0.06), float3(0.06, 0.12, 0.14), smoothstep(far - 0.12, far, uv.y));
        color = mix(color, rock + glow * float3(0.1, 0.22, 0.18) * smoothstep(far - 0.06, far, uv.y), farMask);

        float ridge = 0.1 + 0.05 * fbm(float2(p.x * 2.2 + 3.0, 7.0), 5);
        float column = p.x * 85.0;
        float treeHeight = 0.012 + 0.03 * hash21(float2(floor(column), 3.0));
        float trees = ridge + treeHeight * max(0.0, 1.0 - abs(fract(column) * 2.0 - 1.0) * 1.15);
        float nearMask = smoothstep(trees + 0.0012, trees - 0.0012, uv.y);
        color = mix(color, float3(0.003, 0.006, 0.01), nearMask);
        // Mist drifting between the ranges.
        float mist = fbm(float2(p.x * 2.5 + t * 0.03, uv.y * 8.0), 4);
        color += float3(0.07, 0.16, 0.17) * smoothstep(0.09, 0.0, abs(uv.y - ridge - 0.04)) * mist * 0.5 * (1.0 - nearMask);
        return float4(finish(color, uv, u.resolution, t, 0.75, 1.35), 1.0);
    }

    // MARK: Nebula — domain-warped gas, dust lanes and parallax stars

    fragment float4 fx_nebula(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
        float2 uv = in.uv;
        float2 q = (uv - 0.5) * float2(u.resolution.x / u.resolution.y, 1.0);
        float t = u.time * 0.015;

        float2 w = float2(fbm(q * 1.5 + float2(t, -t * 0.7), 6), fbm(q * 1.5 + float2(5.2, 1.3) - t, 6));
        float2 w2 = float2(fbm(q * 2.2 + 3.0 * w + float2(1.7, 9.2) + t * 1.4, 6), fbm(q * 2.2 + 3.0 * w + float2(8.3, 2.8) - t, 6));
        float n = fbm(q * 1.8 + 3.2 * w2, 6);

        float3 deep = float3(0.01, 0.01, 0.04);
        float3 violet = float3(0.32, 0.08, 0.42);
        float3 magenta = float3(0.85, 0.22, 0.55);
        float3 amber = float3(1.0, 0.62, 0.32);
        float3 teal = float3(0.08, 0.45, 0.6);
        float3 color = mix(deep, violet, smoothstep(0.25, 0.6, n));
        color = mix(color, teal, smoothstep(0.35, 0.8, w2.x) * 0.65);
        color = mix(color, float3(0.15, 0.3, 0.85), smoothstep(0.45, 0.85, w.y) * 0.4);
        color = mix(color, magenta, smoothstep(0.55, 0.8, n) * 0.85);
        color = mix(color, amber, smoothstep(0.72, 0.95, n) * 0.75);
        color *= 0.3 + 1.5 * smoothstep(0.18, 0.85, n);
        float dust = fbm(q * 3.5 - w * 2.0 + 4.0, 5);
        color *= mix(0.25, 1.0, smoothstep(0.32, 0.62, dust));

        for (int k = 0; k < 3; k++) {
            float fk = float(k);
            float2 drift = float2(u.time * 0.004 * (fk + 1.0), u.time * 0.0015 * (fk + 1.0));
            color += float3(0.85, 0.9, 1.0) * stars(q + drift + fk * 3.3, 70.0 + fk * 70.0, 0.18 - fk * 0.03, u.time, 0.1 + fk * 0.03) * (1.0 - fk * 0.25);
        }
        // A few bright stars with diffraction spikes.
        float2 g = q * 6.0;
        float2 id = floor(g);
        if (hash21(id + 0.5) > 0.86) {
            float2 c = fract(g) - (0.25 + 0.5 * hash22(id + 2.0));
            float r = length(c);
            float spikes = max(0.0, 1.0 - abs(c.x) * 70.0) * max(0.0, 1.0 - abs(c.y) * 4.0)
                         + max(0.0, 1.0 - abs(c.y) * 70.0) * max(0.0, 1.0 - abs(c.x) * 4.0);
            float pulse = 0.75 + 0.25 * sin(u.time * 0.7 + hash21(id) * 30.0);
            color += float3(0.9, 0.95, 1.0) * (exp(-r * 55.0) * 1.6 + spikes * 0.35) * pulse;
        }
        return float4(finish(color, uv, u.resolution, u.time, 0.9, 1.3), 1.0);
    }

    // MARK: Ocean — caustic light network, god rays and drifting motes

    // Animated Voronoi: brightness peaks along cell edges, like light focused
    // by surface waves.
    float causticLayer(float2 p, float t) {
        float2 cell = floor(p), f = fract(p);
        float nearest = 8.0, second = 8.0;
        for (int y = -1; y <= 1; y++) {
            for (int x = -1; x <= 1; x++) {
                float2 g = float2(x, y);
                float2 o = hash22(cell + g);
                o = 0.5 + 0.42 * sin(t * 0.55 + 6.2831 * o);
                float d = length(g + o - f);
                if (d < nearest) { second = nearest; nearest = d; } else if (d < second) { second = d; }
            }
        }
        float edge = second - nearest;
        return pow(1.0 - smoothstep(0.0, 0.16, edge), 2.6);
    }

    fragment float4 fx_ocean(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
        float2 uv = in.uv;
        float aspect = u.resolution.x / u.resolution.y;
        float2 p = float2(uv.x * aspect, uv.y);
        float t = u.time;

        float3 color = mix(float3(0.0, 0.02, 0.07), float3(0.0, 0.28, 0.42), pow(uv.y, 1.3));
        float2 warp = float2(fbm(p * 1.3 + t * 0.05, 3), fbm(p * 1.3 - t * 0.04 + 7.0, 3)) * 0.9;
        float caustic = causticLayer(p * 3.2 + warp, t) * 0.9 + causticLayer(p * 4.9 + warp * 1.4 + 13.0, t * 1.15) * 0.6;
        caustic *= caustic * 1.4;
        color += float3(0.55, 0.95, 1.0) * caustic * (0.25 + 0.9 * uv.y);

        // Light shafts from the surface.
        float shaftX = uv.x * 5.0 + (1.0 - uv.y) * 1.3;
        float shafts = pow(fbm(float2(shaftX + t * 0.04, t * 0.03), 4), 3.0) * 2.2;
        color += float3(0.35, 0.8, 0.95) * shafts * smoothstep(0.05, 1.0, uv.y);
        // Surface shimmer at the top.
        color += float3(0.5, 0.9, 1.0) * smoothstep(0.88, 1.0, uv.y) * 0.35;

        // Drifting motes.
        for (int k = 0; k < 2; k++) {
            float fk = float(k);
            float2 mp = p * (14.0 + fk * 12.0) + float2(sin(t * 0.1 + fk) * 2.0, -t * (0.25 + fk * 0.1));
            color += float3(0.7, 0.95, 1.0) * stars(mp / (14.0 + fk * 12.0), 14.0 + fk * 12.0, 0.08, t, 0.08) * 0.35;
        }
        return float4(finish(color, uv, u.resolution, t, 1.1, 1.3), 1.0);
    }

    // MARK: Retro sunset — striped sun, misty mountains and a moving grid

    fragment float4 fx_synthwave(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
        float2 uv = in.uv;
        float aspect = u.resolution.x / u.resolution.y;
        float2 p = float2((uv.x - 0.5) * aspect, uv.y);
        float t = u.time;
        float horizon = 0.36;

        float3 color;
        if (uv.y > horizon) {
            float h = (uv.y - horizon) / (1.0 - horizon);
            color = mix(float3(1.0, 0.42, 0.38), float3(0.42, 0.08, 0.42), smoothstep(0.0, 0.45, h));
            color = mix(color, float3(0.05, 0.015, 0.12), smoothstep(0.35, 1.0, h));
            color += float3(1.0, 0.9, 0.95) * stars(p, 140.0, 0.14, t, 0.1) * smoothstep(0.45, 0.9, h);

            // Sun with scrolling horizontal cuts in its lower half.
            float2 sunCenter = float2(0.0, horizon + 0.15);
            float r = length((p - sunCenter) * float2(1.0, 1.0));
            float radius = 0.21;
            float sun = smoothstep(radius + 0.002, radius - 0.002, r);
            float rel = (p.y - (sunCenter.y - radius)) / (radius * 2.0);    // 0 bottom .. 1 top
            float bands = fract(rel * 13.0 + t * 0.3);
            float gap = mix(0.55, 0.06, smoothstep(0.0, 0.6, rel));
            sun *= (rel > 0.62) ? 1.0 : step(gap, bands);
            float3 sunColor = mix(float3(1.0, 0.16, 0.55), float3(1.0, 0.9, 0.3), smoothstep(0.0, 0.9, rel));
            color = mix(color, sunColor, sun);
            color += float3(1.0, 0.35, 0.45) * exp(-max(r - radius, 0.0) * 9.0) * 0.45;

            // Mountains: hazy back range, dark front range with a pink rim.
            float back = horizon + 0.07 + 0.08 * fbm(float2(p.x * 1.8 + 4.0, 1.0), 5);
            float front = horizon + 0.02 + 0.06 * fbm(float2(p.x * 2.6 + 9.0, 3.0), 5) * smoothstep(0.0, 0.9, abs(p.x));
            color = mix(color, float3(0.32, 0.06, 0.32), smoothstep(back + 0.002, back - 0.002, uv.y) * 0.85);
            float frontMask = smoothstep(front + 0.002, front - 0.002, uv.y);
            color = mix(color, float3(0.06, 0.01, 0.1), frontMask);
            color += float3(1.0, 0.35, 0.7) * smoothstep(0.006, 0.0, abs(uv.y - front)) * 0.6 * (1.0 - frontMask * 0.5);
        } else {
            // Perspective grid floor scrolling towards the viewer.
            float depth = 0.22 / max(horizon - uv.y, 0.0005);
            float2 grid = float2(p.x * depth * 1.6, depth + t * 1.4);
            float2 cell = abs(fract(grid) - 0.5);
            float2 width = fwidth(grid) * 1.4;
            float line = max(smoothstep(width.x, 0.0, 0.5 - cell.x), smoothstep(width.y, 0.0, 0.5 - cell.y));
            float fade = smoothstep(0.0, 0.35, horizon - uv.y);
            color = mix(float3(0.06, 0.0, 0.1), float3(0.02, 0.0, 0.05), smoothstep(0.0, horizon, horizon - uv.y));
            color += float3(1.0, 0.25, 0.85) * line * (0.35 + 0.65 * fade);
            color += float3(0.25, 0.9, 1.0) * line * 0.25 * fade;
            // Reflection of the sun on the floor.
            color += float3(1.0, 0.4, 0.5) * exp(-abs(p.x) * 5.0) * smoothstep(0.12, 0.0, horizon - uv.y) * 0.35;
        }
        // Horizon glow.
        color += float3(1.0, 0.35, 0.6) * exp(-abs(uv.y - horizon) * 60.0) * 0.8;
        return float4(finish(color, uv, u.resolution, t, 0.75, 0.0), 1.0);
    }
    """#
}
