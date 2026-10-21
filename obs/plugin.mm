#include <obs-module.h>
#include <util/platform.h>
#import "KRIPC.h"
#include <atomic>
#include <mutex>
#include <string>
#include <unordered_set>

OBS_DECLARE_MODULE()
static dispatch_group_t inventoryJobs = dispatch_group_create();
static std::atomic<bool> unloading{false};
MODULE_EXPORT const char *obs_module_description(void) {
    return "KiraRaki real-time contour filter and transparent source";
}
MODULE_EXPORT const char *obs_module_name(void) { return "KiraRaki"; }

struct KiraSource {
    obs_source_t *context = nullptr;
    bool filter = false, rendering = false, cycleWarning = false;
    uint64_t lastInventory = 0;
    std::atomic<bool> inventoryPending{false};
    std::atomic<int> mode{0};
    KRClient *client;
    NSString *sourceID;
    std::string target;
    std::mutex lock;
    gs_texrender_t *capture = nullptr;
    gs_stagesurf_t *stage[3] = {};
    uint64_t stagePTS[3] = {};
    bool filled[3] = {};
    int index = 0;
    gs_texture_t *output = nullptr;
    uint32_t width = 1920, height = 1080;
    uint64_t lastCapture = 0, lastOutput = 0;
    int audioMix = -1;
    dispatch_queue_t audioQueue =
        dispatch_queue_create("jp.meowkawaii.kira.obs-audio", DISPATCH_QUEUE_SERIAL);
};
static bool graphContains(obs_source_t *root, obs_source_t *needle,
                          std::unordered_set<obs_source_t *> &visited, int depth = 0) {
    if (root == needle)
        return true;
    if (!root || visited.count(root))
        return false;
    if (depth > 64)
        return true;
    visited.insert(root);
    struct Check {
        obs_source_t *n;
        std::unordered_set<obs_source_t *> *v;
        int depth;
        bool found = false;
    } check{needle, &visited, depth};
    if (strcmp(obs_source_get_unversioned_id(root), "kiraraki_source") == 0) {
        obs_data_t *s = obs_source_get_settings(root);
        obs_source_t *target = obs_get_source_by_uuid(obs_data_get_string(s, "target_uuid"));
        bool found = target && graphContains(target, needle, visited, depth + 1);
        obs_source_release(target);
        obs_data_release(s);
        if (found)
            return true;
    }
    obs_source_enum_active_sources(
        root,
        [](obs_source_t *, obs_source_t *child, void *p) {
            auto *c = (Check *)p;
            if (!c->found)
                c->found = graphContains(child, c->n, *c->v, c->depth + 1);
        },
        &check);
    return check.found;
}
static void audioCallback(void *opaque, size_t mix, struct audio_data *audio) {
    @autoreleasepool {
        auto *s = (KiraSource *)opaque;
        KRClient *client = s->client;
        NSString *source;
        {
            std::lock_guard<std::mutex> g(s->lock);
            source = s->sourceID;
        }
        if (!source || !client.connected || audio->frames > 48000)
            return;
        NSData *data = [NSData dataWithBytes:audio->data[0]
                                      length:audio->frames * sizeof(float) * 2];
        uint64_t pts = audio->timestamp;
        dispatch_async(s->audioQueue, ^{
            [client sendStereoAudio:data pts:pts source:source];
        });
    }
}
static void update(void *opaque, obs_data_t *settings) {
    auto *s = (KiraSource *)opaque;
    s->mode = (int)obs_data_get_int(settings, "output_mode");
    {
        std::lock_guard<std::mutex> g(s->lock);
        s->target = obs_data_get_string(settings, "target_uuid");
    }
    int next = (int)obs_data_get_int(settings, "audio_mix") - 1;
    if (next != s->audioMix) {
        if (s->audioMix >= 0)
            audio_output_disconnect(obs_get_audio(), s->audioMix, audioCallback, s);
        s->audioMix = -1;
        if (next >= 0 && next < 6) {
            audio_convert_info convert{};
            convert.samples_per_sec = 48000;
            convert.format = AUDIO_FORMAT_FLOAT;
            convert.speakers = SPEAKERS_STEREO;
            if (audio_output_connect(obs_get_audio(), next, &convert, audioCallback, s))
                s->audioMix = next;
        }
    }
}
static void *create(obs_data_t *settings, obs_source_t *context, bool filter) {
    auto *s = new KiraSource;
    s->context = context;
    s->filter = filter;
    s->sourceID = [@"obs:audio:" stringByAppendingString:@(obs_source_get_uuid(context))];
    s->client = [KRClient new];
    [s->client connect];
    update(s, settings);
    return s;
}
static void *createFilter(obs_data_t *s, obs_source_t *c) { return create(s, c, true); }
static void *createSource(obs_data_t *s, obs_source_t *c) { return create(s, c, false); }
static void destroy(void *opaque) {
    auto *s = (KiraSource *)opaque;
    if (s->audioMix >= 0)
        audio_output_disconnect(obs_get_audio(), s->audioMix, audioCallback, s);
    [s->client disconnect];
    obs_enter_graphics();
    gs_texrender_destroy(s->capture);
    gs_texture_destroy(s->output);
    for (auto *stage : s->stage)
        gs_stagesurface_destroy(stage);
    obs_leave_graphics();
    delete s;
}
static void defaultsFilter(obs_data_t *d) {
    obs_data_set_default_int(d, "output_mode", 0);
    obs_data_set_default_int(d, "audio_mix", 0);
}
static void defaultsSource(obs_data_t *d) {
    obs_data_set_default_int(d, "output_mode", 2);
    obs_data_set_default_int(d, "audio_mix", 0);
}
static obs_properties_t *properties(void *opaque) {
    auto *s = (KiraSource *)opaque;
    obs_properties_t *p = obs_properties_create();
    if (!s || !s->filter) {
        obs_property_t *list =
            obs_properties_add_list(p, "target_uuid", "解析するソース / シーン",
                                    OBS_COMBO_TYPE_LIST, OBS_COMBO_FORMAT_STRING);
        obs_property_list_add_string(list, "Macアプリの映像", "");
        obs_enum_sources(
            [](void *param, obs_source_t *source) {
                auto *list = (obs_property_t *)param;
                obs_property_list_add_string(list, obs_source_get_name(source),
                                             obs_source_get_uuid(source));
                return true;
            },
            list);
        obs_enum_scenes(
            [](void *param, obs_source_t *source) {
                auto *list = (obs_property_t *)param;
                obs_property_list_add_string(list, obs_source_get_name(source),
                                             obs_source_get_uuid(source));
                return true;
            },
            list);
    }
    auto *mode = obs_properties_add_list(p, "output_mode", "映像出力", OBS_COMBO_TYPE_LIST,
                                         OBS_COMBO_FORMAT_INT);
    obs_property_list_add_int(mode, "元映像と合成", 0);
    obs_property_list_add_int(mode, "黒背景に線のみ", 1);
    obs_property_list_add_int(mode, "透明 RGBA", 2);
    auto *audio = obs_properties_add_list(p, "audio_mix", "音反応 / 録画に使うOBSミックス",
                                          OBS_COMBO_TYPE_LIST, OBS_COMBO_FORMAT_INT);
    obs_property_list_add_int(audio, "音声を取得しない", 0);
    for (int i = 1; i <= 6; i++) {
        char name[40];
        snprintf(name, sizeof(name), "ミックス / トラック %d", i);
        obs_property_list_add_int(audio, name, i);
    }
    obs_properties_add_text(p, "instructions",
                            "線の表現・色・プリセット・録画はKiraRakiアプリで操作します。接続が切れ"
                            "た場合、フィルタは元映像、独立ソースは透明に戻ります。",
                            OBS_TEXT_INFO);
    return p;
}
static uint32_t width(void *opaque) { return ((KiraSource *)opaque)->width; }
static uint32_t height(void *opaque) { return ((KiraSource *)opaque)->height; }
static void fallback(KiraSource *s) {
    if (s->filter)
        obs_source_skip_video_filter(s->context);
}
static void drawOutput(KiraSource *s) {
    IOSurface *surface = [s->client latestSurface];
    NSDictionary *m = s->client.latestMetadata;
    if (!surface || KRClockNS() - [m[@"renderedNS"] unsignedLongLongValue] > 500000000) {
        fallback(s);
        return;
    }
    uint64_t frame = [m[@"frameID"] unsignedLongLongValue];
    if (!s->output || gs_texture_get_width(s->output) != surface.width ||
        gs_texture_get_height(s->output) != surface.height) {
        gs_texture_destroy(s->output);
        s->output = gs_texture_create((uint32_t)surface.width, (uint32_t)surface.height, GS_BGRA, 1,
                                      nullptr, GS_DYNAMIC);
        s->lastOutput = UINT64_MAX;
    }
    if (s->lastOutput != frame) {
        [surface lockWithOptions:kIOSurfaceLockReadOnly seed:nullptr];
        gs_texture_set_image(s->output, (const uint8_t *)surface.baseAddress,
                             (uint32_t)surface.bytesPerRow, false);
        [surface unlockWithOptions:kIOSurfaceLockReadOnly seed:nullptr];
        s->lastOutput = frame;
    }
    s->width = (uint32_t)surface.width;
    s->height = (uint32_t)surface.height;
    gs_blend_state_push();
    gs_blend_function(GS_BLEND_ONE, GS_BLEND_INVSRCALPHA);
    gs_effect_t *e = obs_get_base_effect(OBS_EFFECT_DEFAULT);
    gs_effect_set_texture(gs_effect_get_param_by_name(e, "image"), s->output);
    while (gs_effect_loop(e, "Draw"))
        gs_draw_sprite(s->output, 0, 0, 0);
    gs_blend_state_pop();
}
static void render(void *opaque, gs_effect_t *) {
    @autoreleasepool {
        auto *s = (KiraSource *)opaque;
        if (s->rendering) {
            fallback(s);
            return;
        }
        s->rendering = true;
        obs_source_t *target = nullptr;
        bool release = false;
        std::string uuid;
        {
            std::lock_guard<std::mutex> g(s->lock);
            uuid = s->target;
        }
        if (s->filter)
            target = obs_filter_get_target(s->context);
        else if (!uuid.empty()) {
            target = obs_get_source_by_uuid(uuid.c_str());
            release = true;
        }
        if (!target) {
            if (!s->filter && uuid.empty()) {
                [s->client requestPreview:@"app-main"];
                drawOutput(s);
            } else
                fallback(s);
            s->rendering = false;
            return;
        }
        std::unordered_set<obs_source_t *> visited;
        if (!s->filter && graphContains(target, s->context, visited)) {
            if (!s->cycleWarning)
                blog(LOG_WARNING, "[KiraRaki] Cyclic source/scene reference rejected");
            s->cycleWarning = true;
            if (release)
                obs_source_release(target);
            s->rendering = false;
            return;
        }
        s->cycleWarning = false;
        uint32_t w = obs_source_get_base_width(target), h = obs_source_get_base_height(target);
        uint64_t now = obs_get_video_frame_time();
        NSString *sourceID = [@"obs:"
            stringByAppendingString:@(obs_source_get_uuid(
                                        s->filter ? obs_filter_get_parent(s->context) : target))];
        {
            std::lock_guard<std::mutex> g(s->lock);
            s->sourceID = sourceID;
        }
        bool reuse = false;
        if (!s->filter)
            obs_source_enum_filters(
                target,
                [](obs_source_t *, obs_source_t *f, void *p) {
                    if (obs_source_enabled(f) &&
                        strcmp(obs_source_get_unversioned_id(f), "kiraraki_filter") == 0)
                        *(bool *)p = true;
                },
                &reuse);
        if (w && h && w <= 7680 && h <= 4320 && now != s->lastCapture) {
            if (!s->capture)
                s->capture = gs_texrender_create(GS_BGRA, GS_ZS_NONE);
            if (s->width != w || s->height != h) {
                for (int i = 0; i < 3; i++) {
                    gs_stagesurface_destroy(s->stage[i]);
                    s->stage[i] = nullptr;
                    s->filled[i] = false;
                }
            }
            s->width = w;
            s->height = h;
            gs_texrender_reset(s->capture);
            gs_blend_state_push();
            gs_blend_function(GS_BLEND_ONE, GS_BLEND_ZERO);
            if (gs_texrender_begin_with_color_space(s->capture, w, h, GS_CS_SRGB)) {
                vec4 clear{};
                gs_clear(GS_CLEAR_COLOR, &clear, 0, 0);
                gs_ortho(0, float(w), 0, float(h), -100, 100);
                uint32_t flags = obs_source_get_output_flags(target);
                if (s->filter && target == obs_filter_get_parent(s->context) &&
                    !(flags & (OBS_SOURCE_CUSTOM_DRAW | OBS_SOURCE_ASYNC)))
                    obs_source_default_render(target);
                else
                    obs_source_video_render(target);
                gs_texrender_end(s->capture);
            }
            gs_blend_state_pop();
            if (reuse) {
                [s->client requestPreview:sourceID mode:s->mode.load()];
                s->lastCapture = now;
                drawOutput(s);
                if (release)
                    obs_source_release(target);
                s->rendering = false;
                return;
            }
            int read = (s->index + 1) % 3;
            if (s->filled[read]) {
                uint8_t *bytes = nullptr;
                uint32_t stride = 0;
                if (gs_stagesurface_map(s->stage[read], &bytes, &stride)) {
                    [s->client submitBGRA:bytes
                                    width:w
                                   height:h
                                 rowBytes:stride
                                      pts:s->stagePTS[read]
                                   source:sourceID
                                     mode:s->mode.load()];
                    gs_stagesurface_unmap(s->stage[read]);
                }
                s->filled[read] = false;
            }
            if (!s->stage[s->index])
                s->stage[s->index] = gs_stagesurface_create(w, h, GS_BGRA);
            gs_texture_t *tex = gs_texrender_get_texture(s->capture);
            if (tex && s->stage[s->index]) {
                gs_stage_texture(s->stage[s->index], tex);
                s->stagePTS[s->index] = now;
                s->filled[s->index] = true;
            }
            s->index = (s->index + 1) % 3;
            s->lastCapture = now;
        }
        drawOutput(s);
        if (release)
            obs_source_release(target);
        s->rendering = false;
    }
}
static void tick(void *opaque, float) {
    auto *s = (KiraSource *)opaque;
    uint64_t now = KRClockNS();
    if (unloading.load())
        return;
    if (now - s->lastInventory < 1000000000 || s->inventoryPending.exchange(true))
        return;
    s->lastInventory = now;
    dispatch_group_enter(inventoryJobs);
    obs_source_t *context = obs_source_get_ref(s->context);
    KRClient *client = s->client;
    bool filter = s->filter;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            NSMutableArray *sources = [NSMutableArray array];
            auto collect = [](void *ptr, obs_source_t *source) {
                [(__bridge NSMutableArray *)ptr addObject:@{
                    @"uuid" : @(obs_source_get_uuid(source)),
                    @"name" : @(obs_source_get_name(source))
                }];
                return true;
            };
            obs_enum_sources(collect, (__bridge void *)sources);
            obs_enum_scenes(collect, (__bridge void *)sources);
            obs_data_t *settings = obs_source_get_settings(context);
            NSString *instanceID = @(obs_source_get_uuid(context));
            obs_source_t *parent = filter ? obs_filter_get_parent(context) : nullptr;
            NSString *inputID =
                parent
                    ? [@"obs:" stringByAppendingString:@(obs_source_get_uuid(parent))]
                    : [@"obs:"
                          stringByAppendingString:@(obs_data_get_string(settings, "target_uuid"))];
            if (!filter && !strlen(obs_data_get_string(settings, "target_uuid")))
                inputID = @"app-main";
            NSDictionary *instance = @{
                @"instanceID" : instanceID,
                @"name" : @(obs_source_get_name(context)),
                @"filter" : @(filter),
                @"targetUUID" : parent ? @(obs_source_get_uuid(parent))
                                       : @(obs_data_get_string(settings, "target_uuid")),
                @"sourceID" : inputID,
                @"audioSourceID" :
                        (!filter && !strlen(obs_data_get_string(settings, "target_uuid")))
                    ? [@"obs:audio:" stringByAppendingString:instanceID]
                    : inputID,
                @"outputMode" : @(obs_data_get_int(settings, "output_mode")),
                @"audioMix" : @(obs_data_get_int(settings, "audio_mix"))
            };
            obs_data_release(settings);
            [client publishOBS:@{@"sources" : sources, @"instance" : instance}
                         reply:^(NSDictionary *command) {
                             if (command.count) {
                                 obs_data_t *changes = obs_data_create();
                                 if (command[@"targetUUID"] && !filter)
                                     obs_data_set_string(changes, "target_uuid",
                                                         [command[@"targetUUID"] UTF8String]);
                                 if (command[@"outputMode"])
                                     obs_data_set_int(changes, "output_mode",
                                                      [command[@"outputMode"] longLongValue]);
                                 if (command[@"audioMix"])
                                     obs_data_set_int(changes, "audio_mix",
                                                      [command[@"audioMix"] longLongValue]);
                                 obs_source_update(context, changes);
                                 obs_data_release(changes);
                             }
                             s->inventoryPending = false;
                             obs_source_release(context);
                             dispatch_group_leave(inventoryJobs);
                         }];
        }
    });
}
MODULE_EXPORT bool obs_module_load(void) {
    obs_source_info filter{};
    filter.id = "kiraraki_filter";
    filter.type = OBS_SOURCE_TYPE_FILTER;
    filter.output_flags = OBS_SOURCE_VIDEO | OBS_SOURCE_CUSTOM_DRAW;
    filter.get_name = [](void *) { return "KiraRaki 輪郭フィルタ"; };
    filter.create = createFilter;
    filter.destroy = destroy;
    filter.update = update;
    filter.get_defaults = defaultsFilter;
    filter.get_properties = properties;
    filter.video_render = render;
    filter.video_tick = tick;
    obs_register_source(&filter);
    obs_source_info source{};
    source.id = "kiraraki_source";
    source.type = OBS_SOURCE_TYPE_INPUT;
    source.output_flags = OBS_SOURCE_VIDEO | OBS_SOURCE_CUSTOM_DRAW;
    source.get_name = [](void *) { return "KiraRaki 線画ソース"; };
    source.create = createSource;
    source.destroy = destroy;
    source.update = update;
    source.get_defaults = defaultsSource;
    source.get_properties = properties;
    source.video_render = render;
    source.video_tick = tick;
    source.get_width = width;
    source.get_height = height;
    source.icon_type = OBS_ICON_TYPE_COLOR;
    obs_register_source(&source);
    blog(LOG_INFO, "[KiraRaki] Registered filter and source; XPC/IOSurface copy transport");
    return true;
}

MODULE_EXPORT void obs_module_unload(void) {
    unloading = true;
    dispatch_group_wait(inventoryJobs, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
}
