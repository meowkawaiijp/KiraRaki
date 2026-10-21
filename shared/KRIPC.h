#import <Foundation/Foundation.h>
#import <IOSurface/IOSurfaceObjC.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSString *const KRServiceName;
FOUNDATION_EXPORT NSDictionary *KRDefaultPreset(void);
FOUNDATION_EXPORT NSDictionary *_Nullable KRValidatePreset(NSDictionary *value, NSError **error);
FOUNDATION_EXPORT NSDictionary *KRInterpolatePreset(NSDictionary *from, NSDictionary *to,
                                                    double progress);
FOUNDATION_EXPORT NSXPCInterface *KRServiceInterface(void);
FOUNDATION_EXPORT IOSurface *_Nullable KRMakeSurface(NSUInteger width, NSUInteger height);
FOUNDATION_EXPORT uint64_t KRClockNS(void);

@protocol KRRenderService
- (void)hello:(NSDictionary *)identity reply:(void (^)(NSDictionary *))reply;
- (void)configure:(NSDictionary *)preset
           origin:(NSString *)origin
            reply:(void (^)(NSDictionary *))reply;
- (void)process:(IOSurface *)surface
       metadata:(NSDictionary *)metadata
          reply:(void (^)(IOSurface *_Nullable, NSDictionary *))reply;
- (void)audio:(NSData *)floatPCM metadata:(NSDictionary *)metadata;
- (void)preview:(NSString *)sourceID
           mode:(NSInteger)mode
          reply:(void (^)(IOSurface *_Nullable, NSDictionary *))reply;
- (void)status:(void (^)(NSDictionary *))reply;
- (void)record:(NSDictionary *)options reply:(void (^)(NSDictionary *))reply;
- (void)stopRecording:(void (^)(NSDictionary *))reply;
- (void)reset:(NSString *)sourceID;
- (void)publishOBS:(NSDictionary *)inventory reply:(void (^)(NSDictionary *))reply;
- (void)routeOBS:(NSDictionary *)settings
        instance:(NSString *)instanceID
           reply:(void (^)(NSDictionary *))reply;
@end

@interface KRClient : NSObject
@property(atomic, readonly) BOOL connected;
@property(atomic, readonly) NSDictionary *latestMetadata;
@property(atomic, copy, nullable) void (^onFrame)(IOSurface *, NSDictionary *);
@property(atomic, copy, nullable) void (^onError)(NSString *);
- (void)connect;
- (void)disconnect;
- (void)configure:(NSDictionary *)preset origin:(NSString *)origin;
- (BOOL)submitPixelBuffer:(CVPixelBufferRef)buffer
                      pts:(uint64_t)pts
                   source:(NSString *)source
                     mode:(NSInteger)mode;
- (BOOL)submitBGRA:(const void *)bytes
             width:(NSUInteger)width
            height:(NSUInteger)height
          rowBytes:(NSUInteger)rowBytes
               pts:(uint64_t)pts
            source:(NSString *)source
              mode:(NSInteger)mode;
- (void)sendAudio:(NSData *)pcm pts:(uint64_t)pts source:(NSString *)source;
- (void)sendStereoAudio:(NSData *)pcm pts:(uint64_t)pts source:(NSString *)source;
- (void)requestPreview:(NSString *)source;
- (void)requestPreview:(NSString *)source mode:(NSInteger)mode;
- (nullable IOSurface *)latestSurface;
- (void)fetchStatus:(void (^)(NSDictionary *))reply;
- (void)startRecording:(NSDictionary *)options reply:(void (^)(NSDictionary *))reply;
- (void)stopRecording:(void (^)(NSDictionary *))reply;
- (void)reset:(NSString *)source;
- (void)publishOBS:(NSDictionary *)inventory reply:(void (^)(NSDictionary *))reply;
- (void)routeOBS:(NSDictionary *)settings instance:(NSString *)instanceID;
@end
NS_ASSUME_NONNULL_END
