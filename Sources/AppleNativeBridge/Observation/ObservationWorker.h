#import "../AXP/AXPInternal.h"
#import "../Transport/NativeServiceFailure.h"
#import "../Transport/CoreDeviceProxy/DeviceServiceTransport.h"
@interface ASObservationCommands : NSObject
- (instancetype)initWithGeneration:(NSString *)generation;
- (BOOL)canStartScreenshotAt:(NSTimeInterval)uptime;
@property(nonatomic, readonly) NSValue *focusPoint;
- (void)ready;
- (BOOL)next;
- (BOOL)nextWithHealthCheck:(void (^)(void))check;
- (void)publish:(NSDictionary *)value;
- (void)closed:(NSDictionary *)facts error:(NSString *)error;
- (void)closed:(NSDictionary *)facts error:(NSString *)error kind:(NSString *)kind;
@end
NSDictionary *ASRunAXObservation(NSString *device, ASObservationCommands *commands);
NSDictionary *ASRunScreenshotObservation(NSString *device, ASObservationCommands *commands);
