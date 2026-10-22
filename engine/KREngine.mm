#import "KREngine.h"
#import "KRIPC.h"
#import <Metal/Metal.h>
#import <Vision/Vision.h>
#import <CoreImage/CoreImage.h>
#import <Accelerate/Accelerate.h>
#include "Contours.hpp"
#include <algorithm>
#include <atomic>
#include <cmath>
#include <mutex>
#include <numeric>

@implementation KREngine {
    id<MTLDevice> _device;
    id<MTLCommandQueue> _queue;
    NSMutableDictionary<NSString *, id<MTLComputePipelineState>> *_compute;
    id<MTLRenderPipelineState> _line;
    id<MTLTexture> _gray, _previous, _flow, _mask, _layer, _history[2], _small[3];
    id<MTLBuffer> _features;
    CIContext *_ci;
    dispatch_queue_t _visionQueue;
    std::mutex _visionLock;
    CVPixelBufferRef _visionMask;
    std::atomic<bool> _visionBusy;
    NSString *_visionError;
    BOOL _visionHasForeground;
    std::atomic<uint64_t> _generation;
    uint64_t _lastAudioNS;
    NSMutableDictionary<NSNumber *, IOSurface *> *_outputs;
    kira::Contours _contours;
    NSDictionary *_statistics;
    int _aw, _ah, _w, _h, _historyIndex, _frame, _level, _healthy, _bloomDivisor;
    double _lastPTS, _lastVision, _costEMA;
    std::vector<float> _audioWindow;
    std::vector<float> _prevSpectrum;
    std::array<float, 5> _audioFeatures;
    std::vector<float> _mappingState;
    FFTSetup _fft;
}
- (instancetype)initWithShader:(NSString *)path error:(NSError **)error {
    if ((self = [super init])) {
        _device = MTLCreateSystemDefaultDevice();
        if (!_device) {
            if (error)
                *error = [NSError
                    errorWithDomain:@"KiraRaki"
                               code:2
                           userInfo:@{NSLocalizedDescriptionKey : @"Metal GPUが見つかりません"}];
            return nil;
        }
        _queue = [_device newCommandQueue];
        NSString *src = [NSString stringWithContentsOfFile:path
                                                  encoding:NSUTF8StringEncoding
                                                     error:error];
        if (!src)
            return nil;
        id<MTLLibrary> lib = [_device newLibraryWithSource:src options:nil error:error];
        if (!lib)
            return nil;
        _compute = [NSMutableDictionary dictionary];
        for (NSString *n in
             @[ @"prepare", @"flow", @"features", @"downsample", @"blur", @"finish" ]) {
            _compute[n] = [_device newComputePipelineStateWithFunction:[lib newFunctionWithName:n]
                                                                 error:error];
            if (!_compute[n])
                return nil;
        }
        MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
        d.vertexFunction = [lib newFunctionWithName:@"line_vertex"];
        d.fragmentFunction = [lib newFunctionWithName:@"line_fragment"];
        d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
        d.colorAttachments[0].blendingEnabled = YES;
        d.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
        d.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        d.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        d.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        _line = [_device newRenderPipelineStateWithDescriptor:d error:error];
        if (!_line)
            return nil;
        _ci = [CIContext contextWithMTLDevice:_device];
        _visionQueue = dispatch_queue_create("jp.meowkawaii.kira.vision", DISPATCH_QUEUE_SERIAL);
        _statistics = @{};
        _outputs = [NSMutableDictionary dictionary];
        _lastPTS = -1;
        _fft = vDSP_create_fftsetup(11, kFFTRadix2);
        _prevSpectrum.resize(1024);
    }
    return self;
}
- (NSDictionary *)statistics {
    return _statistics;
}
- (IOSurface *)latestSurfaceForMode:(NSInteger)mode {
    return _outputs[@(mode)];
}
- (id<MTLTexture>)texture:(MTLPixelFormat)format w:(int)w h:(int)h {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                                                 width:w
                                                                                height:h
                                                                             mipmapped:NO];
    d.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget;
    d.storageMode = MTLStorageModePrivate;
    return [_device newTextureWithDescriptor:d];
}
- (void)dispatch:(NSString *)name
         command:(id<MTLCommandBuffer>)c
        textures:(NSArray *)textures
          buffer:(id<MTLBuffer>)buffer
           bytes:(const void *)bytes
          length:(NSUInteger)len
               w:(int)w
               h:(int)h {
    id<MTLComputeCommandEncoder> e = [c computeCommandEncoder];
    [e setComputePipelineState:_compute[name]];
    for (NSUInteger i = 0; i < textures.count; ++i)
        [e setTexture:textures[i] atIndex:i];
    if (buffer)
        [e setBuffer:buffer offset:0 atIndex:0];
    if (bytes)
        [e setBytes:bytes length:len atIndex:buffer ? 1 : 0];
    [e dispatchThreads:MTLSizeMake(w, h, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
    [e endEncoding];
}
- (void)reset {
    _generation++;
    {
        std::lock_guard<std::mutex> g(_visionLock);
        if (_visionMask)
            CVPixelBufferRelease(_visionMask);
        _visionMask = nullptr;
        _visionHasForeground = NO;
    }
    _lastVision = -1e30;
    _contours.reset();
    _gray = nil;
    _previous = nil;
    _history[0] = nil;
    _history[1] = nil;
    _lastPTS = -1;
    _audioWindow.clear();
    std::fill(_audioFeatures.begin(), _audioFeatures.end(), 0);
    _mappingState.clear();
    std::fill(_prevSpectrum.begin(), _prevSpectrum.end(), 0);
}
- (void)audio:(NSData *)data {
    _lastAudioNS = KRClockNS();
    const float *s = (const float *)data.bytes;
    size_t count = data.length / 4;
    for (size_t i = 0; i < count; ++i)
        _audioWindow.push_back(std::isfinite(s[i]) ? s[i] : 0);
    while (_audioWindow.size() >= 2048) {
        float window[2048], samples[2048], real[1024], imag[1024];
        vDSP_hann_window(window, 2048, vDSP_HANN_NORM);
        vDSP_vmul(_audioWindow.data(), 1, window, 1, samples, 1, 2048);
        DSPSplitComplex split{real, imag};
        vDSP_ctoz((DSPComplex *)samples, 2, &split, 1, 1024);
        vDSP_fft_zrip(_fft, &split, 1, 11, FFT_FORWARD);
        float bands[3] = {}, flux = 0, total = 0;
        int nums[3] = {};
        for (int i = 1; i < 513; ++i) {
            float mag = std::hypot(real[i], imag[i]) / 2048;
            float hz = i * 48000.f / 2048;
            int b = hz < 250 ? 0 : hz < 2000 ? 1 : 2;
            bands[b] += mag * mag;
            nums[b]++;
            flux += std::max(0.f, mag - _prevSpectrum[i]);
            _prevSpectrum[i] = mag;
        }
        for (int i = 0; i < 2048; ++i)
            total += _audioWindow[i] * _audioWindow[i];
        _audioFeatures[0] = std::min(1.f, std::sqrt(total / 2048) * 4);
        for (int i = 0; i < 3; ++i)
            _audioFeatures[i + 1] = std::min(1.f, std::sqrt(bands[i]) * 5);
        _audioFeatures[4] = std::min(1.f, flux * 1.8f);
        _audioWindow.erase(_audioWindow.begin(), _audioWindow.begin() + 512);
    }
    if (_audioWindow.size() > 8192)
        _audioWindow.erase(_audioWindow.begin(), _audioWindow.end() - 2048);
}
- (NSDictionary *)modulated:(NSDictionary *)preset dt:(float)dt {
    NSMutableDictionary *p = [preset mutableCopy];
    NSArray *maps = preset[@"audioMappings"];
    _mappingState.resize(maps.count, 0);
    NSArray *names = @[ @"rms", @"low", @"mid", @"high", @"onset" ];
    for (NSUInteger i = 0; i < maps.count; ++i) {
        NSDictionary *m = maps[i];
        NSUInteger idx = [names indexOfObject:m[@"feature"]];
        if (idx == NSNotFound)
            continue;
        float x = std::clamp(_audioFeatures[idx] * [m[@"gain"] floatValue], 0.f, 1.f);
        if ([m[@"invert"] boolValue])
            x = 1 - x;
        float tau = [m[x > _mappingState[i] ? @"attack" : @"release"] floatValue];
        float a = 1 - std::exp(-dt / std::max(.001f, tau));
        _mappingState[i] += a * (x - _mappingState[i]);
        float lo = [m[@"min"] floatValue], hi = [m[@"max"] floatValue];
        p[m[@"target"]] = @(lo + (hi - lo) * _mappingState[i]);
    }
    return KRValidatePreset(p, nullptr) ?: preset;
}
- (void)updateVision:(IOSurface *)surface pts:(double)pts mode:(int)mode {
    if (mode == 1)
        return;
    double interval = _offline ? 0 : (.1 * std::pow(1.6, _level));
    if (pts - _lastVision < interval || _visionBusy.exchange(true))
        return;
    _lastVision = pts;
    // Copy a small immutable input: capture/OBS may recycle its IOSurface once this frame replies.
    int vw = _level >= 2 ? 384 : 512,
        vh = std::max(1, int(surface.height * double(vw) / surface.width));
    CVPixelBufferRef pixel = nullptr;
    CVPixelBufferCreate(
        kCFAllocatorDefault, vw, vh, kCVPixelFormatType_32BGRA,
        (__bridge CFDictionaryRef) @{(id)kCVPixelBufferIOSurfacePropertiesKey : @{}}, &pixel);
    CGColorSpaceRef color = CGColorSpaceCreateWithName(kCGColorSpaceITUR_709);
    CIImage *image = [CIImage imageWithIOSurface:(__bridge IOSurfaceRef)surface
                                         options:@{kCIImageColorSpace : (__bridge id)color}];
    image =
        [image imageByApplyingTransform:CGAffineTransformMakeScale(double(vw) / surface.width,
                                                                   double(vh) / surface.height)];
    [_ci render:image toCVPixelBuffer:pixel bounds:CGRectMake(0, 0, vw, vh) colorSpace:color];
    CGColorSpaceRelease(color);
    uint64_t generation = _generation.load();
    void (^work)(void) = ^{
        @autoreleasepool {
            NSError *err = nil;
            VNImageRequestHandler *h = [[VNImageRequestHandler alloc] initWithCVPixelBuffer:pixel
                                                                                    options:@{}];
            VNGenerateForegroundInstanceMaskRequest *r =
                [VNGenerateForegroundInstanceMaskRequest new];
            CVPixelBufferRef result = nullptr;
            if ([h performRequests:@[ r ] error:&err]) {
                VNInstanceMaskObservation *o = r.results.firstObject;
                if (o && o.allInstances.count)
                    result = [o generateScaledMaskForImageForInstances:o.allInstances
                                                    fromRequestHandler:h
                                                                 error:&err];
            }
            if (!result) {
                VNGeneratePersonSegmentationRequest *person =
                    [VNGeneratePersonSegmentationRequest new];
                person.qualityLevel = self->_offline
                                          ? VNGeneratePersonSegmentationRequestQualityLevelAccurate
                                          : VNGeneratePersonSegmentationRequestQualityLevelBalanced;
                person.outputPixelFormat = kCVPixelFormatType_OneComponent8;
                [h performRequests:@[ person ] error:&err];
                VNPixelBufferObservation *o = person.results.firstObject;
                if (o) {
                    result = o.pixelBuffer;
                    CVPixelBufferRetain(result);
                }
            }
            BOOL foreground = NO;
            if (result) {
                CVPixelBufferLockBaseAddress(result, kCVPixelBufferLock_ReadOnly);
                if (CVPixelBufferGetPixelFormatType(result) == kCVPixelFormatType_OneComponent8) {
                    auto *bytes = (uint8_t *)CVPixelBufferGetBaseAddress(result);
                    for (size_t y = 0; y < CVPixelBufferGetHeight(result) && !foreground; y += 4)
                        for (size_t x = 0; x < CVPixelBufferGetWidth(result); x += 4)
                            if (bytes[y * CVPixelBufferGetBytesPerRow(result) + x] > 20) {
                                foreground = YES;
                                break;
                            }
                } else
                    foreground = YES;
                CVPixelBufferUnlockBaseAddress(result, kCVPixelBufferLock_ReadOnly);
            }
            {
                std::lock_guard<std::mutex> g(self->_visionLock);
                if (generation == self->_generation.load()) {
                    if (self->_visionMask)
                        CVPixelBufferRelease(self->_visionMask);
                    self->_visionMask = result;
                    self->_visionHasForeground = foreground;
                    self->_visionError = err.localizedDescription;
                } else if (result)
                    CVPixelBufferRelease(result);
            }
            CVPixelBufferRelease(pixel);
            self->_visionBusy = false;
        }
    };
    if (_offline)
        work();
    else
        dispatch_async(_visionQueue, work);
}
- (IOSurface *)render:(IOSurface *)surface
             metadata:(NSDictionary *)metadata
               preset:(NSDictionary *)base
                error:(NSError **)error {
    uint64_t start = KRClockNS();
    int w = int(surface.width), h = int(surface.height);
    if (!w || !h || w > 7680 || h > 4320 || surface.pixelFormat != kCVPixelFormatType_32BGRA)
        return nil;
    double pts = [metadata[@"ptsNS"] unsignedLongLongValue] * 1e-9;
    float dt = _lastPTS >= 0 ? std::clamp(float(pts - _lastPTS), 0.001f, .2f) : 1 / 30.f;
    if (pts < _lastPTS || pts - _lastPTS > 2)
        [self reset];
    if (!_offline && KRClockNS() - _lastAudioNS > 250000000)
        for (float &value : _audioFeatures)
            value *= std::exp2(-dt / .08f);
    NSDictionary *preset = [self modulated:base dt:dt];
    int analysis = [preset[@"analysisMode"] intValue];
    [self updateVision:surface pts:pts mode:analysis];
    int aw = std::min(w, _level >= 2 ? 384
                         : _offline  ? 960
                                     : 640),
        ah = std::max(1, int(h * double(aw) / w));
    int divisor = _level >= 5 ? 8 : (_offline ? 2 : 4);
    BOOL fresh = !_gray || _aw != aw || _ah != ah || w != _w || h != _h || _bloomDivisor != divisor;
    if (fresh) {
        _bloomDivisor = divisor;
        _aw = aw;
        _ah = ah;
        _w = w;
        _h = h;
        _gray = [self texture:MTLPixelFormatR32Float w:aw h:ah];
        _previous = [self texture:MTLPixelFormatR32Float w:aw h:ah];
        _flow = [self texture:MTLPixelFormatRG32Float w:(aw + 7) / 8 h:(ah + 7) / 8];
        _mask = [self texture:MTLPixelFormatR8Unorm w:aw h:ah];
        _layer = [self texture:MTLPixelFormatRGBA16Float w:w h:h];
        for (int i = 0; i < 2; ++i)
            _history[i] = [self texture:MTLPixelFormatRGBA16Float w:w h:h];
        for (int i = 0; i < 3; ++i)
            _small[i] = [self texture:MTLPixelFormatRGBA16Float
                                    w:std::max(1, w / _bloomDivisor)
                                    h:std::max(1, h / _bloomDivisor)];
        _features = [_device newBufferWithLength:aw * ah * sizeof(kira::Feature)
                                         options:MTLResourceStorageModeShared];
        _contours.reset();
    }
    MTLTextureDescriptor *inputDesc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                           width:w
                                                          height:h
                                                       mipmapped:NO];
    inputDesc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    id<MTLTexture> input = [_device newTextureWithDescriptor:inputDesc
                                                   iosurface:(__bridge IOSurfaceRef)surface
                                                       plane:0];
    if (!input)
        return nil;
    id<MTLCommandBuffer> c = [_queue commandBuffer];
    CVPixelBufferRef mask = nullptr;
    NSString *visionError;
    BOOL foreground = NO;
    {
        std::lock_guard<std::mutex> g(_visionLock);
        mask = _visionMask;
        if (mask)
            CVPixelBufferRetain(mask);
        visionError = _visionError;
        foreground = _visionHasForeground;
    }
    if (mask) {
        CIImage *im = [CIImage imageWithCVPixelBuffer:mask];
        im = [im imageByApplyingTransform:CGAffineTransformMakeScale(
                                              double(aw) / CVPixelBufferGetWidth(mask),
                                              double(ah) / CVPixelBufferGetHeight(mask))];
        CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
        [_ci render:im
             toMTLTexture:_mask
            commandBuffer:c
                   bounds:CGRectMake(0, 0, aw, ah)
               colorSpace:gray];
        CGColorSpaceRelease(gray);
        CVPixelBufferRelease(mask);
    } else {
        MTLRenderPassDescriptor *r = [MTLRenderPassDescriptor renderPassDescriptor];
        r.colorAttachments[0].texture = _mask;
        r.colorAttachments[0].loadAction = MTLLoadActionClear;
        r.colorAttachments[0].storeAction = MTLStoreActionStore;
        r.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
        [[c renderCommandEncoderWithDescriptor:r] endEncoding];
    }
    [self dispatch:@"prepare"
           command:c
          textures:@[ input, _gray ]
            buffer:nil
             bytes:nil
            length:0
                 w:aw
                 h:ah];
    if (fresh) {
        id<MTLBlitCommandEncoder> b = [c blitCommandEncoder];
        [b copyFromTexture:_gray toTexture:_previous];
        [b endEncoding];
        for (int i = 0; i < 2; ++i) {
            MTLRenderPassDescriptor *r = [MTLRenderPassDescriptor renderPassDescriptor];
            r.colorAttachments[0].texture = _history[i];
            r.colorAttachments[0].loadAction = MTLLoadActionClear;
            r.colorAttachments[0].storeAction = MTLStoreActionStore;
            r.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
            [[c renderCommandEncoderWithDescriptor:r] endEncoding];
        }
    }
    uint32_t flowRadius = _level >= 3 ? 2 : 4;
    [self dispatch:@"flow"
           command:c
          textures:@[ _gray, _previous, _flow ]
            buffer:nil
             bytes:&flowRadius
            length:sizeof(flowRadius)
                 w:(aw + 7) / 8
                 h:(ah + 7) / 8];
    uint32_t opts[4] = {
        (uint32_t)aw, (uint32_t)ah,
        (uint32_t)(analysis == 2 && !foreground && [preset[@"lossMode"] intValue] == 0 ? 1
                                                                                       : analysis),
        0};
    [self dispatch:@"features"
           command:c
          textures:@[ _gray, _previous, _mask, _flow ]
            buffer:_features
             bytes:opts
            length:sizeof(opts)
                 w:aw
                 h:ah];
    [c commit];
    [c waitUntilCompleted];
    if (c.error) {
        if (error)
            *error = c.error;
        return nil;
    }
    kira::Parameters p;
    p.width = [preset[@"lineWidth"] floatValue];
    p.distortion = [preset[@"distortion"] floatValue];
    p.density = [preset[@"density"] floatValue];
    p.threshold = [preset[@"threshold"] floatValue];
    p.lifetime = [preset[@"lifetime"] floatValue];
    p.tracking = [preset[@"tracking"] floatValue];
    p.updateHz = [preset[@"updateHz"] floatValue];
    p.irregularity = [preset[@"irregularity"] floatValue];
    p.strokeLength = [preset[@"strokeLength"] floatValue];
    p.jaggedSpacing = [preset[@"jaggedSpacing"] floatValue];
    p.motionResponse = [preset[@"motionResponse"] floatValue];
    p.seed = [preset[@"seed"] unsignedLongLongValue];
    p.hueSpeed = [preset[@"hueSpeed"] floatValue];
    p.hueOffset = [preset[@"hueOffset"] floatValue];
    p.colorMode = [preset[@"colorMode"] intValue];
    p.lossMode = [preset[@"lossMode"] intValue];
    p.maxStrokes = _offline ? 1200 : (_level >= 4 ? 220 : 550);
    for (int i = 0; i < 4; ++i)
        p.shapes[i] = [preset[@"shapes"][i] floatValue];
    for (int i = 0; i < 5; ++i)
        p.regions[i] = [preset[@"regions"][i] floatValue];
    for (int i = 0; i < 3; ++i)
        p.placement[i] = [preset[@"placement"][i] floatValue];
    p.palette.clear();
    for (NSString *s in preset[@"palette"]) {
        unsigned hex = 0;
        [[NSScanner scannerWithString:s] scanHexInt:&hex];
        p.palette.push_back({(hex >> 16) / 255.f, ((hex >> 8) & 255) / 255.f, (hex & 255) / 255.f});
    }
    auto vertices = _contours.update((kira::Feature *)_features.contents, aw, ah, w, h, pts, p);
    id<MTLCommandBuffer> draw = [_queue commandBuffer];
    MTLRenderPassDescriptor *r = [MTLRenderPassDescriptor renderPassDescriptor];
    r.colorAttachments[0].texture = _layer;
    r.colorAttachments[0].loadAction = MTLLoadActionClear;
    r.colorAttachments[0].storeAction = MTLStoreActionStore;
    r.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
    id<MTLRenderCommandEncoder> e = [draw renderCommandEncoderWithDescriptor:r];
    [e setRenderPipelineState:_line];
    if (!vertices.empty()) {
        id<MTLBuffer> vb = [_device newBufferWithBytes:vertices.data()
                                                length:vertices.size() * sizeof(kira::Vertex)
                                               options:MTLResourceStorageModeShared];
        [e setVertexBuffer:vb offset:0 atIndex:0];
        float size[2] = {(float)w, (float)h};
        [e setVertexBytes:size length:sizeof(size) atIndex:1];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:vertices.size()];
    }
    [e endEncoding];
    int sw = std::max(1, w / _bloomDivisor), sh = std::max(1, h / _bloomDivisor);
    [self dispatch:@"downsample"
           command:draw
          textures:@[ _layer, _small[0] ]
            buffer:nil
             bytes:nil
            length:0
                 w:sw
                 h:sh];
    float radius =
        [preset[@"glowRadius"] floatValue] * (float(h) / 1080.f) / std::max(1, _bloomDivisor);
    float dir[4] = {1.f / sw, 0, std::max(.5f, radius), 0};
    [self dispatch:@"blur"
           command:draw
          textures:@[ _small[0], _small[1] ]
            buffer:nil
             bytes:dir
            length:sizeof(dir)
                 w:sw
                 h:sh];
    dir[0] = 0;
    dir[1] = 1.f / sh;
    [self dispatch:@"blur"
           command:draw
          textures:@[ _small[1], _small[2] ]
            buffer:nil
             bytes:dir
            length:sizeof(dir)
                 w:sw
                 h:sh];
    float half = [preset[@"trailHalfLife"] floatValue];
    struct {
        float glow, decay, enabled, pad;
        uint32_t mode, w, h, pad2;
    } finish{[preset[@"glow"] floatValue],
             half > 0 ? std::exp2(-dt / half) : 0.f,
             [preset[@"enabled"] boolValue] ? 1.f : 0.f,
             0,
             (uint32_t)(metadata[@"mode"] ? [metadata[@"mode"] intValue]
                                          : [preset[@"outputMode"] intValue]),
             (uint32_t)w,
             (uint32_t)h,
             0};
    if (!finish.enabled)
        finish.decay = 0;
    int selectedMode = finish.mode;
    for (int mode = 0; mode < 3; ++mode) {
        IOSurface *surface = KRMakeSurface(w, h);
        _outputs[@(mode)] = surface;
        id<MTLTexture> target = [_device newTextureWithDescriptor:inputDesc
                                                        iosurface:(__bridge IOSurfaceRef)surface
                                                            plane:0];
        finish.mode = mode;
        [self dispatch:@"finish"
               command:draw
              textures:@[
                  input, _layer, _small[2], _history[_historyIndex], _history[1 - _historyIndex],
                  target
              ]
                buffer:nil
                 bytes:&finish
                length:sizeof(finish)
                     w:w
                     h:h];
    }
    [draw commit];
    [draw waitUntilCompleted];
    if (draw.error) {
        if (error)
            *error = draw.error;
        return nil;
    }
    _historyIndex = 1 - _historyIndex;
    std::swap(_gray, _previous);
    _lastPTS = pts;
    ++_frame;
    double cost = (KRClockNS() - start) * 1e-6;
    _costEMA = _costEMA > 0 ? _costEMA * .92 + cost * .08 : cost;
    if (!_offline && [preset[@"autoAdapt"] boolValue]) {
        if (_costEMA > 29 && _frame % 30 == 0) {
            _level = std::min(5, _level + 1);
            _healthy = 0;
        } else if (_costEMA < 19 && ++_healthy > 240) {
            _level = std::max(0, _level - 1);
            _healthy = 0;
        }
    } else
        _level = 0;
    _statistics = @{
        @"processingMS" : @(cost),
        @"strokes" : @(_contours.statistics.strokes),
        @"vertices" : @(_contours.statistics.vertices),
        @"candidates" : @(_contours.statistics.candidates),
        @"adaptationLevel" : @(_level),
        @"analysisWidth" : @(aw),
        @"visionReady" : @(foreground),
        @"visionError" : visionError ?: @"",
        @"audio" : @[
            @(_audioFeatures[0]), @(_audioFeatures[1]), @(_audioFeatures[2]), @(_audioFeatures[3]),
            @(_audioFeatures[4])
        ],
        @"fps" : @(1 / dt)
    };
    return _outputs[@(std::clamp(selectedMode, 0, 2))];
}
- (void)dealloc {
    if (_visionMask)
        CVPixelBufferRelease(_visionMask);
    if (_fft)
        vDSP_destroy_fftsetup(_fft);
}
@end
