#import "ObservationWorker.h"
#import "DTXReadOnlyRequest.h"
#import <dlfcn.h>
#import <unistd.h>
#import <sys/socket.h>
#import "../../Sources/AppleNativeBridge/AXP/AXPReader.m"

@interface InterruptedReply : NSObject
@property unsigned code;
- (unsigned)errorStatus;
- (id)object;
@end
@implementation InterruptedReply
- (unsigned)errorStatus { return self.code ?: 2; }
- (id)object { return nil; }
@end
@interface InterruptedChannel : NSObject
@property unsigned code;
@end
@implementation InterruptedChannel
- (void)sendMessage:(id)message replyHandler:(void(^)(id))handler { InterruptedReply *reply=[InterruptedReply new]; reply.code=self.code; handler(reply); }
@end
static ASObservationCommands *lateCommands;

// Exercise the production AX acknowledgement branch with a real system DTX disconnect.
static void AXCallFailure(NSString *mode) {
    if (!dlopen("/System/Library/PrivateFrameworks/DTXConnectionServices.framework/DTXConnectionServices", RTLD_NOW|RTLD_LOCAL))
        ASAXFail(@"DTX unavailable");
    ASDTXReadConnectionState *state=[ASDTXReadConnectionState new];
    if ([mode isEqual:@"ax_unconfirmed"] || [mode isEqual:@"ax_semantic"]) {
        InterruptedChannel *channel=[InterruptedChannel new];
        if ([mode isEqual:@"ax_semantic"]) { channel.code=3; [state markDisconnected]; }
        Call(channel,state,@"processDataFromHost:",@[[NSData data]]);
        ASAXFail(@"AX refusal unexpectedly returned");
    }
    int sockets[2]; if(socketpair(AF_UNIX,SOCK_STREAM,0,sockets)) ASAXFail(@"socketpair failed");
    int owned=sockets[0],peer=sockets[1];
    dispatch_semaphore_t released=dispatch_semaphore_create(0);
    id transport=((id(*)(id,SEL,int,id))objc_msgSend)([NSClassFromString(@"DTXSocketTransport") alloc],
        NSSelectorFromString(@"initWithConnectedSocket:disconnectAction:"),owned,^{[state markDisconnected];close(owned);dispatch_semaphore_signal(released);});
    id connection=((id(*)(id,SEL,id))objc_msgSend)([NSClassFromString(@"DTXConnection") alloc],
        NSSelectorFromString(@"initWithTransport:"),transport);
    ((void(*)(id,SEL))objc_msgSend)(connection,NSSelectorFromString(@"resume"));
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,20*NSEC_PER_MSEC),dispatch_get_global_queue(0,0),^{close(peer);});
    @try { Call(connection,state,@"processDataFromHost:",@[[NSData data]]); ASAXFail(@"AX disconnect unexpectedly returned"); }
    @finally {
        ((void(*)(id,SEL))objc_msgSend)(connection,NSSelectorFromString(@"cancel"));
        if(dispatch_semaphore_wait(released,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC))) ASAXFail(@"DTX cleanup failed");
    }
}
static NSDictionary *AXWorker(NSString *mode, ASObservationCommands *commands) {
    [commands ready];
    while ([commands next]) {
        if ([mode isEqual:@"ax_deadline"]) usleep(600000);
        NSString *marker=[NSProcessInfo.processInfo.arguments[0] stringByAppendingString:@".first"];
        if (![[NSFileManager defaultManager] fileExistsAtPath:marker]) {
            [@"started" writeToFile:marker atomically:YES encoding:NSUTF8StringEncoding error:nil];
            if ([mode isEqual:@"ax_late"]) lateCommands=commands;
            AXCallFailure(mode);
            ASAXFail(@"AX failure unexpectedly returned");
        }
        [commands publish:@{@"deviceID":mode,@"recovered":@YES}];
    }
    return @{@"connectionClosed":@YES,@"tunnelClosed":@YES};
}

