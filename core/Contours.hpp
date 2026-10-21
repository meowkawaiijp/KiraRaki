#pragma once
#include <array>
#include <cstdint>
#include <vector>

namespace kira {
struct Point {
    float x = 0, y = 0;
};
struct Feature {
    float edge, outer, texture, motion, gx, gy, flowX, flowY;
};
struct Color {
    float r, g, b;
};
struct Vertex {
    float x, y, r, g, b, a, side;
};
struct Parameters {
    float width = 3, distortion = .45f, density = .35f, threshold = .14f;
    float lifetime = 0.65f, tracking = .8f, updateHz = 12, irregularity = .5f;
    std::array<float, 4> shapes{1, .7f, .25f, .45f};
    std::array<float, 5> regions{.3f, .3f, .12f, .2f, .08f};
    std::array<float, 3> placement{.2f, .5f, .3f};
    float hueSpeed = .08f, hueOffset = 0, opacity = 1;
    int colorMode = 0, maxStrokes = 550, lossMode = 0;
    uint64_t seed = 873512;
    std::vector<Color> palette{{.04f, .8f, 1}, {1, .08f, .46f}, {.65f, .15f, 1}, {1, .7f, .05f}};
};
struct Stroke {
    uint64_t id;
    std::vector<Point> points;
    double birth, lastSeen;
    float confidence = 1;
    Point center;
};
struct Statistics {
    int candidates = 0, strokes = 0, vertices = 0;
    float candidateLength = 0, drawnLength = 0;
};
class Contours {
  public:
    std::vector<Vertex> update(const Feature *, int, int, int, int, double, const Parameters &);
    void reset();
    Statistics statistics;

  private:
    std::vector<Stroke> tracks;
    uint64_t nextID = 1;
    double lastPTS = -1;
    int lastW = 0, lastH = 0;
};
uint64_t hash(uint64_t);
float random01(uint64_t);
} // namespace kira
