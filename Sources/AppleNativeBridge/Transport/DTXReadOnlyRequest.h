#import <Foundation/Foundation.h>

// Owned by one DTX connection. The transport callback may run on another queue.
@interface ASDTXReadConnectionState : NSObject
- (void)markDisconnected;
- (BOOL)isDisconnected;
@end

// For read-only observation requests only; this function never retries a request.
id ASDTXReadOnlyRequest(id channel, NSString *selector, NSTimeInterval timeout,
                       ASDTXReadConnectionState *state, NSString *context);

// AX requests carry archived arguments; classification and deadlines are shared with screenshots.
id ASDTXReadOnlyRequestWithObjects(id channel, NSString *selector, NSArray *objects, NSTimeInterval timeout,
                                  ASDTXReadConnectionState *state, NSString *context);
