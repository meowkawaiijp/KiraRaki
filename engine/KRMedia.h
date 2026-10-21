#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <IOSurface/IOSurfaceObjC.h>
#import "KREngine.h"
NS_ASSUME_NONNULL_BEGIN
@interface KRMovieWriter : NSObject
@property(nonatomic, readonly) NSInteger frames;
@property(nonatomic, readonly, nullable) NSError *error;
- (nullable instancetype)initWithURL:(NSURL *)url
                               width:(NSInteger)width
                              height:(NSInteger)height
                               codec:(NSString *)codec
                               audio:(BOOL)audio
                            realtime:(BOOL)realtime
                               error:(NSError **)error;
- (BOOL)appendSurface:(IOSurface *)surface pts:(CMTime)pts;
- (BOOL)appendAudioSample:(CMSampleBufferRef)sample;
- (BOOL)appendMonoAudio:(NSData *)data pts:(CMTime)pts;
- (BOOL)appendStereoAudio:(NSData *)data pts:(CMTime)pts;
- (BOOL)finish:(NSError **)error;
@end
FOUNDATION_EXPORT BOOL KRExportMovie(NSURL *input, NSURL *output, NSString *shader,
                                     NSDictionary *preset, NSString *codec, NSInteger forcedMode,
                                     BOOL audio, NSURL *_Nullable events, void (^progress)(double),
                                     NSError **error);
FOUNDATION_EXPORT NSString *KRFileSHA256(NSURL *url);
NS_ASSUME_NONNULL_END
