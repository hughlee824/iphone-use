#import "../../NativeChannelInternal.h"
NS_ASSUME_NONNULL_BEGIN
// RSD discovery belongs to the provider, not to an individual service protocol.
// Does not open or cancel remoted's existing RSD connection. Isolated process only.
@interface ASDeviceServiceTransport : NSObject
- (instancetype)initWithUDID:(NSString *)udid;
- (instancetype)initWithUDID:(NSString *)udid sessionLifetime:(BOOL)sessionLifetime;
@property(nonatomic, readonly) uint64_t versionFlags;
- (int)openService:(NSString *)name; // caller owns the returned connected byte stream
- (BOOL)close;
@end
NS_ASSUME_NONNULL_END
