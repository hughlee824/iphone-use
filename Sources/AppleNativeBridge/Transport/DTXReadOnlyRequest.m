#import "DTXReadOnlyRequest.h"
#import "NativeServiceFailure.h"
#import <objc/message.h>

@implementation ASDTXReadConnectionState {
    NSLock *_lock;
    BOOL _disconnected;
}
- (instancetype)init { if ((self = [super init])) _lock = [NSLock new]; return self; }
- (void)markDisconnected { [_lock lock]; _disconnected = YES; [_lock unlock]; }
- (BOOL)isDisconnected { [_lock lock]; BOOL value = _disconnected; [_lock unlock]; return value; }
@end

id ASDTXReadOnlyRequest(id channel, NSString *selector, NSTimeInterval timeout,
                       ASDTXReadConnectionState *state, NSString *context) {
    return ASDTXReadOnlyRequestWithObjects(channel, selector, @[], timeout, state, context);
}

id ASDTXReadOnlyRequestWithObjects(id channel, NSString *selector, NSArray *objects, NSTimeInterval timeout,
                                  ASDTXReadConnectionState *state, NSString *context) {
    id message = ((id(*)(id, SEL, SEL, id))objc_msgSend)([NSClassFromString(@"DTXMessage") alloc],
        NSSelectorFromString(@"initWithSelector:objects:"), NSSelectorFromString(selector), objects);
    NSLock *lock = [NSLock new];
    __block id value; __block unsigned status; __block BOOL done = NO;
    ((void(*)(id, SEL, id, id))objc_msgSend)(channel, NSSelectorFromString(@"sendMessage:replyHandler:"), message, ^(id reply) {
        [lock lock];
        value = ((id(*)(id, SEL))objc_msgSend)(reply, NSSelectorFromString(@"object"));
        status = ((unsigned(*)(id, SEL))objc_msgSend)(reply, NSSelectorFromString(@"errorStatus"));
        done = YES; [lock unlock];
    });
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + timeout;
    while (YES) {
        [lock lock]; BOOL ready = done; unsigned code = status; id result = value; [lock unlock];
        if (ready && code) {
            // DTX status 2 is kDTXInterruptionMessage, also generated locally on disconnect.
            // Do not infer connection loss from the status alone or from error text.
            // Cancellation can become visible AFTER the reply callback; use the SAME deadline.
            if (code == 2 && NSProcessInfo.processInfo.systemUptime < deadline) {
                BOOL cancelled = [channel respondsToSelector:NSSelectorFromString(@"isCanceled")]
                    && ((BOOL(*)(id, SEL))objc_msgSend)(channel, NSSelectorFromString(@"isCanceled"));
                BOOL disconnected = [state isDisconnected] || cancelled;
                // State access / scheduling may itself cross the deadline. Late evidence
                // must not upgrade an uncorroborated interruption into a retryable failure.
                if (disconnected && NSProcessInfo.processInfo.systemUptime < deadline)
                    ASNativeConnectionFail([NSString stringWithFormat:@"%@ interrupted: status=2, connection closed", context]);
            }
            if (code != 2 || NSProcessInfo.processInfo.systemUptime >= deadline)
                ASNativeSemanticFail([NSString stringWithFormat:@"%@ request refused: status=%u", context, code]);
        } else {
            if (NSProcessInfo.processInfo.systemUptime >= deadline)
                ASNativeConnectionFail([context stringByAppendingString:@" reply timed out"]);
            if (ready) return result;
        }
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
    }
}
