#pragma once
#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
namespace kira {
struct RenderProfile {
    int width, flowRadius, maxStrokes, bloomDivisor, visionWidth;
    double visionInterval;
};
inline constexpr std::array<RenderProfile, 7> liveProfiles{{
    {640, 4, 550, 4, 512, .10},
    {640, 4, 550, 4, 448, .16},
    {544, 4, 500, 4, 448, .22},
    {480, 3, 420, 4, 384, .32},
    {416, 2, 320, 6, 320, .48},
    {352, 2, 250, 6, 320, .65},
    {320, 2, 180, 8, 256, .90},
}};
inline constexpr RenderProfile offlineProfile{960, 4, 1200, 2, 512, 0};
class AdaptiveRender {
    int level_ = 0, overload_ = 0, healthy_ = 0;
    double ema_ = 0;
public:
    int level() const { return level_; }
    void reset() { level_ = overload_ = healthy_ = 0; ema_ = 0; }
    RenderProfile profile(bool offline) const {
        return offline ? offlineProfile : liveProfiles[level_];
    }
    // Fixed 30fps design budget; dropped PTS must not conceal overload.
    void observe(double renderMS, double queueMS, bool enabled) {
        if (!enabled) { reset(); return; }
        if (!std::isfinite(renderMS) || !std::isfinite(queueMS) || renderMS < 0 || queueMS < 0)
            return;
        ema_ = ema_ == 0 ? renderMS : .92 * ema_ + .08 * renderMS;
        if (ema_ > 29 || queueMS > 25) {
            healthy_ = 0;
            if (++overload_ >= 8) {
                level_ = std::min(level_ + 1, int(liveProfiles.size()) - 1);
                overload_ = 0;
            }
        } else if (ema_ < 19 && queueMS < 8) {
            overload_ = 0;
            if (++healthy_ >= 120) {
                level_ = std::max(0, level_ - 1);
                healthy_ = 0;
            }
        } else {
            overload_ = healthy_ = 0;
        }
    }
    double visionInterval(bool offline, bool adaptive, double inferenceMS) const {
        const double base = profile(offline).visionInterval;
        if (offline || !adaptive || !std::isfinite(inferenceMS)) return base;
        return std::max(base, std::clamp(inferenceMS * .002, .10, 1.50));
    }
};
template <std::size_t N = 120> class RollingSamples {
    static_assert(N > 0);
    std::array<double, N> values_{};
    std::size_t next_ = 0, size_ = 0;
public:
    void clear() { next_ = size_ = 0; }
    std::size_t size() const { return size_; }
    void push(double x) {
        if (!std::isfinite(x) || x < 0) return;
        values_[next_] = x;
        next_ = (next_ + 1) % N;
        size_ = std::min(size_ + 1, N);
    }
    double mean() const {
        double sum = 0;
        for (std::size_t i = 0; i < size_; ++i) sum += values_[i];
        return size_ ? sum / size_ : 0;
    }
    double p95() const {
        if (!size_) return 0;
        auto sorted = values_;
        const auto index = (95 * size_ + 99) / 100 - 1;
        std::nth_element(sorted.begin(), sorted.begin() + index, sorted.begin() + size_);
        return sorted[index];
    }
};
} // namespace kira
