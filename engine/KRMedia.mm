#import "KRMedia.h"
#import "KRIPC.h"
#import <CommonCrypto/CommonDigest.h>
#include <thread>
#include <chrono>
#include <vector>
#include <cmath>

NSString *KRFileSHA256(NSURL *url) {
    NSInputStream *s = [NSInputStream inputStreamWithURL:url];
    [s open];
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    uint8_t bytes[65536];
    NSInteger n;
    while ((n = [s read:bytes maxLength:sizeof(bytes)]) > 0)
        CC_SHA256_Update(&context, bytes, (CC_LONG)n);
    [s close];
    if (n < 0)
        return @"";
    unsigned char result[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(result, &context);
    NSMutableString *out = [NSMutableString string];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; ++i)
        [out appendFormat:@"%02x", result[i]];
    return out;
}

@implementation KRMovieWriter {
    AVAssetWriter *_writer;
    AVAssetWriterInput *_video, *_audio;
    AVAssetWriterInputPixelBufferAdaptor *_adaptor;
    NSInteger _frames;
    BOOL _realtime;
    NSError *_localError;
}
- (instancetype)initWithURL:(NSURL *)url
                      width:(NSInteger)w
                     height:(NSInteger)h
                      codec:(NSString *)codec
                      audio:(BOOL)audio
                   realtime:(BOOL)realtime
                      error:(NSError **)error {
    if ((self = [super init])) {
        _realtime = realtime;
        if ([[NSFileManager defaultManager] fileExistsAtPath:url.path]) {
            if (error)
                *error = [NSError
                    errorWithDomain:@"KiraRaki"
                               code:10
                           userInfo:@{
                               NSLocalizedDescriptionKey : @"同名の出力ファイルが既にあります"
                           }];
            return nil;
        }
        BOOL mp4 = [codec isEqual:@"h264"];
        AVVideoCodecType type = mp4                             ? AVVideoCodecTypeH264
                                : [codec isEqual:@"hevc-alpha"] ? AVVideoCodecTypeHEVCWithAlpha
                                : [codec isEqual:@"prores422"]  ? AVVideoCodecTypeAppleProRes422HQ
                                                                : AVVideoCodecTypeAppleProRes4444;
        _writer =
            [[AVAssetWriter alloc] initWithURL:url
                                      fileType:mp4 ? AVFileTypeMPEG4 : AVFileTypeQuickTimeMovie
                                         error:error];
        if (!_writer)
            return nil;
        NSMutableDictionary *settings = [@{
            AVVideoCodecKey : type,
            AVVideoWidthKey : @(w),
            AVVideoHeightKey : @(h),
            AVVideoColorPropertiesKey : @{
                AVVideoColorPrimariesKey : AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey : AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey : AVVideoYCbCrMatrix_ITU_R_709_2
            }
        } mutableCopy];
        if (mp4)
            settings[AVVideoCompressionPropertiesKey] = @{
                AVVideoAverageBitRateKey : @(w * h * 6),
                AVVideoExpectedSourceFrameRateKey : @30,
                AVVideoMaxKeyFrameIntervalKey : @60
            };
        if (![_writer canApplyOutputSettings:settings forMediaType:AVMediaTypeVideo]) {
            if (error)
                *error = [NSError errorWithDomain:@"KiraRaki"
                                             code:11
                                         userInfo:@{
                                             NSLocalizedDescriptionKey :
                                                 @"このMacでは選択したコーデックを利用できません"
                                         }];
            return nil;
        }
        _video = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                                    outputSettings:settings];
        _video.expectsMediaDataInRealTime = realtime;
        _adaptor = [AVAssetWriterInputPixelBufferAdaptor
            assetWriterInputPixelBufferAdaptorWithAssetWriterInput:_video
                                       sourcePixelBufferAttributes:@{
                                           (id)kCVPixelBufferPixelFormatTypeKey :
                                               @(kCVPixelFormatType_32BGRA),
                                           (id)kCVPixelBufferWidthKey : @(w),
                                           (id)kCVPixelBufferHeightKey : @(h),
                                           (id)kCVPixelBufferIOSurfacePropertiesKey : @{}
                                       }];
        if (![_writer canAddInput:_video])
            return nil;
        [_writer addInput:_video];
        if (audio) {
            _audio = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio
                                                        outputSettings:@{
                                                            AVFormatIDKey : @(kAudioFormatMPEG4AAC),
                                                            AVSampleRateKey : @48000,
                                                            AVNumberOfChannelsKey : @2,
                                                            AVEncoderBitRateKey : @192000
                                                        }];
            _audio.expectsMediaDataInRealTime = realtime;
            if ([_writer canAddInput:_audio])
                [_writer addInput:_audio];
            else
                _audio = nil;
        }
        if (![_writer startWriting]) {
            if (error)
                *error = _writer.error;
            return nil;
        }
        [_writer startSessionAtSourceTime:kCMTimeZero];
    }
    return self;
}
- (NSInteger)frames {
    return _frames;
}
- (NSError *)error {
    return _localError ?: _writer.error;
}
- (BOOL)ready:(AVAssetWriterInput *)input {
    if (!input)
        return NO;
    if (_realtime)
        return input.readyForMoreMediaData;
    while (!input.readyForMoreMediaData && _writer.status == AVAssetWriterStatusWriting)
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    return _writer.status == AVAssetWriterStatusWriting;
}
- (BOOL)appendSurface:(IOSurface *)surface pts:(CMTime)pts {
    if (![self ready:_video])
        return NO;
    CVPixelBufferRef pixel = nullptr;
    CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, (__bridge IOSurfaceRef)surface,
                                     (__bridge CFDictionaryRef) @{}, &pixel);
    if (!pixel)
        return NO;
    CVBufferSetAttachment(pixel, kCVImageBufferColorPrimariesKey,
                          kCVImageBufferColorPrimaries_ITU_R_709_2,
                          kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pixel, kCVImageBufferTransferFunctionKey,
                          kCVImageBufferTransferFunction_ITU_R_709_2,
                          kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pixel, kCVImageBufferYCbCrMatrixKey,
                          kCVImageBufferYCbCrMatrix_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pixel, kCVImageBufferAlphaChannelModeKey,
                          kCVImageBufferAlphaChannelMode_PremultipliedAlpha,
                          kCVAttachmentMode_ShouldPropagate);
    BOOL ok = [_adaptor appendPixelBuffer:pixel withPresentationTime:pts];
    CVPixelBufferRelease(pixel);
    if (ok)
        _frames++;
    return ok;
}
- (BOOL)appendAudioSample:(CMSampleBufferRef)sample {
    if (!_audio)
        return YES;
    if (CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), kCMTimeZero) < 0)
        return YES;
    if (![self ready:_audio])
        return NO;
    return [_audio appendSampleBuffer:sample];
}
- (BOOL)appendMonoAudio:(NSData *)data pts:(CMTime)pts {
    if (!_audio || !data.length)
        return YES;
    size_t frames = data.length / sizeof(float);
    NSMutableData *stereo = [NSMutableData dataWithLength:frames * 8];
    const float *src = (const float *)data.bytes;
    float *dst = (float *)stereo.mutableBytes;
    for (size_t i = 0; i < frames; i++)
        dst[i * 2] = dst[i * 2 + 1] = src[i];
    return [self appendStereoAudio:stereo pts:pts];
}
- (BOOL)appendStereoAudio:(NSData *)stereo pts:(CMTime)pts {
    if (!_audio || !stereo.length)
        return YES;
    if (stereo.length % 8)
        return NO;
    size_t frames = stereo.length / 8;
    AudioStreamBasicDescription asbd = {48000,
                                        kAudioFormatLinearPCM,
                                        kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                        8,
                                        1,
                                        8,
                                        2,
                                        32,
                                        0};
    CMAudioFormatDescriptionRef format = nullptr;
    CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &asbd, 0, nullptr, 0, nullptr, nullptr,
                                   &format);
    CMBlockBufferRef block = nullptr;
    CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, nullptr, stereo.length,
                                       kCFAllocatorDefault, nullptr, 0, stereo.length, 0, &block);
    CMBlockBufferReplaceDataBytes(stereo.bytes, block, 0, stereo.length);
    CMSampleTimingInfo timing = {CMTimeMake(1, 48000), pts, kCMTimeInvalid};
    size_t sampleSize = 8;
    CMSampleBufferRef sample = nullptr;
    CMSampleBufferCreateReady(kCFAllocatorDefault, block, format, frames, 1, &timing, 1,
                              &sampleSize, &sample);
    BOOL ok = sample ? [self appendAudioSample:sample] : NO;
    if (sample)
        CFRelease(sample);
    if (block)
        CFRelease(block);
    if (format)
        CFRelease(format);
    return ok;
}
- (BOOL)finish:(NSError **)error {
    if (_writer.status != AVAssetWriterStatusWriting) {
        if (error)
            *error = _writer.error;
        return NO;
    }
    [_video markAsFinished];
    [_audio markAsFinished];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [_writer finishWritingWithCompletionHandler:^{
        dispatch_semaphore_signal(done);
    }];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    if (error)
        *error = _writer.error;
    return _writer.status == AVAssetWriterStatusCompleted;
}
@end

