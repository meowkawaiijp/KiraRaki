#import "KREngine.h"
#import "KRIPC.h"
#import <Metal/Metal.h>
#import <Vision/Vision.h>
#import <CoreImage/CoreImage.h>
#import <Accelerate/Accelerate.h>
#include "Contours.hpp"
#include "Performance.hpp"
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <mutex>
#include <numeric>

@implementation KREngine {
    id<MTLDevice> _device;
    id<MTLCommandQueue> _queue;
    NSMutableDictionary<NSString *, id<MTLComputePipelineState>> *_compute;
    id<MTLRenderPipelineState> _line;
    id<MTLTexture> _gray, _previous, _flow, _mask, _layer, _history[2], _small[3];
    id<MTLBuffer> _features, _vertexBuffer, _ridgeMask;
    CIContext *_ci;
    dispatch_queue_t _visionQueue;
    std::mutex _visionLock;
    CVPixelBufferRef _visionMask;
    std::atomic<bool> _visionBusy;
    std::atomic<double> _visionMS;
    uint64_t _maskRevision, _uploadedMaskRevision;
    double _maskPTS;
    NSString *_visionError;
    BOOL _visionHasForeground;
    std::atomic<uint64_t> _generation;
    uint64_t _lastAudioNS;
    NSMutableDictionary<NSNumber *, IOSurface *> *_outputs;
    kira::Contours _contours;
    NSDictionary *_statistics;
    int _aw, _ah, _w, _h, _historyIndex, _bloomDivisor;
    double _lastPTS, _lastVision;
    kira::AdaptiveRender _adaptive;
    kira::RollingSamples<> _renderTimes, _outputIntervals;
    uint64_t _lastRenderNS;
    std::vector<float> _audioWindow;
    std::array<float, 2048> _hannWindow;
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
             @[ @"prepare", @"flow", @"features", @"classifyRidges", @"downsample", @"blur",
                @"finish", @"finishSingle" ]) {
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
        _lastVision = -1e30;
        _uploadedMaskRevision = UINT64_MAX;
        _gpuClassificationEnabled = YES;
        _fft = vDSP_create_fftsetup(11, kFFTRadix2);
        _prevSpectrum.resize(1024);
        vDSP_hann_window(_hannWindow.data(), _hannWindow.size(), vDSP_HANN_NORM);
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
        ++_maskRevision;
    }
    _uploadedMaskRevision = UINT64_MAX;
    _lastRenderNS = 0;
    _outputIntervals.clear();
    _renderTimes.clear();
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
    size_t consumed = 0;
    while (_audioWindow.size() - consumed >= 2048) {
        float samples[2048], real[1024], imag[1024];
        const float *window = _audioWindow.data() + consumed;
        vDSP_vmul(window, 1, _hannWindow.data(), 1, samples, 1, 2048);
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
            total += window[i] * window[i];
        _audioFeatures[0] = std::min(1.f, std::sqrt(total / 2048) * 4);
        for (int i = 0; i < 3; ++i)
            _audioFeatures[i + 1] = std::min(1.f, std::sqrt(bands[i]) * 5);
        _audioFeatures[4] = std::min(1.f, flux * 1.8f);
        consumed += 512;
    }
    if (consumed)
        _audioWindow.erase(_audioWindow.begin(), _audioWindow.begin() + consumed);
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
- (void)updateVision:(IOSurface *)surface pts:(double)pts mode:(int)mode
             profile:(kira::RenderProfile)profile interval:(double)interval
             command:(id<MTLCommandBuffer>)command {
    if (mode == 1)
        return;
    if (pts - _lastVision < interval || _visionBusy.exchange(true))
        return;
    _lastVision = pts;
    // Copy a small immutable input: capture/OBS may recycle its IOSurface once this frame replies.
    int vw = profile.visionWidth,
        vh = std::max(1, int(surface.height * double(vw) / surface.width));
    CVPixelBufferRef pixel = nullptr;
    CVReturn status = CVPixelBufferCreate(
        kCFAllocatorDefault, vw, vh, kCVPixelFormatType_32BGRA,
        (__bridge CFDictionaryRef) @{(id)kCVPixelBufferIOSurfacePropertiesKey : @{},
                                      (id)kCVPixelBufferMetalCompatibilityKey : @YES}, &pixel);
    if (status != kCVReturnSuccess || !pixel) {
        if (pixel)
            CVPixelBufferRelease(pixel);
        std::lock_guard<std::mutex> g(_visionLock);
        _visionError = @"Vision入力バッファを確保できませんでした";
        _visionBusy = false;
        return;
    }
    CGColorSpaceRef color = CGColorSpaceCreateWithName(kCGColorSpaceITUR_709);
    CIImage *image = [CIImage imageWithIOSurface:(__bridge IOSurfaceRef)surface
                                         options:@{kCIImageColorSpace : (__bridge id)color}];
    image =
        [image imageByApplyingTransform:CGAffineTransformMakeScale(double(vw) / surface.width,
                                                                   double(vh) / surface.height)];
    uint64_t generation = _generation.load();
    const BOOL offline = _offline;
    id<MTLTexture> visionInput = nil;
    if (!offline && command && CVPixelBufferGetIOSurface(pixel)) {
        MTLTextureDescriptor *d = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
            width:vw height:vh mipmapped:NO];
        d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead;
        visionInput = [_device newTextureWithDescriptor:d
                                               iosurface:CVPixelBufferGetIOSurface(pixel) plane:0];
    }
    if (visionInput)
        [_ci render:image toMTLTexture:visionInput commandBuffer:command
             bounds:CGRectMake(0, 0, vw, vh) colorSpace:color];
    else
        [_ci render:image toCVPixelBuffer:pixel bounds:CGRectMake(0, 0, vw, vh) colorSpace:color];
    CGColorSpaceRelease(color);
    void (^work)(void) = ^{
        @autoreleasepool {
            const uint64_t visionStart = KRClockNS();
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
                person.qualityLevel = offline
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
                    self->_maskPTS = pts;
                    ++self->_maskRevision;
                    self->_visionHasForeground = foreground;
                    self->_visionError = err.localizedDescription;
                } else if (result)
                    CVPixelBufferRelease(result);
            }
            CVPixelBufferRelease(pixel);
            self->_visionMS.store((KRClockNS() - visionStart) * 1e-6);
            self->_visionBusy = false;
        }
    };
    if (offline) {
        work();
    } else if (visionInput) {
        // The GPU copies the immutable input before Vision can read it.
        [command addCompletedHandler:^(id<MTLCommandBuffer> completed) {
            if (completed.status == MTLCommandBufferStatusCompleted)
                dispatch_async(self->_visionQueue, work);
            else {
                CVPixelBufferRelease(pixel);
                self->_visionBusy = false;
            }
        }];
    } else {
        dispatch_async(_visionQueue, work);
    }
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
    const bool adapt = !_offline && [preset[@"autoAdapt"] boolValue];
    if (!adapt)
        _adaptive.reset();
    const int usedLevel = _adaptive.level();
    const auto profile = _adaptive.profile(_offline);
    const double visionInterval = _adaptive.visionInterval(_offline, adapt, _visionMS.load());
    int aw = std::min(w, profile.width);
    int ah = std::max(1, int(h * double(aw) / w));
    int divisor = profile.bloomDivisor;
    const BOOL freshOutput = !_history[0] || !_history[1] || !_layer || w != _w || h != _h;
    const BOOL freshAnalysis = !_gray || !_previous || _aw != aw || _ah != ah || w != _w || h != _h;
    const BOOL freshBloom = !_small[0] || !_small[1] || !_small[2] ||
                            freshOutput || _bloomDivisor != divisor;
    if (freshAnalysis) {
        _aw = aw;
        _ah = ah;
        _gray = [self texture:MTLPixelFormatR32Float w:aw h:ah];
        _previous = [self texture:MTLPixelFormatR32Float w:aw h:ah];
        _flow = [self texture:MTLPixelFormatRG32Float w:(aw + 7) / 8 h:(ah + 7) / 8];
        _mask = [self texture:MTLPixelFormatR8Unorm w:aw h:ah];
        _features = [_device newBufferWithLength:size_t(aw) * ah * sizeof(kira::Feature)
                                         options:MTLResourceStorageModeShared];
        _ridgeMask = nil;
        _uploadedMaskRevision = UINT64_MAX;
        _contours.reset();
    }
    if (freshOutput) {
        _w = w;
        _h = h;
        _historyIndex = 0;
        _layer = [self texture:MTLPixelFormatRGBA16Float w:w h:h];
        for (int i = 0; i < 2; ++i)
            _history[i] = [self texture:MTLPixelFormatRGBA16Float w:w h:h];
    }
    if (freshBloom) {
        _bloomDivisor = divisor;
        for (int i = 0; i < 3; ++i)
            _small[i] = [self texture:MTLPixelFormatRGBA16Float
                                    w:std::max(1, w / divisor) h:std::max(1, h / divisor)];
    }
    // Optional mask: allocation failure falls back to the existing CPU path.
    const bool wantGPUClassify = !_offline && _gpuClassificationEnabled && size_t(aw) * ah >= 65536;
    if (wantGPUClassify && !_ridgeMask)
        _ridgeMask = [_device newBufferWithLength:size_t(aw) * ah options:MTLResourceStorageModeShared];
    const bool gpuClassify = wantGPUClassify && _ridgeMask != nil;
    if (!_gray || !_previous || !_flow || !_mask || !_layer || !_history[0] ||
        !_history[1] || !_small[0] || !_small[1] || !_small[2] || !_features) {
        [self reset];
        if (error)
            *error = [NSError errorWithDomain:@"KiraRaki" code:4
                                     userInfo:@{NSLocalizedDescriptionKey : @"Metal作業領域を確保できませんでした"}];
        return nil;
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
    if (!c)
        return nil;
    [self updateVision:surface pts:pts mode:analysis profile:profile
               interval:visionInterval command:c];
    CVPixelBufferRef mask = nullptr;
    NSString *visionError;
    BOOL foreground = NO;
    uint64_t maskRevision;
    double maskPTS;
    {
        std::lock_guard<std::mutex> g(_visionLock);
        mask = _visionMask;
        if (mask)
            CVPixelBufferRetain(mask);
        visionError = _visionError;
        foreground = _visionHasForeground;
        maskRevision = _maskRevision;
        maskPTS = _maskPTS;
    }
    uint32_t featureMode =
        analysis == 2 && !foreground && [preset[@"lossMode"] intValue] == 0 ? 1 : analysis;
    const bool uploadMask = featureMode != 1 && _uploadedMaskRevision != maskRevision;
    if (!uploadMask) {
        if (mask)
            CVPixelBufferRelease(mask);
    } else if (mask) {
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
    if (freshAnalysis) {
        id<MTLBlitCommandEncoder> b = [c blitCommandEncoder];
        [b copyFromTexture:_gray toTexture:_previous];
        [b endEncoding];
    }
    if (freshOutput) {
        for (int i = 0; i < 2; ++i) {
            MTLRenderPassDescriptor *r = [MTLRenderPassDescriptor renderPassDescriptor];
            r.colorAttachments[0].texture = _history[i];
            r.colorAttachments[0].loadAction = MTLLoadActionClear;
            r.colorAttachments[0].storeAction = MTLStoreActionStore;
            r.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
            [[c renderCommandEncoderWithDescriptor:r] endEncoding];
        }
    }
    uint32_t flowRadius = profile.flowRadius;
    [self dispatch:@"flow"
           command:c
          textures:@[ _gray, _previous, _flow ]
            buffer:nil
             bytes:&flowRadius
            length:sizeof(flowRadius)
                 w:(aw + 7) / 8
                 h:(ah + 7) / 8];
    uint32_t opts[4] = {(uint32_t)aw, (uint32_t)ah, featureMode, 0};
    [self dispatch:@"features"
           command:c
          textures:@[ _gray, _previous, _mask, _flow ]
            buffer:_features
             bytes:opts
            length:sizeof(opts)
                 w:aw
                 h:ah];
    if (gpuClassify) {
        struct RidgeOptions {
            uint32_t width, height;
            float threshold, sum, regions[5];
        } options{uint32_t(aw), uint32_t(ah), [preset[@"threshold"] floatValue], 0, {}};
        static_assert(sizeof(RidgeOptions) == 36);
        for (int i = 0; i < 5; ++i) {
            options.regions[i] = [preset[@"regions"][i] floatValue];
            options.sum += std::max(options.regions[i], 0.f);
        }
        options.sum = std::max(options.sum, .001f);
        id<MTLComputeCommandEncoder> encoder = [c computeCommandEncoder];
        [encoder setComputePipelineState:_compute[@"classifyRidges"]];
        [encoder setBuffer:_features offset:0 atIndex:0];
        [encoder setBuffer:_ridgeMask offset:0 atIndex:1];
        [encoder setBytes:&options length:sizeof(options) atIndex:2];
        [encoder dispatchThreads:MTLSizeMake(aw, ah, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
        [encoder endEncoding];
    }
    [c commit];
    // Overlap CPU preset decoding with GPU analysis. Stateful tracking remains ordered.
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
    p.maxStrokes = profile.maxStrokes;
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
    [c waitUntilCompleted];
    const uint64_t analysisEnd = KRClockNS();
    if (c.error) {
        if (error)
            *error = c.error;
        [self reset];
        return nil;
    }
    if (uploadMask)
        _uploadedMaskRevision = maskRevision;
    const uint64_t contourStart = KRClockNS();
    auto vertices = _contours.update((kira::Feature *)_features.contents, aw, ah, w, h, pts, p,
                                    gpuClassify ? (const uint8_t *)_ridgeMask.contents : nullptr);
    const uint64_t contourEnd = KRClockNS();
    // Both command buffers finish synchronously before render returns. Reuse this
    // session-local upload buffer, growing geometrically only when needed.
    const size_t vertexBytes = vertices.size() * sizeof(kira::Vertex);
    if (vertexBytes) {
        if (!_vertexBuffer || _vertexBuffer.length < vertexBytes) {
            size_t capacity = std::max<size_t>(65536, _vertexBuffer.length);
            while (capacity < vertexBytes)
                capacity *= 2;
            _vertexBuffer = [_device newBufferWithLength:capacity options:MTLResourceStorageModeShared];
        }
        if (!_vertexBuffer) {
            [self reset];
            if (error)
                *error = [NSError errorWithDomain:@"KiraRaki" code:4
                                         userInfo:@{NSLocalizedDescriptionKey : @"頂点バッファを確保できませんでした"}];
            return nil;
        }
        std::memcpy(_vertexBuffer.contents, vertices.data(), vertexBytes);
    }
    id<MTLCommandBuffer> draw = [_queue commandBuffer];
    MTLRenderPassDescriptor *r = [MTLRenderPassDescriptor renderPassDescriptor];
    r.colorAttachments[0].texture = _layer;
    r.colorAttachments[0].loadAction = MTLLoadActionClear;
    r.colorAttachments[0].storeAction = MTLStoreActionStore;
    r.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
    id<MTLRenderCommandEncoder> e = [draw renderCommandEncoderWithDescriptor:r];
    [e setRenderPipelineState:_line];
    if (!vertices.empty()) {
        [e setVertexBuffer:_vertexBuffer offset:0 atIndex:0];
        float size[2] = {(float)w, (float)h};
        [e setVertexBytes:size length:sizeof(size) atIndex:1];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:vertices.size()];
    }
    [e endEncoding];
    int sw = std::max(1, w / _bloomDivisor), sh = std::max(1, h / _bloomDivisor);
    const float glow = [preset[@"glow"] floatValue];
    const BOOL enabled = [preset[@"enabled"] boolValue];
    if (glow != 0 && enabled) {
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
    }
    float half = [preset[@"trailHalfLife"] floatValue];
    struct {
        float glow, decay, enabled, pad;
        uint32_t mode, w, h, pad2;
    } finish{glow,
             half > 0 ? std::exp2(-dt / half) : 0.f,
             enabled ? 1.f : 0.f,
             0,
             (uint32_t)(metadata[@"mode"] ? [metadata[@"mode"] intValue]
                                          : [preset[@"outputMode"] intValue]),
             (uint32_t)w,
             (uint32_t)h,
             0};
    if (!finish.enabled)
        finish.decay = 0;
    int selectedMode = std::clamp(int(finish.mode), 0, 2);
    finish.mode = uint32_t(selectedMode);
    // Keep distinct, newly allocated IOSurfaces: XPC/OBS clients may retain the
    // previous frame after render returns. Publish all three only on GPU success.
    NSMutableDictionary<NSNumber *, IOSurface *> *nextOutputs = [NSMutableDictionary dictionary];
    const bool singleOutput = _offline || _singleOutput;
    NSMutableArray<id<MTLTexture>> *targets = [NSMutableArray arrayWithCapacity:singleOutput ? 1 : 3];
    for (int mode = 0; mode < 3; ++mode) {
        if (singleOutput && mode != selectedMode)
            continue;
        IOSurface *output = KRMakeSurface(w, h);
        id<MTLTexture> target = output ? [_device newTextureWithDescriptor:inputDesc
                                                                 iosurface:(__bridge IOSurfaceRef)output
                                                                     plane:0] : nil;
        if (!target) {
            [self reset];
            if (error)
                *error = [NSError errorWithDomain:@"KiraRaki" code:4
                                         userInfo:@{NSLocalizedDescriptionKey : @"出力IOSurfaceを確保できませんでした"}];
            return nil;
        }
        nextOutputs[@(mode)] = output;
        [targets addObject:target];
    }
    NSArray *finishTextures = singleOutput
        ? @[input, _layer, _small[2], _history[_historyIndex], _history[1 - _historyIndex], targets[0]]
        : @[input, _layer, _small[2], _history[_historyIndex], _history[1 - _historyIndex],
            targets[0], targets[1], targets[2]];
    [self dispatch:(singleOutput ? @"finishSingle" : @"finish")
           command:draw
          textures:finishTextures
            buffer:nil
             bytes:&finish
            length:sizeof(finish)
                 w:w
                 h:h];
    [draw commit];
    [draw waitUntilCompleted];
    if (draw.error) {
        if (error)
            *error = draw.error;
        [self reset];
        return nil;
    }
    _outputs = nextOutputs;
    const uint64_t drawEnd = KRClockNS();
    _historyIndex = 1 - _historyIndex;
    std::swap(_gray, _previous);
    _lastPTS = pts;
    double cost = (KRClockNS() - start) * 1e-6;
    const double queueMS = std::max(0., [metadata[@"queueMS"] doubleValue]);
    _adaptive.observe(cost, queueMS, adapt);
    _renderTimes.push(cost);
    if (_lastRenderNS && drawEnd > _lastRenderNS)
        _outputIntervals.push((drawEnd - _lastRenderNS) * 1e-6);
    _lastRenderNS = drawEnd;
    const double outputFPS = _outputIntervals.mean() > 0 ? 1000. / _outputIntervals.mean() : 0;
    const double analysisGPU = c.GPUEndTime > c.GPUStartTime && c.GPUStartTime > 0
        ? (c.GPUEndTime - c.GPUStartTime) * 1000. : 0;
    const double drawGPU = draw.GPUEndTime > draw.GPUStartTime && draw.GPUStartTime > 0
        ? (draw.GPUEndTime - draw.GPUStartTime) * 1000. : 0;
    _statistics = @{
        @"processingMS" : @(cost),
        // Wall-clock phases include encoding, scheduling and GPU waits, not GPU-only timestamps.
        @"analysisMS" : @((analysisEnd - start) * 1e-6),
        @"contourMS" : @((contourEnd - contourStart) * 1e-6),
        @"drawMS" : @((drawEnd - contourEnd) * 1e-6),
        @"strokes" : @(_contours.statistics.strokes),
        @"vertices" : @(_contours.statistics.vertices),
        @"candidates" : @(_contours.statistics.candidates),
        @"adaptationLevel" : @(usedLevel),
        @"nextAdaptationLevel" : @(_adaptive.level()),
        @"analysisWidth" : @(aw),
        @"analysisHeight" : @(ah),
        @"gpuClassification" : @(gpuClassify),
        @"outputSurfaceCount" : @(nextOutputs.count),
        @"outputFPS" : @(outputFPS),
        @"processingP95MS" : @(_renderTimes.p95()),
        @"analysisGPUMS" : @(analysisGPU),
        @"drawGPUMS" : @(drawGPU),
        @"visionInferenceMS" : @(_visionMS.load()),
        @"visionIntervalMS" : @(visionInterval * 1000),
        @"visionMaskAgeMS" : @(foreground ? std::max(0., (pts - maskPTS) * 1000) : -1.),
        @"visionBusy" : @(_visionBusy.load()),
        @"queueMS" : @(queueMS),
        @"vertexBufferBytes" : @(_vertexBuffer.length),
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
