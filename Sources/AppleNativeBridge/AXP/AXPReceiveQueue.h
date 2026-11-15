#import <Foundation/Foundation.h>
@protocol DTXAllowedRPC <NSObject>
@end
@protocol ASAXReaderRPC <DTXAllowedRPC>
- (NSNumber *)hostAPIVersion;
- (void)processDataFromRemoteDevice:(NSData *)data;
@end
@interface ASAXReaderTarget : NSObject <ASAXReaderRPC>
- (void)checkHealth;
- (void)beginObservation;
- (NSDictionary *)finishObservation;
- (NSData *)takePacket;
- (NSDictionary *)budgetMetrics;
@end
