#import "DeviceLockdown.h"
#import "NativeServiceFailure.h"
#import "CoreDeviceProxy/CoreDeviceTunnel.h"
#import "NativeTiming.h"
#import <dlfcn.h>

void ASWithLockdownDevice(NSString *udid, void (^operation)(CFTypeRef, void *)) {
    NSTimeInterval mark = NSProcessInfo.processInfo.systemUptime;
    void *library = dlopen("/Library/Apple/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice", RTLD_NOW | RTLD_LOCAL);
    if (!library) ASDeviceTransportFail(@"Device USB runtime unavailable");
    CFArrayRef (*devices)(void) = dlsym(library, "AMDCreateDeviceList");
    CFStringRef (*identifier)(CFTypeRef) = dlsym(library, "AMDeviceCopyDeviceIdentifier");
    int (*interface)(CFTypeRef) = dlsym(library, "AMDeviceGetInterfaceType");
    int (*connect)(CFTypeRef) = dlsym(library, "AMDeviceConnect");
    int (*paired)(CFTypeRef) = dlsym(library, "AMDeviceIsPaired");
    int (*validate)(CFTypeRef) = dlsym(library, "AMDeviceValidatePairing");
    int (*start)(CFTypeRef) = dlsym(library, "AMDeviceStartSession");
    int (*stop)(CFTypeRef) = dlsym(library, "AMDeviceStopSession");
    int (*disconnect)(CFTypeRef) = dlsym(library, "AMDeviceDisconnect");
    if (!devices || !identifier || !interface || !connect || !paired || !validate || !start || !stop || !disconnect)
        ASDeviceTransportFail(@"Device USB runtime unavailable");
    mark = ASNativeTimingMark(@"usb.framework_symbols", mark);
    NSArray *list = CFBridgingRelease(devices());
    id selected = nil;
    for (id device in list) {
        NSString *serial = CFBridgingRelease(identifier((__bridge CFTypeRef)device));
        if ([serial isEqual:udid] && interface((__bridge CFTypeRef)device) == 1) {
            if (selected) ASDeviceTransportFail(@"Ambiguous USB device");
            selected = device;
        }
    }
    if (!selected) ASNativeConnectionFail(@"Selected USB device unavailable");
    mark = ASNativeTimingMark(@"usb.discovery", mark);
    CFTypeRef device = (__bridge CFTypeRef)selected;
    if (connect(device)) ASNativeConnectionFail(@"USB lockdown connection failed");
    mark = ASNativeTimingMark(@"usb.lockdown_connect", mark);
    BOOL session = NO;
    @try {
        if (!paired(device) || validate(device) || start(device)) ASDeviceTransportFail(@"Existing USB pairing unavailable");
        session = YES;
        mark = ASNativeTimingMark(@"usb.validate_start_session", mark);
        operation(device, library);
    } @finally {
        if (session) stop(device);
        disconnect(device);
        ASNativeTimingMark(@"usb.session_cleanup", mark);
    }
}
