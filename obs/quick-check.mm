// One short, local integration check; uses libobs without changing the user's OBS scene collection.
#include <obs.h>
#include <util/platform.h>
#import <AppKit/AppKit.h>
#include <atomic>
#include <vector>
#include <algorithm>
#include <cstdio>

struct Capture {
    std::atomic<int> frames{0}, colorPixels{0};
};
static void received(void *ptr, video_data *f) {
    auto *c = (Capture *)ptr;
    int colored = 0;
    for (int y = 0; y < 360; y += 2)
        for (int x = 0; x < 640; x += 2) {
            const auto *p = f->data[0] + y * f->linesize[0] + x * 4;
            int hi = std::max({p[0], p[1], p[2]}), lo = std::min({p[0], p[1], p[2]});
            if (hi - lo > 20)
                colored++;
        }
    c->colorPixels = std::max(c->colorPixels.load(), colored);
    c->frames++;
}
int main(int argc, char **argv) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        if (argc < 3) {
            fprintf(stderr, "Usage: KiraRakiOBSCheck plugin-binary metal|opengl [source]\n");
            return 2;
        }
        if (!obs_startup("ja-JP", nullptr, nullptr))
            return 1;
        obs_add_data_path(
            "/Applications/OBS.app/Contents/Frameworks/libobs.framework/Versions/A/Resources");
        obs_video_info v{};
        std::string module =
            std::string("/Applications/OBS.app/Contents/Frameworks/libobs-") + argv[2] + ".dylib";
        v.graphics_module = module.c_str();
        v.fps_num = 30;
        v.fps_den = 1;
        v.base_width = v.output_width = 640;
        v.base_height = v.output_height = 360;
        v.output_format = VIDEO_FORMAT_BGRA;
        v.colorspace = VIDEO_CS_709;
        v.range = VIDEO_RANGE_FULL;
        v.scale_type = OBS_SCALE_BILINEAR;
        int result = obs_reset_video(&v);
        if (result != OBS_VIDEO_SUCCESS) {
            fprintf(stderr, "obs_reset_video: %d\n", result);
            obs_shutdown();
            return 1;
        }
        obs_audio_info audio{48000, SPEAKERS_STEREO};
        obs_reset_audio(&audio);
        obs_module_t *plugin = nullptr;
        if (obs_open_module(&plugin, argv[1], ".") != MODULE_SUCCESS || !obs_init_module(plugin)) {
            fprintf(stderr, "Plugin load failed\n");
            obs_shutdown();
            return 1;
        }
        obs_source_info fixture{};
        fixture.id = "kira_check_fixture";
        fixture.type = OBS_SOURCE_TYPE_INPUT;
        fixture.output_flags = OBS_SOURCE_ASYNC_VIDEO;
        fixture.get_name = [](void *) { return "KiraRaki fixture"; };
        fixture.create = [](obs_data_t *, obs_source_t *s) -> void * { return s; };
        fixture.destroy = [](void *) {};
        obs_register_source(&fixture);
        obs_source_t *base =
            obs_source_create("kira_check_fixture", "KiraRaki check input", nullptr, nullptr);
        obs_source_t *filter =
            obs_source_create("kiraraki_filter", "KiraRaki check filter", nullptr, nullptr);
        obs_source_filter_add(base, filter);
        obs_source_t *output = base;
        obs_source_t *source = nullptr;
        if (argc > 3) {
            obs_data_t *settings = obs_data_create();
            obs_data_set_string(settings, "target_uuid", obs_source_get_uuid(base));
            obs_data_set_int(settings, "output_mode", 2);
            source =
                obs_source_create("kiraraki_source", "KiraRaki check source", settings, nullptr);
            obs_data_release(settings);
            output = source;
        }
        obs_set_output_source(0, output);
        Capture capture;
        video_scale_info scale{};
        scale.format = VIDEO_FORMAT_BGRA;
        scale.width = 640;
        scale.height = 360;
        scale.range = VIDEO_RANGE_FULL;
        scale.colorspace = VIDEO_CS_709;
        obs_add_raw_video_callback(&scale, received, &capture);
        std::vector<uint8_t> pixels(640 * 360 * 4);
        for (int frame = 0; frame < 75; frame++) {
            for (int y = 0; y < 360; y++)
                for (int x = 0; x < 640; x++) {
                    int dx = x - 320, dy = y - 180;
                    uint8_t n = dx * dx + dy * dy < 100 * 100 ? 200 : 24;
                    size_t i = (y * 640 + x) * 4;
                    pixels[i] = pixels[i + 1] = pixels[i + 2] = n;
                    pixels[i + 3] = 255;
                }
            obs_source_frame f{};
            f.data[0] = pixels.data();
            f.linesize[0] = 640 * 4;
            f.width = 640;
            f.height = 360;
            f.timestamp = os_gettime_ns();
            f.format = VIDEO_FORMAT_BGRA;
            f.full_range = true;
            obs_source_output_video(base, &f);
            os_sleep_ms(34);
            if (capture.frames > 12 && capture.colorPixels > 40)
                break;
        }
        obs_remove_raw_video_callback(received, &capture);
        obs_set_output_source(0, nullptr);
        obs_source_release(source);
        obs_source_filter_remove(base, filter);
        obs_source_release(filter);
        obs_source_release(base);
        int colored = capture.colorPixels, frames = capture.frames;
        obs_shutdown();
        printf("{\"renderer\":\"%s\",\"mode\":\"%s\",\"outputFrames\":%d,\"coloredPixels\":%d}\n",
               argv[2], argc > 3 ? "source" : "filter", frames, colored);
        return colored > 40 ? 0 : 1;
    }
}
