#import <Foundation/Foundation.h>
// Only used in the bounded native transport subprocess. C ABI calls may block; the parent owns the deadline.
@interface ASDeviceUSBService : NSObject
- (instancetype)initWithUDID:(NSString *)udid;
@property(nonatomic, readonly) int socket;
- (NSData *)receive;
- (void)send:(NSData *)data;
- (void)close;
@end
