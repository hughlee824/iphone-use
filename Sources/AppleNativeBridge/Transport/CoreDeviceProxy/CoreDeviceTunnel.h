#import <Foundation/Foundation.h>
#import <arpa/inet.h>
NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT void ASDeviceTransportFail(NSString *reason);
// Owned USB IP tunnel backed by the native bounded packet adapter. Use once in an isolated worker process:
// MobileDevice C ABI calls can block; the parent must enforce a process deadline.
// This provider is independent of the existing CoreDevice broker for HID/media.
@interface ASCoreDeviceTunnel : NSObject
- (instancetype)initWithUDID:(NSString *)udid;
- (instancetype)initWithUDID:(NSString *)udid sessionLifetime:(BOOL)sessionLifetime;
@property(nonatomic, readonly) uint16_t discoveryPort;
- (int)connectPort:(uint16_t)port; // returned descriptor is owned by the caller; <= 4 streams total
- (BOOL)close;
@end
NS_ASSUME_NONNULL_END
