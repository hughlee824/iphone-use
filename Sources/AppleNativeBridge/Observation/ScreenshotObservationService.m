#import "ObservationWorker.h"
#import "../Transport/DTXReadOnlyRequest.h"
#import <objc/message.h>
#import <dlfcn.h>
#import <unistd.h>
static double Now(void) { return NSProcessInfo.processInfo.systemUptime; }
static void Tick(void) { [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.001]]; }
static void Fail(NSString *reason) { @throw [NSException exceptionWithName:@"ProbeFailure" reason:reason userInfo:nil]; }
NSDictionary *ASRunScreenshotObservation(NSString *device, ASObservationCommands *commands) {
    ASDeviceServiceTransport *provider; ASNativeChannel *deviceInfo; id connection;
    int fd = -1; BOOL handed = NO;
    dispatch_semaphore_t disconnected = dispatch_semaphore_create(0);
    ASDTXReadConnectionState *connectionState = [ASDTXReadConnectionState new];
    NSMutableDictionary *cleanup = [NSMutableDictionary new]; NSException *failure;
    @try {
        provider=[[ASDeviceServiceTransport alloc] initWithUDID:device sessionLifetime:YES];
        fd=[provider openService:@"com.apple.instruments.dtservicehub"];
        if(!dlopen("/System/Library/PrivateFrameworks/DTXConnectionServices.framework/DTXConnectionServices",RTLD_NOW|RTLD_LOCAL)) Fail(@"DTX framework unavailable");
        int owned=fd;
        id transport=((id(*)(id,SEL,int,id))objc_msgSend)([NSClassFromString(@"DTXSocketTransport") alloc],NSSelectorFromString(@"initWithConnectedSocket:disconnectAction:"),owned,^{[connectionState markDisconnected]; close(owned); dispatch_semaphore_signal(disconnected);});
        if(!transport) Fail(@"DTX socket unavailable"); handed=YES;
        connection=((id(*)(id,SEL,id))objc_msgSend)([NSClassFromString(@"DTXConnection") alloc],NSSelectorFromString(@"initWithTransport:"),transport);
        if(!connection) Fail(@"DTX connection unavailable");
        ((void(*)(id,SEL))objc_msgSend)(connection,NSSelectorFromString(@"resume"));
        double deadline=Now()+3;
        NSDictionary *capabilities;
        while(Now()<deadline) {
            capabilities=((id(*)(id,SEL))objc_msgSend)(connection,NSSelectorFromString(@"remoteCapabilityVersions"));
            if(capabilities.count) break; Tick();
        }
        id channel=((id(*)(id,SEL,id))objc_msgSend)(connection,NSSelectorFromString(@"makeChannelWithIdentifier:"),@"com.apple.instruments.server.services.screenshot");
        if(!channel) Fail(@"Screenshot channel unavailable");
        // makeChannelWithIdentifier returns a channel already resumed by DTXConnection.
        NSError *channelError;
        deviceInfo=[[ASNativeChannel alloc] initWithConnectedFileDescriptor:[provider openService:@"com.apple.coredevice.deviceinfo"] versionFlags:provider.versionFlags handshake:NO peerInfo:NULL error:&channelError];
        if(!deviceInfo) ASNativeChannelFail(channelError, @"DeviceInfo channel failed");
        [commands ready];
        while ([commands next]) { @autoreleasepool {
            NSTimeInterval began = NSDate.date.timeIntervalSince1970;
            id value = ASDTXReadOnlyRequest(channel, @"takeScreenshot", 4, connectionState, @"Screenshot");
            if (![value isKindOfClass:NSData.class] || [value length] < 8 || [value length] > 32 * 1024 * 1024)
                Fail(@"Invalid screenshot payload");
            NSData *png = value;
            const unsigned char magic[] = {137,80,78,71,13,10,26,10};
            if (memcmp(png.bytes, magic, 8)) Fail(@"Screenshot is not PNG");
            NSDictionary *display = ASReadDisplayInfo(deviceInfo);
            [commands publish:@{@"deviceID":device, @"png":[png base64EncodedStringWithOptions:0],
                @"display":display, @"startedAt":@(began), @"finishedAt":@(NSDate.date.timeIntervalSince1970)}];
        }}
    } @catch (NSException *exception) { failure = exception; }
    @finally {
        [deviceInfo cancel];
        if (connection) ((void(*)(id,SEL))objc_msgSend)(connection,NSSelectorFromString(@"cancel"));
        if (fd >= 0 && !handed) close(fd);
        cleanup[@"connectionClosed"] = @(handed && dispatch_semaphore_wait(disconnected,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC)) == 0);
        cleanup[@"tunnelClosed"] = @([provider close]);
    }
    if (failure) @throw [NSException exceptionWithName:failure.name reason:failure.reason userInfo:@{@"cleanup":cleanup}];
    return cleanup;
}