static CMSampleBufferRef retime(CMSampleBufferRef sample, CMTime offset) {
    CMItemCount count = 0;
    CMSampleBufferGetSampleTimingInfoArray(sample, 0, nullptr, &count);
    std::vector<CMSampleTimingInfo> t(count);
    CMSampleBufferGetSampleTimingInfoArray(sample, count, t.data(), &count);
    for (auto &v : t) {
        v.presentationTimeStamp = CMTimeSubtract(v.presentationTimeStamp, offset);
        if (CMTIME_IS_VALID(v.decodeTimeStamp))
            v.decodeTimeStamp = CMTimeSubtract(v.decodeTimeStamp, offset);
    }
    CMSampleBufferRef copy = nullptr;
    CMSampleBufferCreateCopyWithNewTiming(kCFAllocatorDefault, sample, count, t.data(), &copy);
    return copy;
}
BOOL KRExportMovie(NSURL *input, NSURL *output, NSString *shader, NSDictionary *preset,
                   NSString *codec, NSInteger forcedMode, BOOL audio, NSURL *events,
                   void (^progress)(double), NSError **error) {
    auto fail = [&](NSString *message) -> BOOL {
        if (error)
            *error = [NSError errorWithDomain:@"KiraRaki"
                                         code:12
                                     userInfo:@{NSLocalizedDescriptionKey : message}];
        return NO;
    };
    NSDictionary *manifest = nil;
    NSMutableArray *log = [NSMutableArray array];
    if (events) {
        NSURL *manifestURL =
            [[events URLByDeletingLastPathComponent] URLByAppendingPathComponent:@"manifest.json"];
        NSData *manifestData = [NSData dataWithContentsOfURL:manifestURL];
        if (manifestData) {
            manifest = [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:error];
            if (![manifest isKindOfClass:NSDictionary.class] ||
                [manifest[@"schemaVersion"] intValue] != 1)
                return fail(@"再現マニフェストの形式が不正です");
            if (![manifest[@"algorithmVersion"] isEqual:@"0.1.0"])
                return fail(@"異なるアルゴリズムバージョンの録画です");
            if (![manifest[@"complete"] boolValue])
                return fail(@"録画が完了していないか、入力映像の欠落が記録されています");
            NSString *expected = manifest[@"inputSHA256"];
            if (!expected.length || ![KRFileSHA256(input) isEqual:expected])
                return fail(@"入力映像のSHA-256が録画時の記録と一致しません");
        }
        NSData *eventData = [NSData dataWithContentsOfURL:events options:0 error:error];
        if (!eventData)
            return NO;
        if (eventData.length > 64 * 1024 * 1024)
            return fail(@"操作ログが大きすぎます");
        NSString *text = [[NSString alloc] initWithData:eventData encoding:NSUTF8StringEncoding];
        if (!text)
            return fail(@"操作ログはUTF-8で保存してください");
        uint64_t previous = 0;
        for (NSString *line in
             [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
            if (!line.length)
                continue;
            NSDictionary *event = [NSJSONSerialization
                JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding]
                           options:0
                             error:error];
            if (![event isKindOfClass:NSDictionary.class] ||
                ![event[@"timestampNS"] isKindOfClass:NSNumber.class] ||
                [event[@"timestampNS"] unsignedLongLongValue] < previous)
                return fail(@"操作ログの時刻順が不正です");
            if (event[@"preset"] && !KRValidatePreset(event[@"preset"], error))
                return NO;
            previous = [event[@"timestampNS"] unsignedLongLongValue];
            [log addObject:event];
        }
    }
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:input
                                            options:@{
                                                AVURLAssetPreferPreciseDurationAndTimingKey : @YES
                                            }];
    AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    if (!track)
        return fail(@"入力に動画トラックがありません");
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:error];
    if (!reader)
        return NO;
    AVAssetReaderTrackOutput *video = [AVAssetReaderTrackOutput
        assetReaderTrackOutputWithTrack:track
                         outputSettings:@{
                             (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
                             (id)kCVPixelBufferIOSurfacePropertiesKey : @{}
                         }];
    video.alwaysCopiesSampleData = NO;
    [reader addOutput:video];
    AVAssetReaderTrackOutput *sound = nil;
    AVAssetTrack *audioTrack = [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
    if (audioTrack) {
        sound =
            [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:audioTrack
                                                       outputSettings:@{
                                                           AVFormatIDKey : @(kAudioFormatLinearPCM),
                                                           AVSampleRateKey : @48000,
                                                           AVNumberOfChannelsKey : @2,
                                                           AVLinearPCMBitDepthKey : @32,
                                                           AVLinearPCMIsFloatKey : @YES,
                                                           AVLinearPCMIsNonInterleaved : @NO
                                                       }];
        [reader addOutput:sound];
    }
    CMTime start = kCMTimeZero;
    CMTime duration = asset.duration;
    if (manifest) {
        if ([manifest[@"inputPath"] isAbsolutePath])
            start = CMTimeMake([manifest[@"sourceStartPTSNS"] longLongValue], 1000000000);
        duration = CMTimeMake([manifest[@"durationNS"] longLongValue], 1000000000);
        if (!CMTIME_IS_NUMERIC(duration) || CMTimeCompare(duration, kCMTimeZero) <= 0)
            return fail(@"録画区間が空です");
        reader.timeRange = CMTimeRangeMake(start, duration);
    }
    if (![reader startReading]) {
        if (error)
            *error = reader.error;
        return NO;
    }
    KREngine *engine = [[KREngine alloc] initWithShader:shader error:error];
    if (!engine)
        return NO;
    engine.offline = YES;
    NSDictionary *target = preset, *from = nil;
    uint64_t transitionNS = 0;
    NSUInteger eventIndex = 0;
    KRMovieWriter *writer = nil;
    CMSampleBufferRef nextAudio = sound ? [sound copyNextSampleBuffer] : nullptr;
    CMTime origin = manifest ? start : kCMTimeInvalid;
    CGAffineTransform transform = track.preferredTransform;
    CIContext *ci = [CIContext contextWithOptions:nil];
    CGColorSpaceRef color = CGColorSpaceCreateWithName(kCGColorSpaceITUR_709);
    BOOL ok = YES;
    while (reader.status == AVAssetReaderStatusReading) {
        @autoreleasepool {
            CMSampleBufferRef frame = [video copyNextSampleBuffer];
            if (!frame)
                break;
            CVPixelBufferRef pixel = CMSampleBufferGetImageBuffer(frame);
            CMTime sourcePTS = CMSampleBufferGetPresentationTimeStamp(frame);
            if (!CMTIME_IS_VALID(origin))
                origin = sourcePTS;
            CMTime pts = CMTimeSubtract(sourcePTS, origin);
            if (CMTimeCompare(pts, kCMTimeZero) < 0) {
                CFRelease(frame);
                continue;
            }
            uint64_t ns = uint64_t(CMTimeGetSeconds(pts) * 1e9);
            auto effectiveAt = [&](uint64_t time) -> NSDictionary * {
                double seconds = [target[@"transitionSeconds"] doubleValue];
                return from && seconds > 0
                           ? KRInterpolatePreset(from, target,
                                                 double(time - transitionNS) * 1e-9 / seconds)
                           : target;
            };
            while (eventIndex < log.count &&
                   [log[eventIndex][@"timestampNS"] unsignedLongLongValue] <= ns) {
                NSDictionary *event = log[eventIndex++];
                if (event[@"preset"]) {
                    uint64_t time = [event[@"timestampNS"] unsignedLongLongValue];
                    NSDictionary *old = effectiveAt(time);
                    target = KRValidatePreset(event[@"preset"], error);
                    if (!target) {
                        ok = NO;
                        break;
                    }
                    from = [event[@"sourceType"] isEqual:@"preset"] ? old : nil;
                    transitionNS = time;
                    if ([event[@"clearTrails"] boolValue])
                        [engine reset];
                }
            }
            if (!ok) {
                CFRelease(frame);
                break;
            }
            NSDictionary *current = effectiveAt(ns);
            CIImage *image =
                [[CIImage imageWithCVPixelBuffer:pixel] imageByApplyingTransform:transform];
            CGRect extent = image.extent;
            image = [image imageByApplyingTransform:CGAffineTransformMakeTranslation(
                                                        -extent.origin.x, -extent.origin.y)];
            IOSurface *in = KRMakeSurface(NSUInteger(std::round(extent.size.width)),
                                          NSUInteger(std::round(extent.size.height)));
            if (!in) {
                CFRelease(frame);
                ok = fail(@"入力解像度が対応範囲を超えています");
                break;
            }
            CVPixelBufferRef normalized = nullptr;
            CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, (__bridge IOSurfaceRef)in,
                                             nullptr, &normalized);
            [ci render:image
                toCVPixelBuffer:normalized
                         bounds:CGRectMake(0, 0, in.width, in.height)
                     colorSpace:color];
            CVPixelBufferRelease(normalized);
            if (!writer) {
                writer = [[KRMovieWriter alloc] initWithURL:output
                                                      width:in.width
                                                     height:in.height
                                                      codec:codec
                                                      audio:audio && sound != nil
                                                   realtime:NO
                                                      error:error];
                if (!writer) {
                    CFRelease(frame);
                    ok = NO;
                    break;
                }
            }
            CMTime frameDuration = CMSampleBufferGetDuration(frame);
            if (!CMTIME_IS_NUMERIC(frameDuration) || CMTimeCompare(frameDuration, kCMTimeZero) <= 0)
                frameDuration = CMTimeMake(1, 30);
            while (nextAudio && CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(nextAudio),
                                              CMTimeAdd(sourcePTS, frameDuration)) < 0) {
                CMBlockBufferRef block = CMSampleBufferGetDataBuffer(nextAudio);
                size_t count = CMBlockBufferGetDataLength(block);
                NSMutableData *data = [NSMutableData dataWithLength:count],
                              *mono = [NSMutableData dataWithLength:count / 2];
                CMBlockBufferCopyDataBytes(block, 0, count, data.mutableBytes);
                float *samples = (float *)data.bytes, *m = (float *)mono.mutableBytes;
                for (size_t i = 0; i < count / 8; ++i)
                    m[i] = (samples[i * 2] + samples[i * 2 + 1]) * .5f;
                if ([current[@"audioInput"] intValue] != 2)
                    [engine audio:mono];
                if (audio) {
                    CMSampleBufferRef adjusted = retime(nextAudio, origin);
                    ok = [writer appendAudioSample:adjusted];
                    CFRelease(adjusted);
                }
                CFRelease(nextAudio);
                nextAudio = [sound copyNextSampleBuffer];
                if (!ok)
                    break;
            }
            uint64_t enginePTS =
                ns + (manifest ? [manifest[@"sourceStartPTSNS"] unsignedLongLongValue] : 0);
            IOSurface *out =
                ok ? [engine render:in
                           metadata:@{
                               @"ptsNS" : @(enginePTS),
                               @"mode" : forcedMode >= 0 ? @(forcedMode) : current[@"outputMode"]
                           }
                             preset:current
                              error:error]
                   : nil;
            if (!out || ![writer appendSurface:out pts:pts]) {
                if (error && !*error)
                    *error = writer.error;
                CFRelease(frame);
                ok = NO;
                break;
            }
            CFRelease(frame);
            if (progress)
                progress(CMTimeGetSeconds(duration) > 0
                             ? std::min(.999, CMTimeGetSeconds(pts) / CMTimeGetSeconds(duration))
                             : 0);
        }
    }
    while (ok && audio && writer && nextAudio) {
        CMSampleBufferRef adjusted = retime(nextAudio, origin);
        ok = [writer appendAudioSample:adjusted];
        CFRelease(adjusted);
        CFRelease(nextAudio);
        nextAudio = [sound copyNextSampleBuffer];
    }
    if (nextAudio)
        CFRelease(nextAudio);
    CGColorSpaceRelease(color);
    if (reader.status == AVAssetReaderStatusFailed) {
        if (error)
            *error = reader.error;
        ok = NO;
    }
    if (!writer)
        return fail(@"動画フレームを読み取れませんでした");
    if (![writer finish:error])
        ok = NO;
    if (progress && ok)
        progress(1);
    return ok;
}
