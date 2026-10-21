#include <metal_stdlib>
using namespace metal;
constexpr sampler smoothSampler(coord::normalized, address::clamp_to_edge, filter::linear);
struct Feature {
    float edge, outer, texture, motion, gx, gy, flowX, flowY;
};
struct FeatureOptions {
    uint width, height, mode, pad;
};
struct FinishOptions {
    float glow, decay, enabled, pad;
    uint mode, width, height, pad2;
};
float luminance(float3 c) { return dot(c, float3(.2126, .7152, .0722)); }
float decode709(float v) { return v < .081 ? v / 4.5 : pow((v + .099) / 1.099, 1 / .45); }
float encode709(float v) {
    v = max(v, 0.0f);
    return v < .018 ? v * 4.5 : 1.099 * pow(v, .45) - .099;
}
kernel void prepare(texture2d<float, access::sample> input [[texture(0)]],
                    texture2d<float, access::write> gray [[texture(1)]],
                    uint2 p [[thread_position_in_grid]]) {
    if (p.x >= gray.get_width() || p.y >= gray.get_height())
        return;
    float2 uv = (float2(p) + .5) / float2(gray.get_width(), gray.get_height());
    gray.write(float4(luminance(input.sample(smoothSampler, uv).rgb)), p);
}
float at(texture2d<float, access::read> t, int2 p) {
    return t.read(uint2(clamp(p, int2(0), int2(t.get_width() - 1, t.get_height() - 1)))).r;
}
kernel void flow(texture2d<float, access::read> now [[texture(0)]],
                 texture2d<float, access::read> previous [[texture(1)]],
                 texture2d<float, access::write> output [[texture(2)]],
                 constant uint &radius [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {
    if (p.x >= output.get_width() || p.y >= output.get_height())
        return;
    int2 center = int2(p) * 8 + 4;
    float best = 1e9;
    int2 delta = 0;
    for (int y = -int(radius); y <= int(radius); y++)
        for (int x = -int(radius); x <= int(radius); x++) {
            float cost = 0;
            for (int j = -1; j <= 1; j++)
                for (int i = -1; i <= 1; i++) {
                    int2 q = center + int2(i, j) * 2;
                    cost += abs(at(now, q) - at(previous, q - int2(x, y)));
                }
            cost += .003 * (abs(x) + abs(y));
            if (cost < best) {
                best = cost;
                delta = int2(x, y);
            }
        }
    output.write(float4(float2(delta), 0, 1), p);
}
float2 gradient(texture2d<float, access::read> g, int2 p) {
    return float2(at(g, p + int2(1, 0)) - at(g, p - int2(1, 0)),
                  at(g, p + int2(0, 1)) - at(g, p - int2(0, 1)));
}
kernel void features(texture2d<float, access::read> gray [[texture(0)]],
                     texture2d<float, access::read> prev [[texture(1)]],
                     texture2d<float, access::sample> mask [[texture(2)]],
                     texture2d<float, access::read> flowMap [[texture(3)]],
                     device Feature *out [[buffer(0)]], constant FeatureOptions &o [[buffer(1)]],
                     uint2 p [[thread_position_in_grid]]) {
    if (p.x >= o.width || p.y >= o.height)
        return;
    int2 q = int2(p);
    float2 d = gradient(gray, q);
    float mag = length(d) * 2;
    int2 axis = abs(d.x) > abs(d.y) ? int2(1, 0) : int2(0, 1);
    float n1 = length(gradient(gray, q + axis)) * 2, n2 = length(gradient(gray, q - axis)) * 2;
    float ridge = mag >= n1 && mag >= n2 ? mag : 0;
    float2 uv = (float2(p) + .5) / float2(o.width, o.height), du = 1.0 / float2(o.width, o.height);
    float m = mask.sample(smoothSampler, uv).r;
    float boundary = abs(mask.sample(smoothSampler, uv + float2(du.x, 0)).r -
                         mask.sample(smoothSampler, uv - float2(du.x, 0)).r) +
                     abs(mask.sample(smoothSampler, uv + float2(0, du.y)).r -
                         mask.sample(smoothSampler, uv - float2(0, du.y)).r);
    float tex = abs(at(gray, q) - (at(gray, q + int2(2, 0)) + at(gray, q - int2(2, 0)) +
                                   at(gray, q + int2(0, 2)) + at(gray, q - int2(0, 2))) *
                                      .25) *
                3;
    float2 velocity =
        flowMap.read(min(p / 8, uint2(flowMap.get_width() - 1, flowMap.get_height() - 1))).rg;
    float motion = clamp(abs(at(gray, q) - at(prev, q)) * 3 + length(velocity) * .07, 0.f, 1.f) *
                   min(1.f, mag * 3);
    if (o.mode == 1) {
        boundary = 0;
    } else if (o.mode == 2) {
        ridge *= m;
        tex *= m;
        motion *= m;
    }
    out[p.y * o.width + p.x] = Feature{clamp(ridge, 0.f, 1.f),
                                       clamp(boundary, 0.f, 1.f),
                                       clamp(tex, 0.f, 1.f),
                                       motion,
                                       d.x,
                                       d.y,
                                       velocity.x,
                                       velocity.y};
}
struct LineVertex {
    float x, y, r, g, b, a, side;
};
struct Raster {
    float4 position [[position]];
    float4 color;
    float side;
};
vertex Raster line_vertex(const device LineVertex *v [[buffer(0)]],
                          constant float2 &size [[buffer(1)]], uint i [[vertex_id]]) {
    LineVertex p = v[i];
    return Raster{float4(p.x / size.x * 2 - 1, 1 - p.y / size.y * 2, 0, 1),
                  float4(p.r, p.g, p.b, p.a), p.side};
}
fragment float4 line_fragment(Raster r [[stage_in]]) {
    float a = r.color.a * (1 - smoothstep(.55, 1.0, abs(r.side)));
    return float4(r.color.rgb * a, a);
}
kernel void downsample(texture2d<float, access::sample> layer [[texture(0)]],
                       texture2d<float, access::write> small [[texture(1)]],
                       uint2 p [[thread_position_in_grid]]) {
    if (p.x >= small.get_width() || p.y >= small.get_height())
        return;
    float2 uv = (float2(p) + .5) / float2(small.get_width(), small.get_height());
    small.write(layer.sample(smoothSampler, uv), p);
}
kernel void blur(texture2d<float, access::sample> src [[texture(0)]],
                 texture2d<float, access::write> dst [[texture(1)]],
                 constant float4 &settings [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {
    if (p.x >= dst.get_width() || p.y >= dst.get_height())
        return;
    float2 uv = (float2(p) + .5) / float2(dst.get_width(), dst.get_height());
    float4 c = 0;
    float sum = 0;
    float sigma = max(.5f, settings.z);
    int radius = clamp(int(ceil(sigma * 3)), 1, 48);
    for (int k = -radius; k <= radius; k++) {
        float w = exp(-float(k * k) / (2 * sigma * sigma));
        c += src.sample(smoothSampler, uv + settings.xy * float(k)) * w;
        sum += w;
    }
    dst.write(c / sum, p);
}
kernel void finish(texture2d<float, access::read> input [[texture(0)]],
                   texture2d<float, access::read> line [[texture(1)]],
                   texture2d<float, access::sample> bloom [[texture(2)]],
                   texture2d<float, access::read> history [[texture(3)]],
                   texture2d<float, access::write> nextHistory [[texture(4)]],
                   texture2d<float, access::write> output [[texture(5)]],
                   constant FinishOptions &o [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {
    if (p.x >= o.width || p.y >= o.height)
        return;
    float2 uv = (float2(p) + .5) / float2(o.width, o.height);
    float4 l = line.read(p) * o.enabled;
    float4 b = bloom.sample(smoothSampler, uv) * o.glow * o.enabled;
    float peak = max(b.r, max(b.g, b.b));
    float ba = clamp(max(b.a, peak), 0.f, .98f);
    if (peak > ba)
        b.rgb *= ba / max(peak, .0001f);
    l.rgb += b.rgb * (1 - l.a);
    l.a = clamp(l.a + ba * (1 - l.a), 0.f, 1.f);
    float4 old = history.read(p) * o.decay;
    l += old * (1 - l.a);
    l.a = clamp(l.a, 0.f, 1.f);
    nextHistory.write(l, p);
    float4 c = l;
    if (o.mode == 0) {
        float4 bg = input.read(p);
        float3 unpremul = bg.a > .0001 ? bg.rgb / bg.a : float3(0);
        float3 linear =
            float3(decode709(unpremul.r), decode709(unpremul.g), decode709(unpremul.b)) * bg.a;
        c = float4(l.rgb + linear * (1 - l.a), l.a + bg.a * (1 - l.a));
    } else if (o.mode == 1)
        c.a = 1;
    float3 straight = c.a > .0001 ? c.rgb / c.a : float3(0);
    float3 encoded = float3(encode709(straight.r), encode709(straight.g), encode709(straight.b));
    output.write(float4(clamp(encoded, 0.f, 1.f) * c.a, c.a), p);
}