// Real worker error envelope and classification, simulated service only. No device/framework connection.
void ASAXFail(NSString *reason) {
    @throw [NSException exceptionWithName:@"AXFailure" reason:reason userInfo:nil];
}
NSDictionary *ASRunAXObservation(NSString *mode, ASObservationCommands *commands) {
    @try {
        if ([mode hasPrefix:@"ax_"]) return AXWorker(mode,commands);
        if ([mode hasPrefix:@"recover"]) {
            BOOL dtx = [mode hasPrefix:@"recover_dtx"];
            if (dtx) dlopen("/System/Library/PrivateFrameworks/DTXConnectionServices.framework/DTXConnectionServices", RTLD_NOW|RTLD_LOCAL);
            [commands ready];
            while ([commands next]) {
                if ([mode isEqual:@"recover_dtx_deadline"]) usleep(600000);
                NSString *marker = [NSProcessInfo.processInfo.arguments[0] stringByAppendingString:@".first"];
                if (![[NSFileManager defaultManager] fileExistsAtPath:marker]) {
                    [@"started" writeToFile:marker atomically:YES encoding:NSUTF8StringEncoding error:nil];
                    if (dtx) {
                        if ([mode isEqual:@"recover_dtx_late"]) lateCommands = commands;
                        ASDTXReadConnectionState *state = [ASDTXReadConnectionState new]; [state markDisconnected];
                        ASDTXReadOnlyRequest([InterruptedChannel new], @"takeScreenshot", 4, state, @"Screenshot");
                        // A broken classifier must fail this fixture, not borrow recover's timeout.
                        ASAXFail(@"DTX interruption unexpectedly returned");
                    }
                    ASNativeConnectionFail(@"Screenshot reply timed out");
                }
                [commands publish:@{@"deviceID":mode, @"recovered":@YES}];
            }
        }
        if ([mode isEqual:@"connection"]) ASNativeConnectionFail(@"AX reply timed out");
        if ([mode isEqual:@"semantic"]) ASNativeSemanticFail(@"AX semantic request refused (error=17)");
        if ([mode isEqual:@"misleading"]) ASAXFail(@"connection timed out");
        if ([mode isEqual:@"no_reason"]) @throw [NSException exceptionWithName:@"Unknown" reason:nil userInfo:nil];
        if ([mode hasPrefix:@"native_"]) {
            NSError *error = [NSError errorWithDomain:@"test" code:1
                userInfo:@{@"somaCode":mode, NSLocalizedDescriptionKey:@"simulated channel failure"}];
            ASNativeChannelFail(error, @"channel failed");
        }
        if ([mode isEqual:@"budget"]) ASAXFail(@"AX response budget exceeded");
        return @{@"connectionClosed":@YES, @"tunnelClosed":@YES};
    } @catch (NSException *error) {
        // Match actual AX/screenshot teardown: retain the failure name while attaching cleanup.
        @throw [NSException exceptionWithName:error.name reason:error.reason
            userInfo:@{@"cleanup":@{@"connectionClosed":@YES, @"tunnelClosed":@YES}}];
    }
}
NSDictionary *ASRunScreenshotObservation(NSString *mode, ASObservationCommands *commands) {
    return ASRunAXObservation(mode, commands);
}
int main(int argc, char **argv) {
    @autoreleasepool {
        NSString *mode = argc == 2 ? @(argv[1]) : nil;
        NSString *generation = @"00000000-0000-0000-0000-000000000001";
        for (int i = 1; i + 1 < argc; i++) {
            if (!strcmp(argv[i], "--device")) mode = @(argv[i + 1]);
            if (!strcmp(argv[i], "--generation")) generation = @(argv[i + 1]);
        }
        if (!mode) return 2;
        NSError *error;
        BOOL ok = ASRunObservationWorker(mode, @"ax", generation, &error);
        if (lateCommands) {
            usleep(100000);
            [lateCommands publish:@{@"deviceID":mode, @"stale":@YES}];
        }
        return ok ? 0 : 1;
    }
}
