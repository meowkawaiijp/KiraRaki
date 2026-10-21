#import "KRMedia.h"
#import "KRIPC.h"
#import <AppKit/AppKit.h>
#include <cstdio>
#include <cmath>
#include <thread>

static IOSurface *demo(int frame, int w, int h) {
    IOSurface *s = KRMakeSurface(w, h);
    [s lockWithOptions:0 seed:nullptr];
    auto *b = (uint8_t *)s.baseAddress;
    for (int y = 0; y < h; y++)
        for (int x = 0; x < w; x++) {
            float cx = w * (.5 + .15 * std::sin(frame * .08)), cy = h * .48, dx = x - cx,
                  dy = y - cy;
            bool circle = dx * dx + dy * dy < h * h * .08;
            bool box = x > w * .12 && x < w * .3 && y > h * .2 && y < h * .8;
            int i = int(y * s.bytesPerRow + x * 4);
            uint8_t v = (circle || box) ? 210 : 18;
            b[i] = v;
            b[i + 1] = (circle ? 140 : v);
            b[i + 2] = (box ? 90 : v);
            b[i + 3] = 255;
        }
    [s unlockWithOptions:0 seed:nullptr];
    return s;
}
static NSData *tone(int frame) {
    NSMutableData *data = [NSMutableData dataWithLength:1600 * sizeof(float)];
    float *s = (float *)data.mutableBytes;
    for (int i = 0; i < 1600; ++i)
        s[i] = .15f * std::sin((frame * 1600 + i) * 440.0 * 6.283185307179586 / 48000);
    return data;
}
static void json(NSDictionary *d) {
    NSData *b = [NSJSONSerialization dataWithJSONObject:d
                                                options:NSJSONWritingSortedKeys
                                                  error:nil];
    fwrite(b.bytes, 1, b.length, stdout);
    puts("");
    fflush(stdout);
}
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSMutableDictionary *args = [NSMutableDictionary dictionary];
        NSString *command = argc > 1 ? @(argv[1]) : @"help";
        for (int i = 2; i < argc; ++i) {
            NSString *k = @(argv[i]);
            if ([k hasPrefix:@"--"]) {
                args[[k substringFromIndex:2]] =
                    (i + 1 < argc && strncmp(argv[i + 1], "--", 2) != 0) ? @(argv[++i]) : @"yes";
            }
        }
        NSString*shader=args[@"shader"]?:[NSBundle.mainBundle pathForResource:@"Effects" ofType:@"metal"]?:[[@(argv[0])stringByDeletingLastPathComponent]stringByAppendingPathComponent:@"../Resources/Effects.metal"];
        NSError *err = nil;
        NSDictionary *preset = KRDefaultPreset();
        if (args[@"preset"]) {
            NSData *d = [NSData dataWithContentsOfFile:args[@"preset"]];
            preset = d ? KRValidatePreset(
                             [NSJSONSerialization JSONObjectWithData:d options:0 error:&err], &err)
                       : nil;
            if (!preset) {
                fprintf(stderr, "Invalid preset: %s\n", err.localizedDescription.UTF8String);
                return 2;
            }
        }
        if ([command isEqual:@"thumbnail"]) {
            if (!args[@"input"] || !args[@"output"])
                return 2;
            AVAssetImageGenerator *g = [[AVAssetImageGenerator alloc]
                initWithAsset:[AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:args[@"input"]]
                                                  options:nil]];
            g.appliesPreferredTrackTransform = YES;
            CGImageRef im = [g copyCGImageAtTime:kCMTimeZero actualTime:nullptr error:&err];
            if (!im) {
                fprintf(stderr, "%s\n", err.localizedDescription.UTF8String);
                return 1;
            }
            NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithCGImage:im];
            [[bitmap representationUsingType:NSBitmapImageFileTypePNG
                                  properties:@{}] writeToFile:args[@"output"] atomically:YES];
            CGImageRelease(im);
            return 0;
        }
        if ([command isEqual:@"export"]) {
            if (!args[@"input"] || !args[@"output"])
                return 2;
            BOOL ok = KRExportMovie(
                [NSURL fileURLWithPath:args[@"input"]], [NSURL fileURLWithPath:args[@"output"]],
                shader, preset, args[@"codec"] ?: @"h264",
                args[@"mode"] ? [args[@"mode"] integerValue] : -1, ![args[@"mute"] isEqual:@"yes"],
                args[@"events"] ? [NSURL fileURLWithPath:args[@"events"]] : nil,
                ^(double p) {
                    json(@{@"progress" : @(p)});
                },
                &err);
            if (!ok) {
                fprintf(stderr, "%s\n", err.localizedDescription.UTF8String);
                return 1;
            }
            return 0;
        }
        if ([command isEqual:@"service-smoke"] || [command isEqual:@"status"]) {
            KRClient *c = [KRClient new];
            [c connect];
            for (int i = 0; i < 40 && !c.connected; i++)
                std::this_thread::sleep_for(std::chrono::milliseconds(50));
            if (!c.connected) {
                fprintf(stderr, "Render service unavailable\n");
                return 1;
            }
            dispatch_semaphore_t done = dispatch_semaphore_create(0);
            if ([command isEqual:@"status"]) {
                [c fetchStatus:^(NSDictionary *d) {
                    json(d);
                    dispatch_semaphore_signal(done);
                }];
            } else {
                c.onFrame = ^(IOSurface *s, NSDictionary *m) {
                    json(m);
                    dispatch_semaphore_signal(done);
                };
                IOSurface *in = demo(0, 640, 360);
                [c submitBGRA:in.baseAddress
                        width:in.width
                       height:in.height
                     rowBytes:in.bytesPerRow
                          pts:0
                       source:@"smoke"
                         mode:2];
            }
            long timeout =
                dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC));
            return timeout ? 1 : 0;
        }
        if ([command isEqual:@"record-demo"]) {
            if (!args[@"output"])
                return 2;
            KRClient *client = [KRClient new];
            [client connect];
            for (int i = 0; i < 40 && !client.connected; ++i)
                std::this_thread::sleep_for(std::chrono::milliseconds(50));
            if (!client.connected) {
                fprintf(stderr, "Render service unavailable\n");
                return 1;
            }
            dispatch_semaphore_t state = dispatch_semaphore_create(0),
                                 frameReady = dispatch_semaphore_create(0);
            __block BOOL started = NO;
            NSString *source = [@"record-demo:" stringByAppendingString:NSUUID.UUID.UUIDString];
            [client startRecording:@{
                @"path" : [NSURL fileURLWithPath:args[@"output"]].path,
                @"sourceID" : source,
                @"codec" : @"h264",
                @"audio" : @(args[@"tone"] != nil),
                @"audioSource" : @"video",
                @"replayEnabled" : @YES
            }
                reply:^(NSDictionary *r) {
                    started = [r[@"recording"] boolValue];
                    if (!started)
                        json(r);
                    dispatch_semaphore_signal(state);
                }];
            if (dispatch_semaphore_wait(state,
                                        dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) ||
                !started)
                return 1;
            client.onFrame = ^(IOSurface *s, NSDictionary *m) {
                dispatch_semaphore_signal(frameReady);
            };
            int frames = args[@"frames"] ? [args[@"frames"] intValue] : 12;
            BOOL success = frames > 0;
            for (int i = 0; i < frames && success; ++i) {
                @autoreleasepool {
                    IOSurface *input = demo(i, 640, 360);
                    uint64_t pts = uint64_t(i) * 1000000000 / 30;
                    success = [client submitBGRA:input.baseAddress
                                           width:640
                                          height:360
                                        rowBytes:input.bytesPerRow
                                             pts:pts
                                          source:source
                                            mode:0];
                    if (success)
                        success = dispatch_semaphore_wait(
                                      frameReady,
                                      dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0;
                    if (args[@"tone"])
                        [client sendAudio:tone(i) pts:pts source:source];
                    std::this_thread::sleep_for(std::chrono::milliseconds(30));
                }
            }
            __block BOOL saved = NO;
            [client stopRecording:^(NSDictionary *r) {
                json(r);
                saved = [r[@"success"] boolValue];
                dispatch_semaphore_signal(state);
            }];
            if (dispatch_semaphore_wait(state, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)))
                return 1;
            return success && saved ? 0 : 1;
        }
        if ([command isEqual:@"demo"]) {
            KREngine *e = [[KREngine alloc] initWithShader:shader error:&err];
            if (!e) {
                fprintf(stderr, "%s\n", err.localizedDescription.UTF8String);
                return 1;
            }
            int w = args[@"width"] ? [args[@"width"] intValue] : 1280,
                h = args[@"height"] ? [args[@"height"] intValue] : 720,
                frames = args[@"frames"] ? [args[@"frames"] intValue] : 30;
            NSMutableDictionary *p = [preset mutableCopy];
            p[@"analysisMode"] = @1;
            if (w <= 0 || h <= 0 || w > 7680 || h > 4320 || frames <= 0)
                return 2;
            if (args[@"mode"])
                p[@"outputMode"] = @([args[@"mode"] intValue]);
            KRMovieWriter *writer = nil;
            double ms = 0;
            for (int f = 0; f < frames; f++) {
                @autoreleasepool {
                    if (args[@"tone"])
                        [e audio:tone(f)];
                    IOSurface *out = [e render:demo(f, w, h)
                                      metadata:@{
                                          @"ptsNS" : @(uint64_t(f) * 1000000000 / 30),
                                          @"mode" : p[@"outputMode"]
                                      }
                                        preset:p
                                         error:&err];
                    if (!out) {
                        fprintf(stderr, "Render failed: %s\n", err.localizedDescription.UTF8String);
                        return 1;
                    }
                    ms += [e.statistics[@"processingMS"] doubleValue];
                    if (args[@"output"]) {
                        if (!writer)
                            writer = [[KRMovieWriter alloc]
                                initWithURL:[NSURL fileURLWithPath:args[@"output"]]
                                      width:w
                                     height:h
                                      codec:args[@"codec"] ?: @"h264"
                                      audio:args[@"tone"] != nil
                                   realtime:NO
                                      error:&err];
                        if (!writer || ![writer appendSurface:out pts:CMTimeMake(f, 30)]) {
                            fprintf(stderr, "Write failed: %s\n",
                                    err.localizedDescription.UTF8String);
                            return 1;
                        }
                        if (args[@"tone"] && ![writer appendMonoAudio:tone(f)
                                                                  pts:CMTimeMake(f, 30)]) {
                            fprintf(stderr, "Audio write failed\n");
                            return 1;
                        }
                    }
                }
            }
            if (writer && ![writer finish:&err]) {
                fprintf(stderr, "%s\n", err.localizedDescription.UTF8String);
                return 1;
            }
            json(@{
                @"frames" : @(frames),
                @"meanProcessingMS" : @(ms / frames),
                @"lastFrame" : e.statistics
            });
            return 0;
        }
        puts(
            "KiraRakiCLI demo|export|record-demo|status|service-smoke|thumbnail\n  --shader path "
            "--preset path --output path --codec h264|prores4444|hevc-alpha\n  export --input path "
            "[--events events.jsonl] [--mute]\n  demo [--frames 30] [--width 1280 --height 720]");
        return 0;
    }
}
