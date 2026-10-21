#import "KRIPC.h"
#import "KREngine.h"
#import "KRMedia.h"
#import <unistd.h>
#include <atomic>
#include <algorithm>
#include <mutex>

@interface KRSession : NSObject
@property KREngine *engine;
@property IOSurface *surface;
@property NSDictionary *metadata;
@property uint64_t lastActive;
@property uint64_t revision;
@property NSDictionary *effectivePreset;
@property NSDictionary *transitionFrom;
@property double transitionStart;
@end
@implementation KRSession
- (instancetype)init {
    if ((self = [super init]))
        _transitionStart = -1;
    return self;
}
@end

@interface KRHost : NSObject <KRRenderService, NSXPCListenerDelegate>
- (instancetype)initWithShader:(NSString *)path;
@end
@implementation KRHost {
    NSString *_shader;
    dispatch_queue_t _queue;
    NSMutableDictionary<NSString *, KRSession *> *_sessions;
    NSDictionary *_preset;
    uint64_t _revision;
    std::atomic<int> _pending;
    NSString *_latestSource;
    NSMutableDictionary *_recordOptions;
    KRMovieWriter *_movie, *_clean;
    uint64_t _recordOrigin, _lastPTS;
    NSFileHandle *_eventFile;
    NSUInteger _sequence, _dropped;
    NSString *_recordError;
    NSDictionary *_transitionFrom;
    double _transitionStart;
    uint64_t _recordLatestPTS, _recordLastClock, _recordAudioOrigin, _obsAudioLastClock,
        _obsPreviewLastNS;
    NSString *_obsAudioOwner, *_obsPreferredAudio;
    NSURL *_manifestURL;
    NSMutableDictionary *_manifest;
    dispatch_source_t _cleanup;
    NSArray *_obsSources;
    NSMutableDictionary<NSString *, NSDictionary *> *_obsInstances, *_obsCommands;
    std::mutex _requestLock;
    NSMutableDictionary<NSString *, NSNumber *> *_latestTickets;
    uint64_t _nextTicket;
}
- (instancetype)initWithShader:(NSString *)path {
    if ((self = [super init])) {
        _shader = path;
        _queue = dispatch_queue_create("jp.meowkawaii.kira.render", DISPATCH_QUEUE_SERIAL);
        _sessions = [NSMutableDictionary dictionary];
        _latestTickets = [NSMutableDictionary dictionary];
        _preset = KRDefaultPreset();
        _recordOrigin = UINT64_MAX;
        _recordAudioOrigin = UINT64_MAX;
        _transitionStart = -1;
        _cleanup = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
        dispatch_source_set_timer(_cleanup, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                                  5 * NSEC_PER_SEC, NSEC_PER_SEC);
        __weak KRHost *weak = self;
        dispatch_source_set_event_handler(_cleanup, ^{
            KRHost *host = weak;
            if (!host)
                return;
            for (NSString *k in host->_sessions.allKeys) {
                if (KRClockNS() - host->_sessions[k].lastActive > 15000000000ULL &&
                    ![host recordingSource:k])
                    [host->_sessions removeObjectForKey:k];
            }
        });
        dispatch_resume(_cleanup);
    }
    return self;
}
- (BOOL)listener:(NSXPCListener *)l shouldAcceptNewConnection:(NSXPCConnection *)c {
    if (c.effectiveUserIdentifier != geteuid())
        return NO;
    c.exportedInterface = KRServiceInterface();
    c.exportedObject = self;
    [c resume];
    return YES;
}
- (void)hello:(NSDictionary *)identity reply:(void (^)(NSDictionary *))reply {
    reply(@{
        @"protocol" : @1,
        @"engineVersion" : @"0.1.0",
        @"transport" : @"XPC / IOSurface",
        @"renderer" : @"Metal"
    });
}
- (void)configure:(NSDictionary *)value
           origin:(NSString *)origin
            reply:(void (^)(NSDictionary *))reply {
    NSError *error = nil;
    NSDictionary *p = KRValidatePreset(value, &error);
    if (!p) {
        reply(@{@"error" : error.localizedDescription});
        return;
    }
    dispatch_async(_queue, ^{
        BOOL transitioning =
            [origin isEqual:@"preset"] && [p[@"transitionSeconds"] doubleValue] > 0;
        self->_transitionFrom = transitioning ? self->_preset : nil;
        self->_transitionStart = -1;
        for (KRSession *s in self->_sessions.allValues) {
            s.transitionFrom = transitioning ? (s.effectivePreset ?: self->_preset) : nil;
            s.transitionStart = -1;
        }
        self->_preset = p;
        self->_revision++;
        if ([p[@"clearTrailsOnPreset"] boolValue] && [origin isEqual:@"preset"])
            for (KRSession *s in self->_sessions.allValues)
                [s.engine reset];
        if (self->_eventFile && self->_recordOrigin != UINT64_MAX) {
            NSDictionary *event = @{
                @"timestampNS" : @(self->_recordLatestPTS >= self->_recordOrigin
                                       ? self->_recordLatestPTS - self->_recordOrigin + 33333333
                                       : 0),
                @"eventSequence" : @(++self->_sequence),
                @"sourceType" : [origin hasPrefix:@"midi:"] ? @"midi" : origin,
                @"midiMessage" : [origin hasPrefix:@"midi:"] ? [origin substringFromIndex:5] : @"",
                @"parameterPath" : @"preset",
                @"preset" : p,
                @"clearTrails" :
                    @([p[@"clearTrailsOnPreset"] boolValue] && [origin isEqual:@"preset"])
            };
            NSData *d = [NSJSONSerialization dataWithJSONObject:event
                                                        options:NSJSONWritingSortedKeys
                                                          error:nil];
            [self->_eventFile writeData:d];
            [self->_eventFile writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
        }
        reply(@{@"revision" : @(self->_revision)});
    });
}
- (NSDictionary *)interpolated:(double)pts session:(KRSession *)session {
    double duration = [_preset[@"transitionSeconds"] doubleValue];
    if (!session.transitionFrom || duration <= 0) {
        session.effectivePreset = _preset;
        return _preset;
    }
    if (session.transitionStart < 0)
        session.transitionStart = pts;
    session.effectivePreset = KRInterpolatePreset(session.transitionFrom, _preset,
                                                  (pts - session.transitionStart) / duration);
    return session.effectivePreset;
}
- (void)process:(IOSurface *)surface
       metadata:(NSDictionary *)metadata
          reply:(void (^)(IOSurface *, NSDictionary *))reply {
    NSString *source = metadata[@"sourceID"];
    if (![metadata[@"ptsNS"] isKindOfClass:NSNumber.class] ||
        ![metadata[@"frameID"] isKindOfClass:NSNumber.class] ||
        ![metadata[@"ingestNS"] isKindOfClass:NSNumber.class] ||
        ![metadata[@"mode"] isKindOfClass:NSNumber.class] || [metadata[@"mode"] intValue] < 0 ||
        [metadata[@"mode"] intValue] > 2 || [metadata[@"protocol"] intValue] != 1 ||
        ![source isKindOfClass:NSString.class] || source.length > 256 || !surface.width ||
        surface.width > 7680 || surface.height > 4320 ||
        surface.pixelFormat != kCVPixelFormatType_32BGRA) {
        reply(nil, @{@"error" : @"不正なフレーム記述子"});
        return;
    }
    uint64_t ticket;
    {
        std::lock_guard<std::mutex> guard(_requestLock);
        ticket = ++_nextTicket;
        _latestTickets[source] = @(ticket);
    }
    if (_pending.fetch_add(1) >= 24) {
        _pending--;
        reply(nil, @{@"dropped" : @YES});
        return;
    }
    dispatch_async(_queue, ^{
        @autoreleasepool {
            {
                std::lock_guard<std::mutex> guard(self->_requestLock);
                if ([self->_latestTickets[source] unsignedLongLongValue] != ticket) {
                    self->_pending--;
                    reply(nil, @{@"dropped" : @YES});
                    return;
                }
            }
            NSError *error = nil;
            KRSession *s = self->_sessions[source];
            uint64_t now = KRClockNS();
            if (!s) {
                if (self->_sessions.count >= 8) {
                    for (NSString *k in self->_sessions.allKeys)
                        if (now - self->_sessions[k].lastActive > 10000000000ULL)
                            [self->_sessions removeObjectForKey:k];
                }
                if (self->_sessions.count >= 8) {
                    self->_pending--;
                    reply(nil, @{@"error" : @"入力数の上限です"});
                    return;
                }
                s = [KRSession new];
                s.engine = [[KREngine alloc] initWithShader:self->_shader error:&error];
                if (!s.engine) {
                    self->_pending--;
                    reply(nil, @{@"error" : error.localizedDescription ?: @"エンジン起動失敗"});
                    return;
                }
                s.transitionFrom = self->_transitionFrom;
                self->_sessions[source] = s;
            }
            s.lastActive = now;
            if (s.surface && s.revision == self->_revision &&
                [s.metadata[@"ptsNS"] isEqual:metadata[@"ptsNS"]]) {
                self->_pending--;
                NSMutableDictionary *cached = [s.metadata mutableCopy];
                cached[@"mode"] = metadata[@"mode"];
                reply([s.engine latestSurfaceForMode:[metadata[@"mode"] integerValue]] ?: s.surface,
                      cached);
                return;
            }
            IOSurface *out = [s.engine
                  render:surface
                metadata:metadata
                  preset:[self interpolated:[metadata[@"ptsNS"] doubleValue] * 1e-9 session:s]
                   error:&error];
            if (!out && !error)
                error = [NSError
                    errorWithDomain:@"KiraRaki"
                               code:3
                           userInfo:@{
                               NSLocalizedDescriptionKey : @"Metalフレームを生成できませんでした"
                           }];
            NSMutableDictionary *m = [metadata mutableCopy];
            [m addEntriesFromDictionary:s.engine.statistics];
            m[@"renderedNS"] = @(KRClockNS());
            m[@"latencyMS"] =
                @((KRClockNS() - [metadata[@"ingestNS"] unsignedLongLongValue]) * 1e-6);
            if (error)
                m[@"error"] = error.localizedDescription;
            if (out) {
                s.surface = out;
                s.metadata = m;
                s.revision = self->_revision;
                self->_latestSource = source;
                self->_lastPTS = [metadata[@"ptsNS"] unsignedLongLongValue];
                [self recordFrame:[s.engine latestSurfaceForMode:[self->_preset[@"outputMode"]
                                                                     integerValue]]
                                      ?: out
                            clean:surface
                         metadata:metadata];
            }
            self->_pending--;
            reply(out, m);
        }
    });
}
- (void)audio:(NSData *)pcm metadata:(NSDictionary *)m {
    if (pcm.length > 48000 * 4 * 4 || pcm.length % 4 || [m[@"sampleRate"] intValue] != 48000 ||
        ![m[@"sourceID"] isKindOfClass:NSString.class])
        return;
    int channels = [m[@"channels"] intValue];
    if ((channels != 1 && channels != 2) || pcm.length % (channels * 4))
        return;
    NSData *analysis = pcm;
    if (channels == 2) {
        NSMutableData *mono = [NSMutableData dataWithLength:pcm.length / 2];
        const float *source = (const float *)pcm.bytes;
        float *target = (float *)mono.mutableBytes;
        for (size_t i = 0; i < pcm.length / 8; i++)
            target[i] = (source[i * 2] + source[i * 2 + 1]) * .5f;
        analysis = mono;
    }
    dispatch_async(_queue, ^{
        NSString *source = m[@"sourceID"];
        BOOL obs = [source hasPrefix:@"obs:"];
        int mode = [self->_preset[@"audioInput"] intValue];
        uint64_t now = KRClockNS();
        if (mode == 2 || (mode == 0 && obs) || (mode == 1 && !obs))
            return;
        if (mode == 1) {
            if (self->_obsPreferredAudio && ![self->_obsPreferredAudio isEqual:source])
                return;
            if (self->_obsAudioOwner && ![self->_obsAudioOwner isEqual:source] &&
                now - self->_obsAudioLastClock < 300000000)
                return;
            self->_obsAudioOwner = source;
            self->_obsAudioLastClock = now;
            for (KRSession *session in self->_sessions.allValues)
                [session.engine audio:analysis];
        } else
            [self->_sessions[source].engine audio:analysis];
        if (!self->_movie || self->_recordOrigin == UINT64_MAX ||
            (![self recordingSource:source] && mode != 1))
            return;
        if (now - self->_recordLastClock > 500000000) {
            self->_recordAudioOrigin = UINT64_MAX;
            return;
        }
        uint64_t pts = [m[@"ptsNS"] unsignedLongLongValue], relative = 0;
        if ([self recordingSource:source]) {
            if (pts < self->_recordOrigin)
                return;
            relative = pts - self->_recordOrigin;
        } else {
            if (self->_recordAudioOrigin == UINT64_MAX) {
                uint64_t elapsed = self->_recordLatestPTS - self->_recordOrigin;
                self->_recordAudioOrigin = pts > elapsed ? pts - elapsed : 0;
            }
            if (pts < self->_recordAudioOrigin)
                return;
            relative = pts - self->_recordAudioOrigin;
        }
        CMTime time = CMTimeMake(relative, 1000000000);
        if (channels == 2) {
            [self->_movie appendStereoAudio:pcm pts:time];
            [self->_clean appendStereoAudio:pcm pts:time];
        } else {
            [self->_movie appendMonoAudio:pcm pts:time];
            [self->_clean appendMonoAudio:pcm pts:time];
        }
    });
}
- (void)preview:(NSString *)source
           mode:(NSInteger)mode
          reply:(void (^)(IOSurface *, NSDictionary *))reply {
    dispatch_async(_queue, ^{
        if ([source isEqual:@"app-main"])
            self->_obsPreviewLastNS = KRClockNS();
        NSString *key = source.length ? source : self->_latestSource;
        KRSession *s = key ? self->_sessions[key] : nil;
        BOOL fresh = s && KRClockNS() - s.lastActive < 500000000;
        if (!fresh) {
            reply(nil, @{});
            return;
        }
        NSMutableDictionary *m = [s.metadata mutableCopy];
        if (mode >= 0 && mode <= 2)
            m[@"mode"] = @(mode);
        reply(mode >= 0 && mode <= 2 ? [s.engine latestSurfaceForMode:mode] : s.surface, m);
    });
}
- (void)status:(void (^)(NSDictionary *))reply {
    dispatch_async(_queue, ^{
        NSMutableArray *sources = [NSMutableArray array], *instances = [NSMutableArray array];
        BOOL obs = NO;
        for (NSDictionary *i in self->_obsInstances.allValues)
            if (KRClockNS() - [i[@"seenNS"] unsignedLongLongValue] < 5000000000) {
                [instances addObject:i];
                obs = YES;
            }
        for (NSString *k in self->_sessions) {
            KRSession *s = self->_sessions[k];
            if (KRClockNS() - s.lastActive > 5000000000)
                continue;
            [sources addObject:@{@"sourceID" : k, @"statistics" : s.engine.statistics}];
            if ([k hasPrefix:@"obs:"])
                obs = YES;
        }
        reply(@{
            @"connected" : @YES,
            @"protocol" : @1,
            @"obsConnected" : @(obs || KRClockNS() - self->_obsPreviewLastNS < 1500000000),
            @"appFeedDemand" : @(KRClockNS() - self->_obsPreviewLastNS < 1500000000),
            @"obsAudioSource" : self->_obsAudioOwner ?: @"",
            @"sources" : sources,
            @"obsSources" : self->_obsSources ?: @[],
            @"obsInstances" : instances,
            @"preset" : self->_preset,
            @"recording" : @(self->_recordOptions != nil),
            @"recordedFrames" : @(self->_movie.frames),
            @"recordingBytes" : @([self recordingBytes]),
            @"recordingMBps" : @(self->_recordLatestPTS > self->_recordOrigin
                                     ? [self recordingBytes] * 1000.0 /
                                           (self->_recordLatestPTS - self->_recordOrigin)
                                     : 0),
            @"droppedRecordingFrames" : @(self->_dropped),
            @"recordError" : self->_recordError ?: @"",
            @"latestSource" : self->_latestSource ?: @""
        });
    });
}
- (void)publishOBS:(NSDictionary *)inventory reply:(void (^)(NSDictionary *))reply {
    NSDictionary *instance = inventory[@"instance"];
    NSString *key = instance[@"instanceID"];
    if (![key isKindOfClass:NSString.class] || key.length > 256) {
        reply(@{});
        return;
    }
    dispatch_async(_queue, ^{
        if (!self->_obsInstances)
            self->_obsInstances = [NSMutableDictionary dictionary];
        if (!self->_obsCommands)
            self->_obsCommands = [NSMutableDictionary dictionary];
        NSMutableDictionary *state = [instance mutableCopy];
        state[@"seenNS"] = @(KRClockNS());
        self->_obsInstances[key] = state;
        if (!self->_obsPreferredAudio && [state[@"audioMix"] intValue] > 0)
            self->_obsPreferredAudio = state[@"audioSourceID"];
        NSArray *sources = inventory[@"sources"];
        if ([sources isKindOfClass:NSArray.class] && sources.count < 2048)
            self->_obsSources = sources;
        NSDictionary *command = self->_obsCommands[key] ?: @{};
        [self->_obsCommands removeObjectForKey:key];
        reply(command);
    });
}
- (void)routeOBS:(NSDictionary *)settings
        instance:(NSString *)instanceID
           reply:(void (^)(NSDictionary *))reply {
    dispatch_async(_queue, ^{
        if (!self->_obsInstances[instanceID]) {
            reply(@{@"error" : @"OBSインスタンスが見つかりません"});
            return;
        }
        NSMutableDictionary *command =
            [self->_obsCommands[instanceID] mutableCopy] ?: [NSMutableDictionary dictionary];
        if ([settings[@"targetUUID"] isKindOfClass:NSString.class])
            command[@"targetUUID"] = settings[@"targetUUID"];
        if ([settings[@"outputMode"] isKindOfClass:NSNumber.class])
            command[@"outputMode"] = @(std::clamp([settings[@"outputMode"] intValue], 0, 2));
        if ([settings[@"audioMix"] isKindOfClass:NSNumber.class]) {
            command[@"audioMix"] = @(std::clamp([settings[@"audioMix"] intValue], 0, 6));
            NSString *provider = self->_obsInstances[instanceID][@"audioSourceID"];
            if ([settings[@"audioMix"] intValue] > 0) {
                self->_obsPreferredAudio = provider;
                self->_obsAudioOwner = nil;
            } else if ([self->_obsPreferredAudio isEqual:provider])
                self->_obsPreferredAudio = nil;
        }
        self->_obsCommands[instanceID] = command;
        reply(@{@"accepted" : @YES});
    });
}
- (BOOL)recordingSource:(NSString *)source {
    NSString *chosen = _recordOptions[@"sourceID"];
    return _recordOptions && (!chosen.length || [chosen isEqual:source]);
}
- (uint64_t)recordingBytes {
    if (!_recordOptions)
        return 0;
    uint64_t bytes = [[[NSFileManager defaultManager] attributesOfItemAtPath:_recordOptions[@"path"]
                                                                       error:nil] fileSize];
    NSString *clean = [[_manifestURL URLByDeletingLastPathComponent].path
        stringByAppendingPathComponent:@"clean.mov"];
    if (clean)
        bytes += [[[NSFileManager defaultManager] attributesOfItemAtPath:clean error:nil] fileSize];
    return bytes;
}
- (void)record:(NSDictionary *)options reply:(void (^)(NSDictionary *))reply {
    dispatch_async(_queue, ^{
        NSString *path = options[@"path"];
        if (self->_recordOptions || ![path isKindOfClass:NSString.class] || !path.isAbsolutePath ||
            [[NSFileManager defaultManager] fileExistsAtPath:path]) {
            reply(@{@"error" : @"録画中、または保存先が不正です"});
            return;
        }
        self->_recordOptions = [options mutableCopy];
        self->_recordOrigin = UINT64_MAX;
        self->_recordAudioOrigin = UINT64_MAX;
        self->_recordLatestPTS = 0;
        self->_sequence = 0;
        self->_dropped = 0;
        self->_recordError = nil;
        reply(@{@"recording" : @YES});
    });
}
- (void)recordFrame:(IOSurface *)out clean:(IOSurface *)input metadata:(NSDictionary *)m {
    NSString *source = m[@"sourceID"];
    if (![self recordingSource:source])
        return;
    if (!_movie) {
        _recordOptions[@"sourceID"] = source;
        NSString *path = _recordOptions[@"path"];
        NSError *err = nil;
        _movie = [[KRMovieWriter alloc] initWithURL:[NSURL fileURLWithPath:path]
                                              width:out.width
                                             height:out.height
                                              codec:_recordOptions[@"codec"] ?: @"h264"
                                              audio:[_recordOptions[@"audio"] boolValue]
                                           realtime:YES
                                              error:&err];
        if (!_movie) {
            _recordError = err.localizedDescription ?: @"録画開始失敗";
            _recordOptions = nil;
            return;
        }
        _recordOrigin = [m[@"ptsNS"] unsignedLongLongValue];
        NSString *directory =
            [[path stringByDeletingPathExtension] stringByAppendingPathExtension:@"kirareplay"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:directory])
            directory = [[[path stringByDeletingPathExtension]
                stringByAppendingFormat:@"-%@", NSUUID.UUID.UUIDString]
                stringByAppendingPathExtension:@"kirareplay"];
        [[NSFileManager defaultManager] createDirectoryAtPath:directory
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:&err];
        NSString *events = [directory stringByAppendingPathComponent:@"events.jsonl"];
        [[NSFileManager defaultManager] createFileAtPath:events contents:nil attributes:nil];
        _eventFile = [NSFileHandle fileHandleForWritingAtPath:events];
        NSString *inputPath = _recordOptions[@"inputPath"] ?: @"";
        BOOL cleanFeed = [_recordOptions[@"replayEnabled"] boolValue] &&
                         (!inputPath.length || [_recordOptions[@"audioSource"] isEqual:@"obs"]);
        if (cleanFeed) {
            _clean = [[KRMovieWriter alloc]
                initWithURL:[NSURL fileURLWithPath:[directory
                                                       stringByAppendingPathComponent:@"clean.mov"]]
                      width:input.width
                     height:input.height
                      codec:@"prores422"
                      audio:[_recordOptions[@"audio"] boolValue]
                   realtime:YES
                      error:&err];
            if (!_clean)
                _recordError = err.localizedDescription;
        }
        NSMutableDictionary *manifest = [@{
            @"schemaVersion" : @1,
            @"algorithmVersion" : @"0.1.0",
            @"preset" : _sessions[source].effectivePreset ?: _preset,
            @"sourceID" : source,
            @"inputPath" : cleanFeed ? @"clean.mov" : inputPath,
            @"inputSHA256" : @"",
            @"originalFileReference" : inputPath,
            @"events" : @"events.jsonl",
            @"sourceStartPTSNS" : @(_recordOrigin),
            @"frameRate" : @30,
            @"colorPrimaries" : @"Rec.709",
            @"transferFunction" : @"Rec.709",
            @"colorRange" : @"full",
            @"alphaMode" : @"premultiplied",
            @"outputCodec" : _recordOptions[@"codec"] ?: @"h264",
            @"shaderSHA256" : KRFileSHA256([NSURL fileURLWithPath:_shader]),
            @"os" : NSProcessInfo.processInfo.operatingSystemVersionString,
            @"renderer" : @"Metal",
            @"visionModel" :
                @"Apple Vision foreground-instance-mask revision 1 / person segmentation",
            @"replayAvailable" : @(inputPath.length || _clean != nil)
        } mutableCopy];
        if (_recordOptions[@"inputStartNS"])
            manifest[@"inputStartNS"] = _recordOptions[@"inputStartNS"];
        _manifest = manifest;
        _manifestURL =
            [NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"manifest.json"]];
        NSData *d = [NSJSONSerialization
            dataWithJSONObject:manifest
                       options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                         error:nil];
        [d writeToFile:[directory stringByAppendingPathComponent:@"manifest.json"] atomically:YES];
    }
    uint64_t pts = [m[@"ptsNS"] unsignedLongLongValue];
    if (pts < _recordOrigin) {
        _recordError = @"入力がシークされました。録画を停止して再開してください";
        return;
    }
    _recordLatestPTS = pts;
    _recordLastClock = KRClockNS();
    CMTime t = CMTimeMake(pts - _recordOrigin, 1000000000);
    if (![_movie appendSurface:out pts:t])
        _dropped++;
    if (_clean && ![_clean appendSurface:input pts:t])
        _recordError = @"クリーン映像のフレームが欠落しました";
}
- (void)stopRecording:(void (^)(NSDictionary *))reply {
    dispatch_async(_queue, ^{
        NSError *err = nil;
        BOOL ok = YES;
        if (self->_movie)
            ok = [self->_movie finish:&err];
        if (self->_clean)
            ok = [self->_clean finish:&err] && ok;
        [self->_eventFile synchronizeFile];
        [self->_eventFile closeFile];
        NSInteger frames = self->_movie.frames;
        if (self->_manifest) {
            self->_manifest[@"durationNS"] =
                @(self->_recordLatestPTS >= self->_recordOrigin
                      ? self->_recordLatestPTS - self->_recordOrigin + 33333333
                      : 0);
            self->_manifest[@"recordedFrames"] = @(frames);
            self->_manifest[@"droppedFrames"] = @(self->_dropped);
            self->_manifest[@"complete"] = @(ok && frames > 0 && !self->_recordError.length);
            NSString *path = self->_manifest[@"inputPath"];
            NSURL *input = [path isAbsolutePath]
                               ? [NSURL fileURLWithPath:path]
                               : [[self->_manifestURL URLByDeletingLastPathComponent]
                                     URLByAppendingPathComponent:path];
            if (path.length)
                self->_manifest[@"inputSHA256"] = KRFileSHA256(input);
            [[NSJSONSerialization
                dataWithJSONObject:self->_manifest
                           options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                             error:nil] writeToURL:self->_manifestURL atomically:YES];
        }
        self->_movie = nil;
        self->_clean = nil;
        self->_eventFile = nil;
        self->_recordOptions = nil;
        self->_manifest = nil;
        self->_manifestURL = nil;
        reply(@{@"recording":@NO,@"frames":@(frames),@"success":@(ok&&frames>0),@"error":err.localizedDescription?:self->_recordError?:(frames>0?@"":@"保存できるフレームがありませんでした")});
    });
}
- (void)reset:(NSString *)source {
    dispatch_async(_queue, ^{
        [self->_sessions[source].engine reset];
    });
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *path = argc > 1
                             ? @(argv[1])
                             : [NSBundle.mainBundle pathForResource:@"Effects" ofType:@"metal"];
        if (!path)
            path = [[@(argv[0]) stringByDeletingLastPathComponent]
                stringByAppendingPathComponent:@"../Resources/Effects.metal"];
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            fprintf(stderr, "Shader not found: %s\n", path.UTF8String);
            return 1;
        }
        KRHost *host = [[KRHost alloc] initWithShader:path];
        NSXPCListener *listener = [[NSXPCListener alloc] initWithMachServiceName:KRServiceName];
        listener.delegate = host;
        [listener resume];
        fprintf(stderr, "KiraRaki render service ready\n");
        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
