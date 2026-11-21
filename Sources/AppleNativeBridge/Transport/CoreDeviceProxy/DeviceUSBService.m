#import "../NativeServiceFailure.h"
#import "../DeviceLockdown.h"
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
    ASWithLockdownDevice(udid, ^(CFTypeRef device, void *library) {
        int (*service)(CFTypeRef, CFStringRef, CFDictionaryRef, CFTypeRef *) = dlsym(library, "AMDeviceSecureStartService");
        int (*getSocket)(CFTypeRef) = dlsym(library, "AMDServiceConnectionGetSocket");
        self->_receive = dlsym(library, "AMDServiceConnectionReceive");
        self->_send = dlsym(library, "AMDServiceConnectionSend");
        self->_invalidate = dlsym(library, "AMDServiceConnectionInvalidate");
        if (!service || !getSocket || !self->_receive || !self->_send || !self->_invalidate)
            ASDeviceTransportFail(@"Device USB runtime unavailable");
        NSTimeInterval mark = NSProcessInfo.processInfo.systemUptime;
        if (service(device, CFSTR("com.apple.internal.devicecompute.CoreDeviceProxy"), NULL, &self->_channel) || !self->_channel)
            ASDeviceTransportFail(@"CoreDeviceProxy unavailable");
        ASNativeTimingMark(@"usb.start_proxy_service", mark);
        self->_socket = getSocket(self->_channel);
        if (self->_socket < 0) ASDeviceTransportFail(@"CoreDeviceProxy descriptor unavailable");
        int yes = 1; setsockopt(self->_socket, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
    });
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
