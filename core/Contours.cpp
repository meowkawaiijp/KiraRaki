#include "Contours.hpp"
#include <algorithm>
#include <cmath>
#include <limits>
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
void Contours::reset() {
    tracks.clear();
    nextID = 1;
    lastPTS = -1;
    statistics = {};
}

std::vector<Vertex> Contours::update(const Feature *f, int w, int h, int ow, int oh, double pts,
                                     const Parameters &p) {
    if (pts < lastPTS || pts - lastPTS > 2 || w != lastW || h != lastH)
        reset();
    lastPTS = pts;
    lastW = w;
    lastH = h;
    statistics = {};
    if (w < 3 || h < 3 || !f || p.shapes[0] + p.shapes[1] + p.shapes[2] + p.shapes[3] <= 0)
        return {};
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
            active[i] = (score > p.threshold * .65f) &&
                        (v.edge > p.threshold || v.outer > .18f || v.motion > .4f);
        }
    std::vector<std::vector<Point>> paths;
    constexpr int dx[8] = {1, 1, 0, -1, -1, -1, 0, 1}, dy[8] = {0, 1, 1, 1, 0, -1, -1, -1};
    // Follow connected one-pixel ridges instead of drawing unrelated edge pixels.
    for (int y = 1; y < h - 1; ++y)
        for (int x = 1; x < w - 1; ++x) {
            int start = y * w + x;
            if (!active[start] || visited[start])
                continue;
            std::vector<Point> chain;
            int cx = x, cy = y;
            Point direction{1, 0};
            for (int n = 0; n < 180; ++n) {
                int i = cy * w + cx;
                visited[i] = 1;
                chain.push_back({float(cx), float(cy)});
                float best = -100;
                int bx = -1, by = 0;
                for (int k = 0; k < 8; ++k) {
                    int nx = cx + dx[k], ny = cy + dy[k];
                    if (nx <= 0 || ny <= 0 || nx >= w - 1 || ny >= h - 1)
                        continue;
                    int j = ny * w + nx;
                    if (!active[j] || visited[j])
                        continue;
                    float s = (direction.x * dx[k] + direction.y * dy[k]) * .12f + f[j].edge +
                              f[j].outer * .7f;
                    if (s > best) {
                        best = s;
                        bx = nx;
                        by = ny;
                    }
                }
                if (bx < 0)
                    break;
                direction = {float(bx - cx), float(by - cy)};
                cx = bx;
                cy = by;
            }
            if (chain.size() < 5)
                continue;
            for (size_t b = 0; b + 4 < chain.size(); b += 28) {
                size_t e = std::min(b + 30, chain.size());
                std::vector<Point> q;
                for (size_t j = b; j < e; j += 2)
                    q.push_back(chain[j]);
                if (q.size() >= 3)
                    paths.push_back(std::move(q));
            }
            if (paths.size() > size_t(std::max(p.maxStrokes * 5, 100)))
                break;
        }
    statistics.candidates = int(paths.size());
    // A small spatial index bounds temporal matching cost, even on textured frames.
    constexpr float cell = 18;
    auto key = [](int x, int y) { return (uint64_t(uint32_t(x)) << 32) | uint32_t(y); };
    std::unordered_map<uint64_t, std::vector<size_t>> bins;
    for (size_t k = 0; k < tracks.size(); ++k) {
        auto &s = tracks[k];
        int ix = std::clamp(int(s.center.x), 0, w - 1), iy = std::clamp(int(s.center.y), 0, h - 1);
        auto v = f[iy * w + ix];
        s.center.x += v.flowX;
        s.center.y += v.flowY;
        for (auto &a : s.points) {
            a.x += v.flowX;
            a.y += v.flowY;
        }
        bins[key(int(s.center.x / cell), int(s.center.y / cell))].push_back(k);
    }
    std::vector<bool> matched(tracks.size(), false);
    for (auto &path : paths) {
        Point c = center(path);
        size_t match = SIZE_MAX;
        float best = 14;
        for (int yy = -1; yy <= 1; ++yy)
            for (int xx = -1; xx <= 1; ++xx) {
                auto b = bins.find(key(int(c.x / cell) + xx, int(c.y / cell) + yy));
                if (b == bins.end())
                    continue;
                for (auto k : b->second) {
                    if (matched[k])
                        continue;
                    float d = distance(c, tracks[k].center);
                    if (d < best) {
                        best = d;
                        match = k;
                    }
                }
            }
        float len = 0;
        for (size_t j = 1; j < path.size(); ++j)
            len += distance(path[j - 1], path[j]);
        statistics.candidateLength += len;
        if (match == SIZE_MAX) {
            if (tracks.size() < size_t(p.maxStrokes * 3)) {
                tracks.push_back({nextID++, std::move(path), pts, pts, 1, c});
                matched.push_back(true);
            }
        } else {
            auto &s = tracks[match];
            matched[match] = true;
            if (s.points.size() == path.size()) {
                float a = .25f + .75f * p.tracking;
                for (size_t j = 0; j < path.size(); ++j) {
                    s.points[j].x += a * (path[j].x - s.points[j].x);
                    s.points[j].y += a * (path[j].y - s.points[j].y);
                }
            } else
                s.points = std::move(path);
            s.center = c;
            s.lastSeen = pts;
            s.confidence = 1;
        }
    }
    std::erase_if(tracks,
                  [&](const Stroke &s) { return pts - s.lastSeen > std::max(.05f, p.lifetime); });
    std::vector<Vertex> vertices;
    vertices.reserve(p.maxStrokes * 180);
    float sx = float(ow) / w, sy = float(oh) / h, scale = oh / 1080.f;
    struct Ranked {
        size_t index;
        float priority, length;
    };
    std::vector<Ranked> ranked;
    float availableLength = 0;
    for (size_t index = 0; index < tracks.size(); ++index) {
        const auto &s = tracks[index];
        float length = 0;
        for (size_t j = 1; j < s.points.size(); ++j)
            length += distance(s.points[j - 1], s.points[j]);
        int fi = std::clamp(int(s.center.y), 0, h - 1) * w + std::clamp(int(s.center.x), 0, w - 1);
        float total = p.placement[0] + p.placement[1] + p.placement[2];
        float salience =
            (p.placement[0] + p.placement[1] * std::min(1.f, f[fi].edge + f[fi].outer) +
             p.placement[2] * std::min(1.f, f[fi].motion * 2)) /
            std::max(.001f, total);
        double time = std::max(0., (pts - s.birth) * p.updateHz);
        uint64_t epoch = uint64_t(std::floor(time));
        float blend = float(time - std::floor(time));
        blend = blend * blend * (3 - 2 * blend);
        float r0 = random01(s.id ^ p.seed ^ hash(epoch)),
              r1 = random01(s.id ^ p.seed ^ hash(epoch + 1));
        ranked.push_back({index, (r0 + (r1 - r0) * blend) / (.1f + salience), length});
        availableLength += length;
    }
    std::sort(ranked.begin(), ranked.end(),
              [](const Ranked &a, const Ranked &b) { return a.priority < b.priority; });
    std::unordered_map<uint64_t, float> selected;
    float remaining = availableLength * p.density;
    for (const auto &item : ranked) {
        if (remaining <= 0 || selected.size() >= size_t(p.maxStrokes))
            break;
        float length = std::min(item.length, remaining);
        selected[tracks[item.index].id] = length;
        remaining -= length;
    }
    for (auto &s : tracks) {
        if (statistics.strokes >= p.maxStrokes || vertices.size() > 400000)
            break;
        // Arc-length sampling is anchored to a stable track and a chosen refresh window.
        uint64_t window = uint64_t(std::max(0., std::floor((pts - s.birth) * p.updateHz)));
        float cycle = random01(s.id ^ p.seed ^ hash(window));
        auto choice = selected.find(s.id);
        if (choice == selected.end())
            continue;
        Color color =
            p.colorMode == 1 && !p.palette.empty()
                ? p.palette[hash(s.id ^ p.seed) % p.palette.size()]
                : hsv(p.hueOffset + (p.colorMode == 2 ? random01(s.id ^ p.seed)
                                                      : float(std::fmod(pts * p.hueSpeed, 1.0)) +
                                                            random01(s.id ^ p.seed)));
        color = {linear(color.r), linear(color.g), linear(color.b)};
        float loss = float(pts - s.lastSeen), alpha = p.opacity;
        if (p.lossMode == 1 && loss > .04f)
            alpha = 0;
        else if (p.lossMode != 2)
            alpha *= std::clamp(1 - loss / std::max(.05f, p.lifetime), 0.f, 1.f);
        if (alpha < .01f)
            continue;
        std::vector<Point> q;
        float arc = 0;
        if (!s.points.empty())
            q.push_back(s.points.front());
        for (size_t j = 1; j < s.points.size(); ++j) {
            float length = distance(s.points[j - 1], s.points[j]);
            if (arc + length <= choice->second) {
                q.push_back(s.points[j]);
                arc += length;
            } else {
                float a = (choice->second - arc) / std::max(.001f, length);
                q.push_back({s.points[j - 1].x + (s.points[j].x - s.points[j - 1].x) * a,
                             s.points[j - 1].y + (s.points[j].y - s.points[j - 1].y) * a});
                break;
            }
        }
        if (q.size() < 2)
            continue;
        float weights = 0;
        for (float a : p.shapes)
            weights += a;
        for (size_t j = 0; j < q.size(); ++j) {
            Point a = s.points[j ? j - 1 : j], b = s.points[std::min(j + 1, q.size() - 1)];
            float d = std::max(distance(a, b), .001f), nx = -(b.y - a.y) / d, ny = (b.x - a.x) / d;
            float phase = random01(s.id ^ p.seed) * 6.2831853f + j * .85f;
            float organic = std::sin(phase + pts * p.updateHz * .18) +
                            .3f * std::sin(phase * 2.1 - pts * p.updateHz * .11);
            double time = pts * p.updateHz * (.35 + .65 * p.irregularity);
            uint64_t tick = uint64_t(std::max(0., std::floor(time)));
            float blend = float(time - std::floor(time));
            blend = blend * blend * (3 - 2 * blend);
            float l0 = random01(s.id ^ p.seed ^ hash(j + tick * 173)),
                  l1 = random01(s.id ^ p.seed ^ hash(j + (tick + 1) * 173));
            float lightning = ((l0 + (l1 - l0) * blend) - .5f) * 2;
            float noise =
                weights > .001f ? (p.shapes[0] * lightning + p.shapes[1] * organic) / weights : 0;
            q[j].x = (q[j].x * sx) + nx * noise * p.distortion * 22 * scale;
            q[j].y = (q[j].y * sy) + ny * noise * p.distortion * 22 * scale;
            if (p.shapes[2] > 0 && cycle < .55f) {
                float v = std::max(1.f, 5 * p.distortion * scale),
                      m = p.shapes[2] / std::max(weights, .001f);
                q[j].x += m * (std::round(q[j].x / v) * v - q[j].x);
                if (j % 3 == 0)
                    q[j].y += m * (std::round(q[j].y / (v * 2)) * v * 2 - q[j].y);
            }
        }
        if (p.shapes[1] > .01f && q.size() > 3) {
            std::vector<Point> smooth;
            float mix = p.shapes[1] / std::max(weights, .001f);
            for (size_t j = 0; j + 1 < q.size(); ++j) {
                Point a = q[j ? j - 1 : j], b = q[j], c = q[j + 1],
                      d = q[std::min(j + 2, q.size() - 1)];
                smooth.push_back(b);
                for (float t : {.3333f, .6667f}) {
                    float t2 = t * t, t3 = t2 * t;
                    Point curve{.5f * ((2 * b.x) + (-a.x + c.x) * t +
                                       (2 * a.x - 5 * b.x + 4 * c.x - d.x) * t2 +
                                       (-a.x + 3 * b.x - 3 * c.x + d.x) * t3),
                                .5f * ((2 * b.y) + (-a.y + c.y) * t +
                                       (2 * a.y - 5 * b.y + 4 * c.y - d.y) * t2 +
                                       (-a.y + 3 * b.y - 3 * c.y + d.y) * t3)};
                    smooth.push_back(
                        {b.x + (c.x - b.x) * t + (curve.x - b.x - (c.x - b.x) * t) * mix,
                         b.y + (c.y - b.y) * t + (curve.y - b.y - (c.y - b.y) * t) * mix});
                }
            }
            smooth.push_back(q.back());
            q = std::move(smooth);
        }
        auto segment = [&](Point a, Point b) {
            float d = std::max(distance(a, b), .001f),
                  half = std::max(.6f, p.width * scale * .5f) + 1.f;
            float nx = -(b.y - a.y) / d * half, ny = (b.x - a.x) / d * half;
            auto v = [&](Point at, float side) {
                return Vertex{
                    at.x + (side * nx), at.y + (side * ny), color.r, color.g, color.b, alpha, side};
            };
            vertices.insert(vertices.end(),
                            {v(a, -1), v(a, 1), v(b, -1), v(b, -1), v(a, 1), v(b, 1)});
            statistics.drawnLength += d / std::max(sx, sy);
        };
        for (size_t j = 1; j < q.size(); ++j) {
            if (p.shapes[3] > 0 &&
                random01(s.id ^ hash(j) ^ p.seed ^ hash(window)) < p.shapes[3] * .33f)
                continue;
            Point a = q[j - 1], b = q[j];
            float glitch = p.shapes[2] / std::max(weights, .001f);
            if (glitch > .01f) {
                Point bend = (hash(s.id + j) % 2) ? Point{b.x, a.y} : Point{a.x, b.y};
                Point mid{(a.x + b.x) * .5f, (a.y + b.y) * .5f};
                bend = {mid.x + (bend.x - mid.x) * glitch, mid.y + (bend.y - mid.y) * glitch};
                segment(a, bend);
                segment(bend, b);
            } else
                segment(a, b);
            if (vertices.size() > 400000)
                break;
        }
        ++statistics.strokes;
    }
    statistics.vertices = int(vertices.size());
    return vertices;
}
} // namespace kira
