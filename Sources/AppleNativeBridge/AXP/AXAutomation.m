#import "../include/AppleNativeBridge.h"
#import "../Transport/DeviceLockdown.h"
#import "../Transport/NativeServiceFailure.h"
#import <dlfcn.h>

NSDictionary *ASSetAXAutomation(NSString *udid, BOOL enabled) {
    NSMutableDictionary *facts = [@{@"writeAttempted":@NO, @"writeAcknowledged":@NO} mutableCopy];
    @try {
        ASWithLockdownDevice(udid, ^(CFTypeRef device, void *library) {
            int (*set)(CFTypeRef, CFStringRef, CFStringRef, CFTypeRef) = dlsym(library, "AMDeviceSetValue");
            if (!set) ASNativeSemanticFail(@"Automation preference API unavailable");
            facts[@"writeAttempted"] = @YES;
            int code = set(device, CFSTR("com.apple.Accessibility"), CFSTR("AutomationEnabled"),
                           enabled ? kCFBooleanTrue : kCFBooleanFalse);
            facts[@"resultCode"] = @(code);
            facts[@"writeAcknowledged"] = @(code == 0);
        });
    } @catch (NSException *exception) {
        facts[@"error"] = exception.reason ?: @"Automation preference write failed";
    }
    return facts;
}
