#import "KRIPC.h"
#import <mach/mach_time.h>
#include <algorithm>
#include <cmath>
#include <mutex>
#include <atomic>
#include <memory>

NSString *const KRServiceName = @"jp.meowkawaii.KiraRaki.render";
NSString *const KRAlgorithmVersion = @"0.2.0";
uint64_t KRClockNS(void) {
    static mach_timebase_info_data_t t = [] {
        mach_timebase_info_data_t a;
        mach_timebase_info(&a);
        return a;
    }();
    return uint64_t((__uint128_t)mach_continuous_time() * t.numer / t.denom);
}
NSDictionary *KRDefaultPreset(void) {
    return @{
        @"schemaVersion" : @1,
        @"enabled" : @YES,
        @"analysisMode" : @0,
        @"audioInput" : @0,
        @"lineWidth" : @3,
        @"distortion" : @.45,
        @"density" : @.35,
        @"threshold" : @.14,
        @"lifetime" : @.65,
        @"tracking" : @.8,
        @"updateHz" : @4,
        @"irregularity" : @.9,
        @"strokeLength" : @420,
        @"jaggedSpacing" : @48,
        @"motionResponse" : @1,
        @"shapes" : @[ @1, @0, @0, @0 ],
        @"regions" : @[ @.3, @.3, @.12, @.2, @.08 ],
        @"placement" : @[ @.2, @.5, @.3 ],
        @"colorMode" : @0,
        @"hueSpeed" : @.08,
        @"hueOffset" : @0,
        @"palette" : @[ @"0ACDFF", @"FF1475", @"A626FF", @"FFB30D" ],
        @"glow" : @.65,
        @"glowRadius" : @4,
        @"trailHalfLife" : @.12,
        @"outputMode" : @0,
        @"lossMode" : @0,
        @"seed" : @873512,
        @"audioMappings" : @[],
        @"transitionSeconds" : @0,
        @"clearTrailsOnPreset" : @YES,
        @"autoAdapt" : @YES
    };
}
NSDictionary *KRValidatePreset(NSDictionary *value, NSError **error) {
    auto fail = [&](NSString *m) -> NSDictionary * {
        if (error)
            *error = [NSError errorWithDomain:@"KiraRaki"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey : m}];
        return nil;
    };
    if (![value isKindOfClass:NSDictionary.class] || [value[@"schemaVersion"] integerValue] != 1)
        return fail(@"対応していないプリセット形式です");
    NSMutableDictionary *p = [KRDefaultPreset() mutableCopy];
    NSDictionary *bounds = @{
        @"lineWidth" : @[ @.25, @40 ],
        @"distortion" : @[ @0, @1 ],
        @"density" : @[ @0, @1 ],
        @"threshold" : @[ @.01, @1 ],
        @"lifetime" : @[ @.05, @10 ],
        @"tracking" : @[ @0, @1 ],
        @"updateHz" : @[ @.1, @60 ],
        @"irregularity" : @[ @0, @1 ],
        @"strokeLength" : @[ @60, @900 ],
        @"jaggedSpacing" : @[ @8, @180 ],
        @"motionResponse" : @[ @0, @1 ],
        @"hueSpeed" : @[ @-2, @2 ],
        @"hueOffset" : @[ @0, @1 ],
        @"glow" : @[ @0, @3 ],
        @"glowRadius" : @[ @1, @18 ],
        @"trailHalfLife" : @[ @0, @3 ],
        @"transitionSeconds" : @[ @0, @10 ],
        @"analysisMode" : @[ @0, @2 ],
        @"audioInput" : @[ @0, @2 ],
        @"outputMode" : @[ @0, @2 ],
        @"colorMode" : @[ @0, @2 ],
        @"lossMode" : @[ @0, @2 ],
        @"seed" : @[ @0, @9007199254740991 ]
    };
    for (NSString *k in bounds) {
        id n = value[k];
        if (!n)
            continue;
        if (![n isKindOfClass:NSNumber.class] || !std::isfinite([n doubleValue]))
            return fail([@"数値が不正です: " stringByAppendingString:k]);
        NSArray *b = bounds[k];
        p[k] = @(std::clamp([n doubleValue], [b[0] doubleValue], [b[1] doubleValue]));
    }
    for (NSString *k in @[ @"enabled", @"autoAdapt", @"clearTrailsOnPreset" ]) {
        if (value[k]) {
            if (![value[k] isKindOfClass:NSNumber.class])
                return fail(@"真偽値が不正です");
            p[k] = @([value[k] boolValue]);
        }
    }
    NSDictionary *sizes = @{@"shapes" : @4, @"regions" : @5, @"placement" : @3};
    for (NSString *k in sizes) {
        if (!value[k])
            continue;
        NSArray *a = value[k];
        if (![a isKindOfClass:NSArray.class] || a.count != [sizes[k] unsignedIntegerValue])
            return fail(@"混合比率の要素数が不正です");
        NSMutableArray *b = [NSMutableArray array];
        for (id x in a) {
            if (![x isKindOfClass:NSNumber.class] || !std::isfinite([x doubleValue]))
                return fail(@"混合比率が不正です");
            [b addObject:@(std::clamp([x doubleValue], 0., 1.))];
        }
        p[k] = b;
    }
    if (value[@"palette"]) {
        NSArray *a = value[@"palette"];
        if (![a isKindOfClass:NSArray.class] || a.count < 1 || a.count > 32)
            return fail(@"パレットは1〜32色にしてください");
        NSCharacterSet *invalid = [[NSCharacterSet
            characterSetWithCharactersInString:@"0123456789abcdefABCDEF"] invertedSet];
        for (id s in a)
            if (![s isKindOfClass:NSString.class] || [s length] != 6 ||
                [s rangeOfCharacterFromSet:invalid].location != NSNotFound)
                return fail(@"パレットは6桁のRGB値を指定してください");
        p[@"palette"] = a;
    }
    if (value[@"audioMappings"]) {
        NSArray *a = value[@"audioMappings"];
        if (![a isKindOfClass:NSArray.class] || a.count > 32)
            return fail(@"音声マッピングが不正です");
        NSMutableArray *maps = [NSMutableArray array];
        for (id item in a) {
            if (![item isKindOfClass:NSDictionary.class])
                return fail(@"音声マッピングが不正です");
            NSString *feature = item[@"feature"], *target = item[@"target"];
            if (![@[ @"rms", @"low", @"mid", @"high", @"onset" ] containsObject:feature] ||
                !bounds[target])
                return fail(@"音声マッピングの対象が不正です");
            NSMutableDictionary *m = [@{
                @"feature" : feature,
                @"target" : target,
                @"gain" : @1,
                @"min" : @0,
                @"max" : @1,
                @"attack" : @.02,
                @"release" : @.2,
                @"invert" : @NO
            } mutableCopy];
            for (NSString *k in @[ @"gain", @"min", @"max", @"attack", @"release", @"invert" ]) {
                id n = item[k];
                if (n) {
                    if (![n isKindOfClass:NSNumber.class] || !std::isfinite([n doubleValue]))
                        return fail(@"音声マッピングの数値が不正です");
                    m[k] = n;
                }
            }
            [maps addObject:m];
        }
        p[@"audioMappings"] = maps;
    }
    return p;
}
NSDictionary *KRInterpolatePreset(NSDictionary *from, NSDictionary *to, double progress) {
    double a = std::clamp(progress, 0., 1.);
    if (a >= 1 || !from)
        return to;
    NSMutableDictionary *p = [to mutableCopy];
    for (NSString *k in @[
             @"lineWidth", @"distortion", @"density", @"threshold", @"lifetime", @"tracking",
             @"updateHz", @"irregularity", @"hueSpeed", @"hueOffset", @"glow", @"glowRadius",
             @"trailHalfLife", @"strokeLength", @"jaggedSpacing", @"motionResponse"
         ]) {
        double x = [from[k] doubleValue], y = [to[k] doubleValue];
        p[k] = @(x + (y - x) * a);
    }
    for (NSString *k in @[ @"shapes", @"regions", @"placement" ]) {
        NSMutableArray *v = [NSMutableArray array];
        for (NSUInteger i = 0; i < [to[k] count]; i++) {
            double x = [from[k][i] doubleValue], y = [to[k][i] doubleValue];
            [v addObject:@(x + (y - x) * a)];
        }
        p[k] = v;
    }
    NSArray *fp = from[@"palette"], *tp = to[@"palette"];
    NSMutableArray *palette = [NSMutableArray array];
    if (fp.count && tp.count)
        for (NSUInteger i = 0; i < std::max(fp.count, tp.count); i++) {
            unsigned x = 0, y = 0;
            [[NSScanner scannerWithString:fp[i % fp.count]] scanHexInt:&x];
            [[NSScanner scannerWithString:tp[i % tp.count]] scanHexInt:&y];
            unsigned result = 0;
            for (int shift : {16, 8, 0}) {
                double c0 = (x >> shift) & 255, c1 = (y >> shift) & 255;
                result |= unsigned(std::round(c0 + (c1 - c0) * a)) << shift;
            }
            [palette addObject:[NSString stringWithFormat:@"%06X", result]];
        }
    if (palette.count)
        p[@"palette"] = palette;
    if (a < .5)
        for (NSString *k in @[ @"colorMode", @"analysisMode", @"lossMode", @"enabled" ])
            p[k] = from[k];
    return p;
}
IOSurface *KRMakeSurface(NSUInteger w, NSUInteger h) {
    if (!w || !h || w > 7680 || h > 4320)
        return nil;
    return [[IOSurface alloc] initWithProperties:@{
        (__bridge id)kIOSurfaceWidth : @(w),
        (__bridge id)kIOSurfaceHeight : @(h),
        (__bridge id)kIOSurfaceBytesPerElement : @4,
        (__bridge id)kIOSurfaceBytesPerRow : @((w * 4 + 63) & ~63UL),
        (__bridge id)kIOSurfacePixelFormat : @(kCVPixelFormatType_32BGRA)
    }];
}
NSXPCInterface *KRServiceInterface(void) {
    NSXPCInterface *i = [NSXPCInterface interfaceWithProtocol:@protocol(KRRenderService)];
    NSSet *c = [NSSet setWithObjects:NSDictionary.class, NSMutableDictionary.class, NSArray.class,
                                     NSMutableArray.class, NSString.class, NSNumber.class,
                                     NSData.class, NSNull.class, IOSurface.class, nil];
    [i setClasses:c forSelector:@selector(hello:reply:) argumentIndex:0 ofReply:NO];
    [i setClasses:c forSelector:@selector(hello:reply:) argumentIndex:0 ofReply:YES];
    [i setClasses:c forSelector:@selector(configure:origin:reply:) argumentIndex:0 ofReply:NO];
    [i setClasses:c forSelector:@selector(configure:origin:reply:) argumentIndex:0 ofReply:YES];
    [i setClasses:c forSelector:@selector(process:metadata:reply:) argumentIndex:1 ofReply:NO];
    [i setClasses:c forSelector:@selector(process:metadata:reply:) argumentIndex:1 ofReply:YES];
    [i setClasses:c forSelector:@selector(audio:metadata:) argumentIndex:1 ofReply:NO];
    [i setClasses:c forSelector:@selector(preview:mode:reply:) argumentIndex:1 ofReply:YES];
    [i setClasses:c forSelector:@selector(status:) argumentIndex:0 ofReply:YES];
    [i setClasses:c forSelector:@selector(record:reply:) argumentIndex:0 ofReply:NO];
    [i setClasses:c forSelector:@selector(record:reply:) argumentIndex:0 ofReply:YES];
    [i setClasses:c forSelector:@selector(stopRecording:) argumentIndex:0 ofReply:YES];
    [i setClasses:c forSelector:@selector(publishOBS:reply:) argumentIndex:0 ofReply:NO];
    [i setClasses:c forSelector:@selector(publishOBS:reply:) argumentIndex:0 ofReply:YES];
    [i setClasses:c forSelector:@selector(routeOBS:instance:reply:) argumentIndex:0 ofReply:NO];
    [i setClasses:c forSelector:@selector(routeOBS:instance:reply:) argumentIndex:0 ofReply:YES];
    return i;
}

