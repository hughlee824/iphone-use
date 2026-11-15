#import "AXPInternal.h"
#import "../Transport/NativeTiming.h"
#import "../Transport/CoreDeviceProxy/DeviceServiceTransport.h"

static NSDictionary *Display(ASNativeChannel *channel, NSUInteger sample) {
    NSTimeInterval startedAt = NSDate.date.timeIntervalSince1970;
    NSTimeInterval started = NSProcessInfo.processInfo.systemUptime;
    NSDictionary *output = ASReadDisplayInfo(channel);
    NSError *error; NSDictionary *screen = ASAXDisplayGeometry(output, &error);
    if ([NSProcessInfo.processInfo.environment[@"IPHONE_USE_AX_DISPLAY_DIAGNOSTICS"] isEqual:@"1"]) {
        NSMutableDictionary *diagnostic = [ASAXDisplayDiagnostic(output, error) mutableCopy];
        diagnostic[@"sample"] = @(sample);
        diagnostic[@"phase"] = sample == 1 ? @"before-hit" : @"after-snapshot";
        diagnostic[@"startedAt"] = @(startedAt);
        diagnostic[@"elapsedSeconds"] = @(NSProcessInfo.processInfo.systemUptime - started);
        NSData *data = [NSJSONSerialization dataWithJSONObject:diagnostic options:NSJSONWritingSortedKeys error:nil];
        if (data.length && data.length <= 32768) fprintf(stderr, "AX_DISPLAY_DIAGNOSTIC %.*s\n", (int)data.length, (const char *)data.bytes);
    }
    if (!screen) ASAXFail(error.localizedDescription);
    return screen;
}
NSDictionary *ASReadAXSnapshot(NSString *udid, NSError **error) {
    ASDeviceServiceTransport *transport; ASNativeChannel *deviceInfo;
    NSMutableDictionary *result;
    NSTimeInterval began = NSDate.date.timeIntervalSince1970;
    NSTimeInterval total = NSProcessInfo.processInfo.systemUptime, mark = total;
    @try {
        transport = [[ASDeviceServiceTransport alloc] initWithUDID:udid];
        mark = ASNativeTimingMark(@"observation.transport_open", mark);
        NSError *failure;
        deviceInfo = [[ASNativeChannel alloc] initWithConnectedFileDescriptor:[transport openService:@"com.apple.coredevice.deviceinfo"]
            versionFlags:transport.versionFlags handshake:NO peerInfo:NULL error:&failure];
        if (!deviceInfo) ASAXFail(failure.localizedDescription);
        mark = ASNativeTimingMark(@"observation.deviceinfo_open", mark);
        __block NSUInteger sample = 0;
        int axFD = [transport openService:@"com.apple.accessibility.axAuditDaemon.remoteAXService"];
        mark = ASNativeTimingMark(@"observation.ax_service_open", mark);
        result = [ASAXReadTree(axFD, ^{
            return Display(deviceInfo, ++sample);
        }) mutableCopy];
        mark = ASNativeTimingMark(@"observation.ax_open_read_close", mark);
        result[@"version"] = @1; result[@"deviceID"] = udid; result[@"startedAt"] = @(began);
    } @catch (NSException *exception) {
        result = nil;
        if (error) *error = [NSError errorWithDomain:@"iPhone-use.AXP" code:1
            userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: @"Native AX unavailable"}];
    } @finally {
        NSTimeInterval cleanupStarted = NSProcessInfo.processInfo.systemUptime;
        [deviceInfo cancel];
        BOOL closed = [transport close];
        ASNativeTimingMark(@"observation.transport_close", cleanupStarted);
        if (result && closed) {
            NSMutableDictionary *cleanup = [result[@"cleanup"] mutableCopy]; cleanup[@"tunnelClosed"] = @YES;
            result[@"cleanup"] = cleanup; result[@"finishedAt"] = @(NSDate.date.timeIntervalSince1970);
        } else if (result) { result = nil; if (error) *error = [NSError errorWithDomain:@"iPhone-use.AXP" code:2
            userInfo:@{NSLocalizedDescriptionKey: @"AX tunnel cleanup did not finish"}]; }
    }
    ASNativeTimingMark(@"observation.total", total);
    return result;
}
