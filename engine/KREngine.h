#import <Foundation/Foundation.h>
#import <IOSurface/IOSurfaceObjC.h>
NS_ASSUME_NONNULL_BEGIN
@interface KREngine : NSObject
@property(nonatomic, readonly) NSDictionary *statistics;
@property(nonatomic) BOOL offline;
- (nullable instancetype)initWithShader:(NSString *)path error:(NSError **)error;
- (nullable IOSurface *)render:(IOSurface *)surface
                      metadata:(NSDictionary *)metadata
                        preset:(NSDictionary *)preset
                         error:(NSError **)error;
- (void)audio:(NSData *)floatPCM;
- (nullable IOSurface *)latestSurfaceForMode:(NSInteger)mode;
- (void)reset;
@end
NS_ASSUME_NONNULL_END
