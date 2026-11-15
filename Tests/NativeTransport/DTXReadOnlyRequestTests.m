#import "DTXReadOnlyRequest.h"
#import "NativeServiceFailure.h"
#import <objc/message.h>
#import <dlfcn.h>
#import <sys/socket.h>
#import <unistd.h>

@interface TestReply : NSObject
@property unsigned errorStatus;
@property id object;
@end
@implementation TestReply
@end
@interface TestChannel : NSObject
@property unsigned code;
@property BOOL isCanceled;
@property NSTimeInterval replyDelay;
@property NSTimeInterval disconnectDelay;
@property BOOL blockRunLoop;
@property BOOL blockCompleted;
@property BOOL lateSuccess;
@property ASDTXReadConnectionState *state;
@end
@implementation TestChannel
- (void)sendMessage:(id)message replyHandler:(void(^)(id))handler {
    TestReply *reply = [TestReply new]; reply.errorStatus = self.code; reply.object = @"payload";
    if (self.blockRunLoop) {
        if (!self.lateSuccess) handler(reply);
        dispatch_async(dispatch_get_main_queue(), ^{
            usleep(150000);
            [self.state markDisconnected]; self.blockCompleted = YES;
            if (self.lateSuccess) handler(reply);
        });
        return;
    }
    if (self.disconnectDelay > 0) {
        ASDTXReadConnectionState *state = self.state;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, self.disconnectDelay * NSEC_PER_SEC), dispatch_get_global_queue(0, 0), ^{ [state markDisconnected]; });
    }
    if (self.replyDelay > 0)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, self.replyDelay * NSEC_PER_SEC), dispatch_get_global_queue(0, 0), ^{ handler(reply); });
    else handler(reply);
}
@end
@interface DelayedDisconnectState : ASDTXReadConnectionState
@property BOOL queried;
@end
@implementation DelayedDisconnectState
- (BOOL)isDisconnected {
    self.queried = YES;
    usleep(150000); [self markDisconnected];
    return [super isDisconnected];
}
@end
static void Check(BOOL value, NSString *message) { if (!value) { NSLog(@"FAIL: %@", message); exit(1); } }
static NSString *Failure(id channel, ASDTXReadConnectionState *state, double timeout) {
    @try { ASDTXReadOnlyRequest(channel, @"takeScreenshot", timeout, state, @"Screenshot"); return @"success"; }
    @catch (NSException *error) { return ASNativeFailureKind(error); }
}
static void Classification(void) {
    // Status 2 on a live channel is not enough. Other refusals stay semantic even after disconnect.
    for (NSNumber *code in @[@0, @1, @2, @3, @99]) for (NSNumber *closed in @[@NO, @YES]) {
        ASDTXReadConnectionState *state = [ASDTXReadConnectionState new];
        if (closed.boolValue) [state markDisconnected];
        TestChannel *channel = [TestChannel new]; channel.code = code.unsignedIntValue;
        NSString *expected = code.intValue == 0 ? @"success" : (code.intValue == 2 && closed.boolValue ? @"connection" : @"semantic");
        Check([Failure(channel, state, .03) isEqual:expected], [NSString stringWithFormat:@"code %@ closed %@", code, closed]);
    }
    TestChannel *cancelled = [TestChannel new]; cancelled.code = 2; cancelled.isCanceled = YES;
    Check([Failure(cancelled, [ASDTXReadConnectionState new], .1) isEqual:@"connection"], @"cancelled channel");
    TestChannel *delayed = [TestChannel new]; delayed.code = 2; delayed.disconnectDelay = .03; delayed.state = [ASDTXReadConnectionState new];
    Check([Failure(delayed, delayed.state, .2) isEqual:@"connection"], @"disconnect becomes visible after reply");
    // A late callback owns its captured state but cannot satisfy a subsequent call.
    TestChannel *late = [TestChannel new]; late.replyDelay = .08;
    Check([Failure(late, [ASDTXReadConnectionState new], .02) isEqual:@"connection"], @"late reply times out");
    TestChannel *fresh = [TestChannel new]; fresh.code = 1; fresh.replyDelay = .1;
    Check([Failure(fresh, [ASDTXReadConnectionState new], .3) isEqual:@"semantic"], @"late success cannot replace fresh refusal");
}
static void ExpiredEvidence(void) {
    // Force the response-consumer run loop past its deadline while real state changes occur.
    // This is not a normal async timeout (which could return before the late event fires).
    for (NSNumber *success in @[@NO, @YES]) {
        TestChannel *channel = [TestChannel new]; channel.code = success.boolValue ? 0 : 2;
        channel.blockRunLoop = YES; channel.lateSuccess = success.boolValue;
        channel.state = [ASDTXReadConnectionState new];
        NSString *kind = Failure(channel, channel.state, .05);
        Check(channel.blockCompleted, @"deadline reproduction executed blocked run loop");
        Check([kind isEqual:success.boolValue ? @"connection" : @"semantic"],
              @"late success rejected; late disconnect cannot authorize retry");
    }
    // Also cross the deadline INSIDE state access; a check only before the getter is insufficient.
    DelayedDisconnectState *state = [DelayedDisconnectState new];
    TestChannel *channel = [TestChannel new]; channel.code = 2;
    Check([Failure(channel, state, .05) isEqual:@"semantic"], @"deadline rechecked after state access");
    Check(state.queried, @"delayed state access executed");
}
static void RealTransport(BOOL pending) {
    int sockets[2]; Check(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0, @"socketpair");
    int owned = sockets[0], peer = sockets[1];
    ASDTXReadConnectionState *state = [ASDTXReadConnectionState new];
    dispatch_semaphore_t released = dispatch_semaphore_create(0);
    id transport = ((id(*)(id,SEL,int,id))objc_msgSend)([NSClassFromString(@"DTXSocketTransport") alloc], NSSelectorFromString(@"initWithConnectedSocket:disconnectAction:"), owned, ^{ [state markDisconnected]; close(owned); dispatch_semaphore_signal(released); });
    id connection = ((id(*)(id,SEL,id))objc_msgSend)([NSClassFromString(@"DTXConnection") alloc], NSSelectorFromString(@"initWithTransport:"), transport);
    ((void(*)(id,SEL))objc_msgSend)(connection, NSSelectorFromString(@"resume"));
    id channel = ((id(*)(id,SEL))objc_msgSend)(connection, NSSelectorFromString(@"defaultChannel"));
    if (pending) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC), dispatch_get_global_queue(0,0), ^{ close(peer); });
    else close(peer);
    double start = NSProcessInfo.processInfo.systemUptime;
    Check([Failure(channel, state, 2) isEqual:@"connection"], @"real DTX disconnect classification");
    Check(NSProcessInfo.processInfo.systemUptime - start < 1, @"real interruption must not fall through to timeout");
    ((void(*)(id,SEL))objc_msgSend)(connection, NSSelectorFromString(@"cancel"));
    Check(dispatch_semaphore_wait(released, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0, @"transport cleanup");
}
int main(void) { @autoreleasepool {
    Check(dlopen("/System/Library/PrivateFrameworks/DTXConnectionServices.framework/DTXConnectionServices", RTLD_NOW|RTLD_LOCAL) != NULL, @"system DTX framework");
    Classification(); ExpiredEvidence();
    for (int i=0; i<10; i++) { RealTransport(NO); RealTransport(YES); }
    puts("DTX classification, callback ordering, late replies and 20 real socket failures passed");
} }
