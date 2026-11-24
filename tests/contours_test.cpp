#include "Contours.hpp"
#include <algorithm>
#include <array>
#include <bit>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <iostream>
#include <stdexcept>
#include <vector>

namespace {
void check(bool ok, const char *message) {
    if (!ok)
        throw std::runtime_error(message);
}
struct Digest {
    uint64_t value = 14695981039346656037ULL;
    void add(uint32_t x) {
        value ^= x;
        value *= 1099511628211ULL;
    }
    void addFloat(float x) {
        check(std::isfinite(x), "non-finite output");
        add(std::bit_cast<uint32_t>(x));
    }
    void frame(const std::vector<kira::Vertex> &v, const kira::Statistics &s) {
        check(v.size() % 6 == 0 && v.size() <= 400000, "invalid ribbon vertex count");
        check(s.vertices == int(v.size()), "statistics mismatch");
        add(uint32_t(v.size()));
        add(uint32_t(s.strokes));
        add(uint32_t(s.candidates));
        addFloat(s.candidateLength);
        addFloat(s.drawnLength);
        for (const auto &p : v)
            for (float x : {p.x, p.y, p.r, p.g, p.b, p.a, p.side})
                addFloat(x);
    }
};
void fill(std::vector<kira::Feature> &f, int w, int h, int shift, bool gap) {
    std::fill(f.begin(), f.end(), kira::Feature{});
    if (gap)
        return;
    // Long connected ridges, intersections, short gaps and high-motion segments.
    for (int y = 8; y < h - 8; ++y)
        for (int x = 8; x < w - 8; ++x) {
            const bool horizontal = (y - shift + 1000 * 18) % 18 == 0 && x % 49 != 0;
            const bool vertical = (x + shift) % 53 == 0;
            if (!horizontal && !vertical)
                continue;
            f[size_t(y) * w + x] = {0.85f, 0.65f, 0.3f, shift ? 0.4f : 0.f,
                                     vertical ? 0.8f : 0.f, horizontal ? 0.8f : 0.f,
                                     shift ? 0.25f : 0.f, shift ? 1.f : 0.f};
        }
}
uint64_t run(int w, int h, const kira::Parameters &p, bool seek, double &milliseconds) {
    std::vector<kira::Feature> f(size_t(w) * h);
    kira::Contours a, b;
    Digest digest, repeated;
    size_t totalVertices = 0;
    for (int frame = 0; frame < 36; ++frame) {
        const bool gap = frame >= 15 && frame < 20;
        fill(f, w, h, frame < 5 ? 0 : frame % 18, gap);
        double pts = seek && frame >= 26 ? (frame - 26) / 30.0 : frame / 30.0;
        auto start = std::chrono::steady_clock::now();
        auto v = a.update(f.data(), w, h, 1920, 1080, pts, p);
        milliseconds += std::chrono::duration<double, std::milli>(
                            std::chrono::steady_clock::now() - start).count();
        digest.frame(v, a.statistics);
        auto v2 = b.update(f.data(), w, h, 1920, 1080, pts, p);
        repeated.frame(v2, b.statistics);
        check(digest.value == repeated.value, "deterministic replay mismatch");
        totalVertices += v.size();
    }
    check(totalVertices > 0, "fixture produced no geometry");
    // Reset must clear history, even though scratch capacity is retained.
    a.reset();
    b = kira::Contours{};
    fill(f, w, h, 0, false);
    Digest reset, fresh;
    auto v = a.update(f.data(), w, h, 1920, 1080, 0, p);
    auto v2 = b.update(f.data(), w, h, 1920, 1080, 0, p);
    reset.frame(v, a.statistics);
    fresh.frame(v2, b.statistics);
    check(reset.value == fresh.value, "reset differs from a fresh instance");
    return digest.value;
}
} // namespace

int main() {
    try {
        kira::Parameters p;
        double ms = 0;
        std::cout << std::hex << run(384, 216, p, false, ms) << '\n';
        p.shapes = {.35f, .3f, .2f, .15f};
        p.lossMode = 2;
        p.jaggedSpacing = 16;
        std::cout << std::hex << run(640, 360, p, true, ms) << '\n';
        p.shapes = {0, 1, 0, 0};
        p.lossMode = 1;
        p.density = .8f;
        p.colorMode = 1;
        p.maxStrokes = 1200;
        std::cout << std::hex << run(960, 540, p, false, ms) << '\n';
        std::cerr << "Contour update mean (108 synthetic frames): " << ms / 108 << " ms\n";
        return 0;
    } catch (const std::exception &e) {
        std::cerr << e.what() << '\n';
        return 1;
    }
}
