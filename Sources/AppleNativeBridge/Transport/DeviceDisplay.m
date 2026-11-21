#import "../AXP/AXPInternal.h"
#import "NativeServiceFailure.h"
NSDictionary *ASReadDisplayInfo(ASNativeChannel *channel) {
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:@"/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/Resources/Info.plist"];
    NSString *version = info[@"CFBundleVersion"];
    NSMutableArray *components = [NSMutableArray new];
    for (NSString *part in [version componentsSeparatedByString:@"."]) {
        if (!part.length || [part rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location != NSNotFound)
            ASAXFail(@"CoreDevice version unavailable");
        [components addObject:[[ASNativeUnsigned alloc] initWithValue:part.longLongValue]];
    }
    if (!components.count) ASAXFail(@"CoreDevice version unavailable");
    NSDictionary *request = @{@"CoreDevice.CoreDeviceDDIProtocolVersion": @2,
        @"CoreDevice.coreDeviceVersion": @{@"components": components, @"originalComponentsCount": @((int64_t)components.count), @"stringValue": version},
        @"CoreDevice.deviceIdentifier": NSUUID.UUID.UUIDString, @"CoreDevice.invocationIdentifier": NSUUID.UUID.UUIDString,
        @"CoreDevice.featureIdentifier": @"com.apple.coredevice.feature.getdisplayinfo", @"CoreDevice.action": @{}, @"CoreDevice.input": @{}};
    NSLock *lock = [NSLock new]; dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSDictionary *response; __block NSError *failure;
    [channel request:request completion:^(NSDictionary *reply, NSError *error) {
        [lock lock]; failure = error; if (!error) response = reply; [lock unlock]; dispatch_semaphore_signal(done);
    }];
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC))) ASNativeConnectionFail(@"AX display query timed out");
    [lock lock]; NSDictionary *output = response[@"CoreDevice.output"]; NSError *error = failure; [lock unlock];
    if (error) ASNativeChannelFail(error, @"Display query failed");
    return output;
}
