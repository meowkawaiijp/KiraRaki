#include "Contours.hpp"
#include <algorithm>
#include <cmath>
#include <unordered_map>

namespace kira {
uint64_t hash(uint64_t x) {
    x += 0x9e3779b97f4a7c15ULL;
    x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9ULL;
    x = (x ^ (x >> 27)) * 0x94d049bb133111ebULL;
    return x ^ (x >> 31);
}
float random01(uint64_t x) { return float(hash(x) >> 40) / 16777216.f; }
static float distance(Point a, Point b) { return std::hypot(a.x - b.x, a.y - b.y); }
static Point mix(Point a, Point b, float t) {
    return {a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t};
}
static Point direction(Point a, Point b) {
    float d = std::max(.001f, distance(a, b));
    return {(b.x - a.x) / d, (b.y - a.y) / d};
}
static Point center(const std::vector<Point> &p) {
    Point c;
    for (auto q : p) {
        c.x += q.x;
        c.y += q.y;
    }
    if (!p.empty()) {
        c.x /= p.size();
        c.y /= p.size();
    }
    return c;
}
static Point atFraction(const std::vector<Point> &p, float t) {
    float index = std::clamp(t, 0.f, 1.f) * (p.size() - 1);
    size_t i = std::min(size_t(index), p.size() - 2);
    return mix(p[i], p[i + 1], index - i);
}
struct Curve {
    const std::vector<Point> &points;
    std::vector<float> arc;
    explicit Curve(const std::vector<Point> &p) : points(p), arc(p.size()) {
        for (size_t i = 1; i < p.size(); ++i)
            arc[i] = arc[i - 1] + distance(p[i - 1], p[i]);
    }
    float length() const { return arc.empty() ? 0 : arc.back(); }
    std::pair<size_t, float> location(float s) const {
        s = std::clamp(s, 0.f, length());
        size_t i = std::clamp(size_t(std::upper_bound(arc.begin(), arc.end(), s) - arc.begin()),
                              size_t(1), arc.size() - 1);
        return {i, (s - arc[i - 1]) / std::max(.001f, arc[i] - arc[i - 1])};
    }
    Point at(float s) const {
        auto [i, t] = location(s);
        return mix(points[i - 1], points[i], t);
    }
    float motionAt(float s, const std::vector<float> &motion) const {
        auto [i, t] = location(s);
        return motion[i - 1] + (motion[i] - motion[i - 1]) * t;
    }
    std::vector<Point> sample(float start, float end, size_t count) const {
        std::vector<Point> result;
        result.reserve(count);
        for (size_t i = 0; i < count; ++i)
            result.push_back(at(start + (end - start) * i / (count - 1)));
        return result;
    }
};
static float smooth(float t) { return t * t * (3 - 2 * t); }
// Spatial controls are shared along a line; only their values evolve over time.
static float noise(uint64_t seed, float position, double time) {
    int64_t x = int64_t(std::floor(position)), y = int64_t(std::floor(time));
    float a = smooth(position - x), b = smooth(float(time - y));
    auto value = [&](int64_t i, int64_t j) {
        return random01(seed ^ hash(uint64_t(i)) ^ hash(uint64_t(j) + 0xa24baed4963ee407ULL));
    };
    float lo = value(x, y) + (value(x + 1, y) - value(x, y)) * a;
    float hi = value(x, y + 1) + (value(x + 1, y + 1) - value(x, y + 1)) * a;
    return lo + (hi - lo) * b;
}
static Color hsv(float h) {
    h -= std::floor(h);
    float a = h * 6;
    int i = int(a);
    float f = a - i;
    switch (i) {
    case 0:
        return {1, f, 0};
    case 1:
        return {1 - f, 1, 0};
    case 2:
        return {0, 1, f};
    case 3:
        return {0, 1 - f, 1};
    case 4:
        return {f, 0, 1};
    default:
        return {1, 0, 1 - f};
    }
}
static float linear(float v) {
    return v < .081f ? v / 4.5f : std::pow((v + .099f) / 1.099f, 1 / .45f);
}
// Shared joints keep an angular stroke connected even when a corner moves sharply.
static void ribbon(const std::vector<Point> &path, Color color, float alpha, float half,
                   std::vector<Vertex> &out) {
    if (path.size() < 2)
        return;
    std::vector<Point> offsets;
    offsets.reserve(path.size());
    for (size_t i = 0; i < path.size(); ++i) {
        Point a = direction(path[i ? i - 1 : i], path[i ? i : 1]);
        Point b = direction(path[i + 1 < path.size() ? i : i - 1],
                            path[std::min(i + 1, path.size() - 1)]);
        Point n{-a.y - b.y, a.x + b.x};
        float d = std::hypot(n.x, n.y);
        n = d > .01f ? Point{n.x / d, n.y / d} : Point{-b.y, b.x};
        float amount = std::min(half * 2.5f, half / std::max(.2f, n.x * -b.y + n.y * b.x));
        offsets.push_back({n.x * amount, n.y * amount});
    }
    auto vertex = [&](size_t i, float side) {
        return Vertex{path[i].x + offsets[i].x * side,
                      path[i].y + offsets[i].y * side,
                      color.r,
                      color.g,
                      color.b,
                      alpha,
                      side};
    };
    for (size_t i = 1; i < path.size() && out.size() + 6 <= 400000; ++i)
        if (distance(path[i - 1], path[i]) > .01f)
            out.insert(out.end(), {vertex(i - 1, -1), vertex(i - 1, 1), vertex(i, -1),
                                   vertex(i, -1), vertex(i - 1, 1), vertex(i, 1)});
}
void Contours::reset() {
    tracks.clear();
    nextID = 1;
    lastPTS = -1;
    lastCandidateLength = 0;
    statistics = {};
}

std::vector<Vertex> Contours::update(const Feature *f, int w, int h, int ow, int oh, double pts,
                                     const Parameters &p) {
    if (pts < lastPTS || pts - lastPTS > 2 || w != lastW || h != lastH)
        reset();
    float dt = lastPTS >= 0 ? std::clamp(float(pts - lastPTS), .001f, .2f) : 1 / 30.f;
    lastPTS = pts;
    lastW = w;
    lastH = h;
    statistics = {};
    float weights = 0;
    for (float a : p.shapes)
        weights += a;
    if (w < 3 || h < 3 || !f || weights <= 0)
        return {};
    float analysisScale = h / 1080.f;
    float sx = float(ow) / w, sy = float(oh) / h, scale = oh / 1080.f;
    float targetLength = std::max(8.f, p.strokeLength * analysisScale);
    float minimumLength = std::max(5.f, 36 * analysisScale);
    auto feature = [&](Point q) -> const Feature & {
        return f[std::clamp(int(std::round(q.y)), 0, h - 1) * w +
                 std::clamp(int(std::round(q.x)), 0, w - 1)];
    };
    auto activity = [&](const Feature &v) {
        float speed = std::hypot(v.flowX, v.flowY) / (analysisScale * dt);
        return std::clamp(std::max(v.motion * 1.8f, speed / 360.f), 0.f, 1.f);
    };
    std::vector<uint8_t> active(w * h), visited(w * h);
    float sum = 0;
    for (float a : p.regions)
        sum += std::max(a, 0.f);
    sum = std::max(sum, .001f);
    for (int y = 1; y < h - 1; ++y)
        for (int x = 1; x < w - 1; ++x) {
            int i = y * w + x;
            const auto &v = f[i];
            float corner = std::min(1.f, std::abs(v.gx * f[i + 1].gy - v.gy * f[i + 1].gx) * 4);
            float score =
                (p.regions[0] * v.outer + p.regions[1] * v.edge + p.regions[2] * v.texture * .45f +
                 p.regions[3] * v.motion + p.regions[4] * corner) /
                sum;
            // Motion selects structural ridges, rather than filling moving regions with dots.
            active[i] = score > p.threshold * .65f && (v.edge > p.threshold || v.outer > .18f);
        }
    std::vector<std::vector<Point>> paths;
    size_t pathLimit = size_t(std::max(p.maxStrokes * 5, 100));
    // Trace both ways from a seed, first from endpoints, then from closed contours.
    for (int pass = 0; pass < 2; ++pass)
        for (int y = 1; y < h - 1 && paths.size() < pathLimit; ++y)
            for (int x = 1; x < w - 1 && paths.size() < pathLimit; ++x) {
                int start = y * w + x;
                if (!active[start] || visited[start])
                    continue;
                if (!pass) {
                    int neighbors = 0;
                    for (int yy = -1; yy <= 1; ++yy)
                        for (int xx = -1; xx <= 1; ++xx)
                            if (xx || yy)
                                neighbors += active[(y + yy) * w + x + xx];
                    if (neighbors > 1)
                        continue;
                }
                visited[start] = 1;
                Point origin{float(x), float(y)};
                auto walk = [&](Point heading) {
                    std::vector<Point> chain;
                    Point at = origin;
                    for (int n = 0; n < 2048; ++n) {
                        Point bestPoint;
                        float best = -100;
                        bool found = false;
                        // Only bridge a missing pixel when adjacent ridge pixels run out.
                        for (int radius = 1; radius <= 2 && !found; ++radius)
                            for (int yy = -radius; yy <= radius; ++yy)
                                for (int xx = -radius; xx <= radius; ++xx) {
                                    if (std::max(std::abs(xx), std::abs(yy)) != radius)
                                        continue;
                                    int nx = int(at.x) + xx, ny = int(at.y) + yy;
                                    if (nx <= 0 || ny <= 0 || nx >= w - 1 || ny >= h - 1)
                                        continue;
                                    int index = ny * w + nx;
                                    if (!active[index] || visited[index])
                                        continue;
                                    Point step = direction(at, {float(nx), float(ny)});
                                    float alignment = heading.x * step.x + heading.y * step.y;
                                    bool guided = std::hypot(heading.x, heading.y) > .1f;
                                    if (guided && alignment < (radius == 1 ? -.2f : .8f))
                                        continue;
                                    const auto &v = f[index];
                                    float gradient = std::hypot(v.gx, v.gy);
                                    float tangent =
                                        gradient > .01f
                                            ? std::abs(-v.gy * step.x + v.gx * step.y) / gradient
                                            : .5f;
                                    if (radius == 2 && tangent < .6f)
                                        continue;
                                    float score = alignment * .9f + tangent * .4f + v.edge * .25f +
                                                  v.outer * .2f -
                                                  std::hypot(float(xx), float(yy)) * .08f;
                                    if (score > best) {
                                        best = score;
                                        bestPoint = {float(nx), float(ny)};
                                        found = true;
                                    }
                                }
                        if (!found)
                            break;
                        heading = direction(at, bestPoint);
                        at = bestPoint;
                        visited[int(at.y) * w + int(at.x)] = 1;
                        chain.push_back(at);
                    }
                    return chain;
                };
                auto forward = walk({});
                Point back = forward.empty() ? Point{} : direction(forward.front(), origin);
                auto backward = walk(back);
                std::vector<Point> chain(backward.rbegin(), backward.rend());
                chain.push_back(origin);
                chain.insert(chain.end(), forward.begin(), forward.end());
                if (chain.size() < 5)
                    continue;
                if (distance(chain.front(), chain.back()) < 2)
                    chain.push_back(chain.front());
                // Remove pixel stair-stepping before introducing intentional angular deformation.
                auto filtered = chain;
                for (size_t i = 1; i + 1 < chain.size(); ++i)
                    filtered[i] = mix(chain[i], mix(chain[i - 1], chain[i + 1], .5f), .4f);
                Curve curve(filtered);
                if (curve.length() < minimumLength)
                    continue;
                int pieces = std::max(1, int(std::round(curve.length() / targetLength)));
                for (int i = 0; i < pieces && paths.size() < pathLimit; ++i) {
                    float a = curve.length() * i / pieces, b = curve.length() * (i + 1) / pieces;
                    size_t count = std::clamp(
                        size_t(std::ceil((b - a) / std::max(1.5f, 6 * analysisScale))) + 1,
                        size_t(3), size_t(256));
                    paths.push_back(curve.sample(a, b, count));
                    statistics.candidateLength += b - a;
                }
            }
    statistics.candidates = int(paths.size());
    if (!paths.empty())
        lastCandidateLength = statistics.candidateLength;
    constexpr float cell = 24;
    auto key = [](int x, int y) { return (uint64_t(uint32_t(x)) << 32) | uint32_t(y); };
    std::unordered_map<uint64_t, std::vector<size_t>> bins;
    for (size_t k = 0; k < tracks.size(); ++k) {
        auto &s = tracks[k];
        for (size_t i = 0; i < s.points.size(); ++i) {
            auto v = feature(s.points[i]);
            s.points[i].x += v.flowX;
            s.points[i].y += v.flowY;
            float target = activity(v), tau = target > s.motion[i] ? .045f : .24f;
            s.motion[i] += (target - s.motion[i]) * (1 - std::exp(-dt / tau));
        }
        s.center = center(s.points);
        bins[key(int(s.center.x / cell), int(s.center.y / cell))].push_back(k);
    }
    std::vector<bool> matched(tracks.size(), false);
    for (auto &path : paths) {
        Point c = center(path);
        size_t match = SIZE_MAX;
        float best = 22;
        bool reverse = false;
        for (int yy = -1; yy <= 1; ++yy)
            for (int xx = -1; xx <= 1; ++xx) {
                auto bin = bins.find(key(int(c.x / cell) + xx, int(c.y / cell) + yy));
                if (bin == bins.end())
                    continue;
                for (auto k : bin->second) {
                    if (matched[k] || distance(c, tracks[k].center) > 24)
                        continue;
                    const auto &old = tracks[k].points;
                    float same =
                        distance(path.front(), old.front()) + distance(path.back(), old.back());
                    float flipped =
                        distance(path.front(), old.back()) + distance(path.back(), old.front());
                    bool flip = flipped < same;
                    float error = std::min(same, flipped);
                    for (float t : {.25f, .5f, .75f})
                        error += distance(atFraction(path, flip ? 1 - t : t), atFraction(old, t));
                    error = error / 5 + distance(c, tracks[k].center) * .2f;
                    if (error < best) {
                        best = error;
                        match = k;
                        reverse = flip;
                    }
                }
            }
        if (match == SIZE_MAX) {
            if (tracks.size() < size_t(p.maxStrokes * 3)) {
                Stroke s{nextID++, std::move(path), pts, pts, 1, c, {}, .5f};
                for (auto q : s.points)
                    s.motion.push_back(activity(feature(q)));
                tracks.push_back(std::move(s));
                matched.push_back(true);
            }
        } else {
            auto &s = tracks[match];
            matched[match] = true;
            if (reverse)
                std::reverse(path.begin(), path.end());
            Curve curve(path);
            auto aligned = curve.sample(0, curve.length(), s.points.size());
            float blend = 1 - std::exp(-dt * (8 + p.tracking * 65));
            for (size_t i = 0; i < s.points.size(); ++i)
                s.points[i] = mix(s.points[i], aligned[i], blend);
            s.center = center(s.points);
            s.lastSeen = pts;
            s.confidence = 1;
        }
    }
    std::erase_if(tracks,
                  [&](const Stroke &s) { return pts - s.lastSeen > std::max(.05f, p.lifetime); });
    struct Ranked {
        size_t index;
        float priority, length;
    };
    std::vector<Ranked> ranked;
    for (size_t index = 0; index < tracks.size(); ++index) {
        auto &s = tracks[index];
        Curve curve(s.points);
        float salience = 0, total = p.placement[0] + p.placement[1] + p.placement[2];
        for (auto q : s.points) {
            const auto &v = feature(q);
            salience += (p.placement[0] + p.placement[1] * std::min(1.f, v.edge + v.outer) +
                         p.placement[2] * std::min(1.f, v.motion * 2)) /
                        std::max(.001f, total);
        }
        salience /= s.points.size();
        s.salience += (salience - s.salience) * (1 - std::exp(-dt / .2f));
        // Selection stays anchored to the track: shape updates do not reshuffle whole lines.
        float priority = (.15f + .85f * random01(s.id ^ p.seed)) / (.3f + s.salience * .7f);
        priority *= std::sqrt(std::max(1.f, targetLength * .45f / std::max(.001f, curve.length())));
        ranked.push_back({index, priority, curve.length()});
    }
    std::sort(ranked.begin(), ranked.end(), [](const Ranked &a, const Ranked &b) {
        return a.priority == b.priority ? a.index < b.index : a.priority < b.priority;
    });
    std::unordered_map<uint64_t, float> selected;
    // Keep the last arc-length budget through a detection gap, so hold/fade modes still work.
    float remaining = lastCandidateLength * std::clamp(p.density, 0.f, 1.f);
    for (const auto &item : ranked) {
        if (remaining < minimumLength || selected.size() >= size_t(p.maxStrokes))
            break;
        float length = std::min(item.length, remaining);
        selected[tracks[item.index].id] = length;
        remaining -= length;
    }
    std::vector<Vertex> vertices;
    vertices.reserve(p.maxStrokes * 180);
    for (auto &s : tracks) {
        if (statistics.strokes >= p.maxStrokes || vertices.size() + 6 > 400000)
            break;
        auto choice = selected.find(s.id);
        if (choice == selected.end())
            continue;
        Color color = p.colorMode == 1 && !p.palette.empty()
                          ? p.palette[hash(s.id ^ p.seed) % p.palette.size()]
                          : hsv(p.hueOffset + random01(s.id ^ p.seed) +
                                (p.colorMode == 2 ? 0 : float(std::fmod(pts * p.hueSpeed, 1.0))));
        color = {linear(color.r), linear(color.g), linear(color.b)};
        float loss = float(pts - s.lastSeen), alpha = p.opacity;
        if (p.lossMode == 1 && loss > .04f)
            alpha = 0;
        else if (p.lossMode != 2)
            alpha *= std::clamp(1 - loss / std::max(.05f, p.lifetime), 0.f, 1.f);
        alpha *= std::min(1.f, .25f + float(pts - s.birth) / .1f);
        if (alpha < .01f)
            continue;
        Curve curve(s.points);
        float length = std::min(choice->second, curve.length());
        float start = (curve.length() - length) * random01(s.id ^ hash(p.seed));
        size_t count = std::clamp(size_t(std::ceil(length / (p.jaggedSpacing * analysisScale))) + 1,
                                  size_t(3), size_t(192));
        std::vector<Point> q = curve.sample(start, start + length, count);
        uint64_t seed = hash(s.id ^ p.seed);
        double time = pts * p.updateHz * .6;
        for (size_t i = 0; i < q.size(); ++i) {
            float arc = start + length * i / (q.size() - 1);
            Point a = curve.at(std::max(0.f, arc - analysisScale * 8));
            Point b = curve.at(std::min(curve.length(), arc + analysisScale * 8));
            Point tangent = direction({a.x * sx, a.y * sy}, {b.x * sx, b.y * sy});
            float localMotion = curve.motionAt(arc, s.motion);
            float response = .3f * (1 - p.motionResponse) + localMotion * p.motionResponse;
            float amplitude = p.distortion * 140 * scale * (.08f + 1.6f * std::pow(response, 1.1f));
            float envelope = noise(seed ^ 0x68bc21ebULL, float(i) / 2.5f, time * .27);
            float varying =
                1 - p.irregularity + p.irregularity * (.04f + .96f * std::pow(envelope, 2.1f));
            float lightning = noise(seed, float(i), time) * 2 - 1;
            float organic = std::sin(float(arc / (p.jaggedSpacing * analysisScale * 2)) +
                                     random01(seed) * 6.2831853f + float(time * .4));
            float endpoint =
                .35f +
                .65f * std::pow(std::max(0.f, std::sin(3.14159265f * i / (q.size() - 1))), .4f);
            float offset = (p.shapes[0] * lightning + p.shapes[1] * organic) / weights * amplitude *
                           varying * endpoint;
            q[i] = {q[i].x * sx - tangent.y * offset, q[i].y * sy + tangent.x * offset};
            float glitch = p.shapes[2] / weights;
            if (glitch > .01f) {
                float grid = std::max(1.f, p.distortion * 16 * scale);
                q[i].x += (std::round(q[i].x / grid) * grid - q[i].x) * glitch;
                q[i].y += (std::round(q[i].y / grid) * grid - q[i].y) * glitch;
            }
        }
        if (p.shapes[1] > .01f && q.size() > 3) {
            std::vector<Point> smoothPoints;
            float amount = p.shapes[1] / weights;
            for (size_t i = 0; i + 1 < q.size(); ++i) {
                Point a = q[i ? i - 1 : i], b = q[i], c = q[i + 1],
                      d = q[std::min(i + 2, q.size() - 1)];
                smoothPoints.push_back(b);
                for (float t : {.3333f, .6667f}) {
                    float t2 = t * t, t3 = t2 * t;
                    Point point{.5f * (2 * b.x + (-a.x + c.x) * t +
                                       (2 * a.x - 5 * b.x + 4 * c.x - d.x) * t2 +
                                       (-a.x + 3 * b.x - 3 * c.x + d.x) * t3),
                                .5f * (2 * b.y + (-a.y + c.y) * t +
                                       (2 * a.y - 5 * b.y + 4 * c.y - d.y) * t2 +
                                       (-a.y + 3 * b.y - 3 * c.y + d.y) * t3)};
                    smoothPoints.push_back(mix(mix(b, c, t), point, amount));
                }
            }
            smoothPoints.push_back(q.back());
            q = std::move(smoothPoints);
        }
        size_t before = vertices.size();
        std::vector<Point> run{q.front()};
        float half = std::max(.4f, p.width * scale * .5f) + 1;
        for (size_t i = 1; i < q.size(); ++i) {
            float arc = start + length * (i - .5f) / (q.size() - 1);
            float block = arc / (std::max(120.f, p.jaggedSpacing * 3) * analysisScale);
            // Optional gaps occupy whole long spans, never independent tiny line segments.
            bool gap = p.shapes[3] > .01f && noise(seed ^ 0x02e5be93ULL, std::floor(block),
                                                   time * .15) < p.shapes[3] * .36f;
            if (gap) {
                ribbon(run, color, alpha, half, vertices);
                run = {q[i]};
                continue;
            }
            float glitch = p.shapes[2] / weights;
            if (glitch > .01f) {
                Point a = q[i - 1], b = q[i];
                Point bend = (hash(seed + i) % 2) ? Point{b.x, a.y} : Point{a.x, b.y};
                run.push_back(mix(mix(a, b, .5f), bend, glitch));
            }
            run.push_back(q[i]);
            statistics.drawnLength += length / (q.size() - 1);
        }
        ribbon(run, color, alpha, half, vertices);
        if (vertices.size() > before)
            ++statistics.strokes;
    }
    statistics.vertices = int(vertices.size());
    return vertices;
}
} // namespace kira
