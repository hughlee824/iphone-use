#import "../NativeServiceFailure.h"
#import "DeviceUSBService.h"
#import "CoreDeviceTunnel.h"
#import "../NativeTiming.h"
#import <dlfcn.h>
#import <sys/socket.h>

@implementation ASDeviceUSBService {
    CFTypeRef _channel;
    int (*_receive)(CFTypeRef, void *, unsigned int);
    int (*_send)(CFTypeRef, const void *, unsigned int);
    void (*_invalidate)(CFTypeRef);
}
- (instancetype)initWithUDID:(NSString *)udid {
    if (!(self = [super init])) return nil;
    _socket = -1;
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
    int (*service)(CFTypeRef, CFStringRef, CFDictionaryRef, CFTypeRef *) = dlsym(library, "AMDeviceSecureStartService");
    int (*getSocket)(CFTypeRef) = dlsym(library, "AMDServiceConnectionGetSocket");
    _receive = dlsym(library, "AMDServiceConnectionReceive");
    _send = dlsym(library, "AMDServiceConnectionSend");
    _invalidate = dlsym(library, "AMDServiceConnectionInvalidate");
    if (!library || !devices || !identifier || !interface || !connect || !paired || !validate || !start
        || !stop || !disconnect || !service || !getSocket || !_receive || !_send || !_invalidate)
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
        if (service(device, CFSTR("com.apple.internal.devicecompute.CoreDeviceProxy"), NULL, &_channel) || !_channel)
            ASDeviceTransportFail(@"CoreDeviceProxy unavailable");
        mark = ASNativeTimingMark(@"usb.start_proxy_service", mark);
        _socket = getSocket(_channel);
        if (_socket < 0) ASDeviceTransportFail(@"CoreDeviceProxy descriptor unavailable");
        int yes = 1; setsockopt(_socket, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
    } @finally {
        if (session) stop(device);
        disconnect(device);
        ASNativeTimingMark(@"usb.session_cleanup", mark);
    }
    return self;
}
- (NSData *)receive {
    uint8_t bytes[65536];
    int count = _receive(_channel, bytes, sizeof(bytes));
    if (count <= 0 || (NSUInteger)count > sizeof(bytes)) ASNativeConnectionFail(@"Device USB stream closed");
    return [NSData dataWithBytes:bytes length:count];
}
- (void)send:(NSData *)data {
    NSUInteger offset = 0;
    while (offset < data.length) {
        int count = _send(_channel, (const uint8_t *)data.bytes + offset, (unsigned int)(data.length - offset));
        if (count <= 0 || (NSUInteger)count > data.length - offset) ASNativeConnectionFail(@"Device USB write failed");
        offset += count;
    }
}
- (void)close { if (_channel) { _invalidate(_channel); CFRelease(_channel); _channel = NULL; _socket = -1; } }
- (void)dealloc { [self close]; }
@end
