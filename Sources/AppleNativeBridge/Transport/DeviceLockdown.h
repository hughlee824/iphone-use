#import <Foundation/Foundation.h>

// Only in bounded subprocesses: MobileDevice C calls have no cancellation contract.
// Uses an existing USB pairing; never pairs or changes trust.
FOUNDATION_EXPORT void ASWithLockdownDevice(NSString *udid, void (^operation)(CFTypeRef device, void *library));