@implementation KRClient {
    NSXPCConnection *_connection;
    std::mutex _lock;
    IOSurface *_latest;
    NSDictionary *_metadata;
    BOOL _connected;
    IOSurface *_slots[3];
    bool _busy[3];
    uint64_t _frameID;
    uint64_t _generation;
    uint64_t _slotFrame[3];
    uint64_t _lastConnect;
    BOOL _previewPending;
}
- (instancetype)init {
    if ((self = [super init])) {
        _metadata = @{};
    }
    return self;
}
- (BOOL)connected {
    std::lock_guard<std::mutex> g(_lock);
    return _connected;
}
- (NSDictionary *)latestMetadata {
    std::lock_guard<std::mutex> g(_lock);
    return _metadata;
}
- (IOSurface *)latestSurface {
    std::lock_guard<std::mutex> g(_lock);
    return _latest;
}
- (void)connect {
    @synchronized(self) {
        if (_connection || KRClockNS() - _lastConnect < 1000000000)
            return;
        _lastConnect = KRClockNS();
        NSXPCConnection *c = [[NSXPCConnection alloc] initWithMachServiceName:KRServiceName
                                                                      options:0];
        c.remoteObjectInterface = KRServiceInterface();
        __weak KRClient *weak = self;
        c.interruptionHandler = ^{
            [weak disconnect];
        };
        c.invalidationHandler = ^{
            [weak disconnect];
        };
        _connection = c;
        [c resume];
        id<KRRenderService> p = [c remoteObjectProxyWithErrorHandler:^(NSError *e) {
            [weak disconnect];
        }];
        [p hello:@{@"protocol" : @1, @"client" : NSBundle.mainBundle.bundleIdentifier ?: @"cli"}
            reply:^(NSDictionary *r) {
                KRClient *s = weak;
                if (s) {
                    std::lock_guard<std::mutex> g(s->_lock);
                    s->_connected = [r[@"protocol"] intValue] == 1;
                }
            }];
    }
}
- (void)disconnect {
    NSXPCConnection *c;
    @synchronized(self) {
        c = _connection;
        _connection = nil;
    }
    if (!c)
        return;
    c.invalidationHandler = nil;
    c.interruptionHandler = nil;
    [c invalidate];
    std::lock_guard<std::mutex> g(_lock);
    _generation++;
    _connected = NO;
    _previewPending = NO;
    _latest = nil;
    _metadata = @{};
    for (int i = 0; i < 3; ++i)
        _busy[i] = false;
}
- (id<KRRenderService>)proxy {
    [self connect];
    __weak KRClient *w = self;
    return [_connection remoteObjectProxyWithErrorHandler:^(NSError *e) {
        [w disconnect];
    }];
}
- (void)configure:(NSDictionary *)preset origin:(NSString *)origin {
    __weak KRClient *weak = self;
    [[self proxy] configure:preset
                     origin:origin
                      reply:^(NSDictionary *r) {
                          void (^cb)(NSString *) = weak.onError;
                          if (r[@"error"] && cb)
                              cb(r[@"error"]);
                      }];
}
- (void)received:(IOSurface *)surface metadata:(NSDictionary *)meta {
    if (!surface) {
        void (^cb)(NSString *) = self.onError;
        if (meta[@"error"] && cb)
            cb(meta[@"error"]);
        return;
    }
    {
        std::lock_guard<std::mutex> g(_lock);
        _latest = surface;
        _metadata = meta;
    }
    void (^cb)(IOSurface *, NSDictionary *) = self.onFrame;
    if (cb)
        cb(surface, meta);
}
- (BOOL)submitPixelBuffer:(CVPixelBufferRef)b
                      pts:(uint64_t)pts
                   source:(NSString *)source
                     mode:(NSInteger)mode {
    if (CVPixelBufferGetPixelFormatType(b) != kCVPixelFormatType_32BGRA)
        return NO;
    CVPixelBufferLockBaseAddress(b, kCVPixelBufferLock_ReadOnly);
    BOOL ok = [self submitBGRA:CVPixelBufferGetBaseAddress(b)
                         width:CVPixelBufferGetWidth(b)
                        height:CVPixelBufferGetHeight(b)
                      rowBytes:CVPixelBufferGetBytesPerRow(b)
                           pts:pts
                        source:source
                          mode:mode];
    CVPixelBufferUnlockBaseAddress(b, kCVPixelBufferLock_ReadOnly);
    return ok;
}
- (BOOL)submitBGRA:(const void *)bytes
             width:(NSUInteger)w
            height:(NSUInteger)h
          rowBytes:(NSUInteger)stride
               pts:(uint64_t)pts
            source:(NSString *)source
              mode:(NSInteger)mode {
    if (!bytes || stride < w * 4)
        return NO;
    id<KRRenderService> proxy = [self proxy];
    if (!self.connected || !proxy)
        return NO;
    int slot = -1;
    IOSurface *surface;
    uint64_t fid, generation;
    {
        std::lock_guard<std::mutex> g(_lock);
        for (int i = 0; i < 3; ++i)
            if (!_busy[i]) {
                slot = i;
                break;
            }
        if (slot < 0)
            return NO;
        if (_slots[slot].width != w || _slots[slot].height != h)
            _slots[slot] = KRMakeSurface(w, h);
        surface = _slots[slot];
        if (!surface)
            return NO;
        _busy[slot] = true;
        fid = ++_frameID;
        _slotFrame[slot] = fid;
        generation = _generation;
    }
    [surface lockWithOptions:0 seed:nullptr];
    for (NSUInteger y = 0; y < h; ++y)
        memcpy((uint8_t *)surface.baseAddress + y * surface.bytesPerRow,
               (uint8_t *)bytes + y * stride, w * 4);
    [surface unlockWithOptions:0 seed:nullptr];
    __weak KRClient *weak = self;
    [proxy process:surface
          metadata:@{
              @"protocol" : @1,
              @"sourceID" : source,
              @"frameID" : @(fid),
              @"ptsNS" : @(pts),
              @"ingestNS" : @(KRClockNS()),
              @"mode" : @(mode),
              @"colorPrimaries" : @"Rec.709",
              @"transfer" : @"Rec.709",
              @"range" : @"full",
              @"alpha" : @"premultiplied"
          }
             reply:^(IOSurface *out, NSDictionary *meta) {
                 KRClient *s = weak;
                 if (!s)
                     return;
                 {
                     std::lock_guard<std::mutex> g(s->_lock);
                     if (s->_generation != generation || s->_slotFrame[slot] != fid)
                         return;
                     s->_busy[slot] = false;
                 }
                 [s received:out metadata:meta];
             }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                       KRClient *s = weak;
                       if (!s)
                           return;
                       bool timedOut;
                       {
                           std::lock_guard<std::mutex> g(s->_lock);
                           timedOut = s->_generation == generation && s->_slotFrame[slot] == fid &&
                                      s->_busy[slot];
                       }
                       if (timedOut)
                           [s disconnect];
                   });
    return YES;
}
- (void)sendAudio:(NSData *)pcm pts:(uint64_t)pts source:(NSString *)source {
    if (pcm.length > 48000 * 4 * 4)
        return;
    [[self proxy] audio:pcm
               metadata:@{
                   @"sourceID" : source,
                   @"ptsNS" : @(pts),
                   @"sampleRate" : @48000,
                   @"channels" : @1
               }];
}
- (void)requestPreview:(NSString *)source {
    [self requestPreview:source mode:-1];
}
- (void)sendStereoAudio:(NSData *)pcm pts:(uint64_t)pts source:(NSString *)source {
    if (pcm.length > 48000 * 4 * 4 || pcm.length % 8)
        return;
    [[self proxy] audio:pcm
               metadata:@{
                   @"sourceID" : source,
                   @"ptsNS" : @(pts),
                   @"sampleRate" : @48000,
                   @"channels" : @2
               }];
}
- (void)requestPreview:(NSString *)source mode:(NSInteger)mode {
    {
        std::lock_guard<std::mutex> g(_lock);
        if (_previewPending)
            return;
        _previewPending = YES;
    }
    __weak KRClient *w = self;
    id<KRRenderService> p = [self proxy];
    if (!p) {
        std::lock_guard<std::mutex> g(_lock);
        _previewPending = NO;
        return;
    }
    [p preview:source
          mode:mode
         reply:^(IOSurface *s, NSDictionary *m) {
             KRClient *a = w;
             if (a) {
                 {
                     std::lock_guard<std::mutex> g(a->_lock);
                     a->_previewPending = NO;
                 }
                 [a received:s metadata:m];
             }
         }];
}
- (void)fetchStatus:(void (^)(NSDictionary *))reply {
    if (!self.connected) {
        [self connect];
        reply(@{@"connected" : @NO});
        return;
    }
    [[self proxy] status:reply];
}
- (void)startRecording:(NSDictionary *)options reply:(void (^)(NSDictionary *))reply {
    [[self proxy] record:options reply:reply];
}
- (void)stopRecording:(void (^)(NSDictionary *))reply {
    [[self proxy] stopRecording:reply];
}
- (void)reset:(NSString *)source {
    [[self proxy] reset:source];
}
- (void)publishOBS:(NSDictionary *)inventory reply:(void (^)(NSDictionary *))reply {
    [self connect];
    NSXPCConnection *connection;
    @synchronized(self) {
        connection = _connection;
    }
    auto done = std::make_shared<std::atomic<bool>>(false);
    void (^completion)(NSDictionary *) = ^(NSDictionary *result) {
        if (!done->exchange(true))
            reply(result);
    };
    if (!connection) {
        completion(@{});
        return;
    }
    __weak KRClient *weak = self;
    id<KRRenderService> proxy = [connection remoteObjectProxyWithErrorHandler:^(NSError *e) {
        [weak disconnect];
        completion(@{});
    }];
    [proxy publishOBS:inventory reply:completion];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                       completion(@{});
                   });
}
- (void)routeOBS:(NSDictionary *)settings instance:(NSString *)instanceID {
    [[self proxy] routeOBS:settings
                  instance:instanceID
                     reply:^(NSDictionary *r){
                     }];
}
- (void)dealloc {
    [self disconnect];
}
@end
