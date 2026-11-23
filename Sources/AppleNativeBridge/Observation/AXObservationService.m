#import "ObservationWorker.h"
NSDictionary *ASRunAXObservation(NSString *device, ASObservationCommands *commands) {
    ASDeviceServiceTransport *provider; ASNativeChannel *info;
    NSMutableDictionary *cleanup = [NSMutableDictionary new];
    NSException *failure;
    @try {
        provider = [[ASDeviceServiceTransport alloc] initWithUDID:device sessionLifetime:YES];
        NSError *error;
        info = [[ASNativeChannel alloc] initWithConnectedFileDescriptor:[provider openService:@"com.apple.coredevice.deviceinfo"]
            versionFlags:provider.versionFlags handshake:NO peerInfo:NULL error:&error];
        if (!info) ASNativeChannelFail(error, @"DeviceInfo channel failed");
        __block BOOL first = YES;
        NSDictionary *last = ASAXReadTreeLoop([provider openService:@"com.apple.accessibility.axAuditDaemon.remoteAXService"], ^{
            NSError *displayError; NSDictionary *display = ASAXDisplayGeometry(ASReadDisplayInfo(info), &displayError);
            if (!display) ASAXFail(displayError.localizedDescription); return display;
        }, ^{ return commands.focusPoint; }, ^(void (^check)(void)){
            if (first) { [commands ready]; first = NO; }
            return [commands nextWithHealthCheck:check];
        }, ^(NSDictionary *snapshot) {
            NSMutableDictionary *value = [snapshot mutableCopy]; value[@"version"] = @1; value[@"deviceID"] = device;
            NSData *encoded = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
            if (!encoded || encoded.length > 12 * 1024 * 1024) ASAXFail(@"AX output budget exceeded");
            [commands publish:value];
        });
        [cleanup addEntriesFromDictionary:last[@"cleanup"] ?: @{}];
    } @catch (NSException *exception) { failure = exception; [cleanup addEntriesFromDictionary:exception.userInfo[@"cleanup"] ?: @{}]; }
    @finally {
        [info cancel]; cleanup[@"tunnelClosed"] = @([provider close]);
    }
    if (failure) @throw [NSException exceptionWithName:failure.name reason:failure.reason userInfo:@{@"cleanup":cleanup}];
    return cleanup;
}
