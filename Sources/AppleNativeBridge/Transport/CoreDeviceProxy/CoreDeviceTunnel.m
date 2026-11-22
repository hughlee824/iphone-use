#import "../NativeServiceFailure.h"
#import "CoreDeviceTunnel.h"
#import "DeviceUSBService.h"
#import "../NativeTiming.h"
#include "DeviceIP.h"
#import <sys/socket.h>
#import <poll.h>
#import <unistd.h>

void ASDeviceTransportFail(NSString *reason) {
    @throw [NSException exceptionWithName:@"DeviceTransportFailure" reason:reason ?: @"Device stream unavailable" userInfo:nil];
}
static uint16_t Read16(const uint8_t *p) { return ((uint16_t)p[0] << 8) | p[1]; }

@implementation ASCoreDeviceTunnel {
    ASDeviceUSBService *_usb;
    NSData *_localAddress, *_remoteAddress;
    NSMutableArray<NSDictionary *> *_pending;
    DeviceIP *_stack;
    uint16_t _rtpSource, _receiverPort;
    uint32_t _rtpSSRC;
    NSUInteger _rtpCount;
    NSUInteger _streamCount;
    NSMutableData *_input;
    dispatch_group_t _worker;
    BOOL _closed, _failed, _sessionLifetime;
}
- (instancetype)initWithUDID:(NSString *)udid { return [self initWithUDID:udid sessionLifetime:NO]; }
- (instancetype)initWithUDID:(NSString *)udid sessionLifetime:(BOOL)sessionLifetime {
    if (!(self = [super init])) return nil;
    _sessionLifetime = sessionLifetime;
    _pending = [NSMutableArray new]; _input = [NSMutableData new];
    NSTimeInterval mark = NSProcessInfo.processInfo.systemUptime;
    _usb = [[ASDeviceUSBService alloc] initWithUDID:udid];
    mark = ASNativeTimingMark(@"tunnel.usb_service", mark);
    NSData *json = [NSJSONSerialization dataWithJSONObject:@{@"type": @"clientHandshakeRequest", @"mtu": @1280} options:0 error:nil];
    NSMutableData *request = [NSMutableData dataWithBytes:"CDTunnel" length:8];
    uint16_t length = htons(json.length); [request appendBytes:&length length:2]; [request appendData:json];
    [_usb send:request];
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 4;
    NSUInteger expected = 10;
    while (_input.length < expected) {
        if (NSProcessInfo.processInfo.systemUptime > deadline) ASNativeConnectionFail(@"Device USB handshake timed out");
        struct pollfd fd = {_usb.socket, POLLIN, 0};
        if (poll(&fd, 1, 50) < 0 && errno != EINTR) ASNativeConnectionFail(@"Device USB poll failed");
        if (fd.revents) [_input appendData:[_usb receive]];
        if (_input.length >= 10) {
            if (memcmp(_input.bytes, "CDTunnel", 8)) ASDeviceTransportFail(@"Device USB handshake framing invalid");
            expected = 10 + Read16((const uint8_t *)_input.bytes + 8);
        }
    }
    NSDictionary *reply = [NSJSONSerialization JSONObjectWithData:[_input subdataWithRange:NSMakeRange(10, expected - 10)] options:0 error:nil];
    if (![reply isKindOfClass:NSDictionary.class] || ![reply[@"type"] isEqual:@"serverHandshakeResponse"])
        ASDeviceTransportFail(@"Device USB handshake invalid");
    NSDictionary *client = reply[@"clientParameters"];
    struct in6_addr local, remote;
    if (![client isKindOfClass:NSDictionary.class] || ![client[@"address"] isKindOfClass:NSString.class]
        || ![reply[@"serverAddress"] isKindOfClass:NSString.class]
        || inet_pton(AF_INET6, [client[@"address"] UTF8String], &local) != 1
        || inet_pton(AF_INET6, [reply[@"serverAddress"] UTF8String], &remote) != 1
        || ![reply[@"serverRSDPort"] isKindOfClass:NSNumber.class]
        || CFGetTypeID((__bridge CFTypeRef)reply[@"serverRSDPort"]) == CFBooleanGetTypeID()
        || [reply[@"serverRSDPort"] doubleValue] != [reply[@"serverRSDPort"] integerValue]
        || [reply[@"serverRSDPort"] integerValue] <= 0 || [reply[@"serverRSDPort"] integerValue] > 65535
        || ![client[@"mtu"] isKindOfClass:NSNumber.class] || [client[@"mtu"] integerValue] < 1280) ASDeviceTransportFail(@"Device USB endpoint invalid");
    _localAddress = [NSData dataWithBytes:&local length:16]; _remoteAddress = [NSData dataWithBytes:&remote length:16];
    _localIP = [client[@"address"] copy]; _deviceIP = [reply[@"serverAddress"] copy];
    _discoveryPort = [reply[@"serverRSDPort"] unsignedShortValue];
    [_input replaceBytesInRange:NSMakeRange(0, expected) withBytes:NULL length:0];
    ASNativeTimingMark(@"tunnel.handshake", mark);
    _worker = dispatch_group_create();
    dispatch_group_async(_worker, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ [self pump]; });
    return self;
}
- (int)connectPort:(uint16_t)port {
    @synchronized(self) {
        if (_closed || _failed || !port || _streamCount >= 4) ASDeviceTransportFail(@"Device tunnel unavailable or stream budget exceeded");
        int sockets[2];
        if (socketpair(AF_UNIX, SOCK_STREAM, 0, sockets)) ASNativeConnectionFail(@"Device local socket failed");
        [_pending addObject:@{@"fd": @(sockets[1]), @"port": @(port)}];
        _streamCount++;
        return sockets[0];
    }
}
- (BOOL)output:(NSData *)packet {
    @try { [_usb send:packet]; return YES; } @catch (NSException *exception) { return NO; }
}
static bool Output(void *context, const void *bytes, size_t count) {
    return [(__bridge ASCoreDeviceTunnel *)context output:[NSData dataWithBytes:bytes length:count]];
}
- (uint16_t)openMediaReceiver {
    @synchronized(self) {
        if (_closed || _failed || !_sessionLifetime || _receiverPort) ASDeviceTransportFail(@"Media endpoint unavailable");
        _receiverPort = 49152 + arc4random_uniform(16384);
        return _receiverPort;
    }
}
- (void)receiveVideo:(const uint8_t *)bytes length:(size_t)count port:(uint16_t)port {
    if (count < 12 || bytes[0] >> 6 != 2 || (bytes[1] >= 192 && bytes[1] <= 223)) return;
    uint32_t ssrc; memcpy(&ssrc, bytes + 8, sizeof(ssrc)); ssrc = ntohl(ssrc);
    @synchronized(self) {
        if (_rtpSource != port || _rtpSSRC != ssrc) _rtpCount = 0;
        _rtpSource = port; _rtpSSRC = ssrc; _rtpCount++;
    }
}
- (NSUInteger)receivedFromPort:(uint16_t)port ssrc:(uint32_t)ssrc {
    @synchronized(self) { return !_closed && !_failed && port == _rtpSource && ssrc == _rtpSSRC ? _rtpCount : 0; }
}
static void Datagram(void *context, uint16_t port, const uint8_t *bytes, size_t count) {
    [(__bridge ASCoreDeviceTunnel *)context receiveVideo:bytes length:count port:port];
}
- (void)pump {
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + (_sessionLifetime ? INFINITY : 22);
    @try {
        _stack = device_ip_create(_localAddress.bytes, _remoteAddress.bytes, Output, (__bridge void *)self);
        if (!_stack) ASDeviceTransportFail(@"Native network stack initialization failed");
        if (_sessionLifetime) device_ip_use_session_lifetime(_stack);
        BOOL receivingUDP = NO;
        while (NSProcessInfo.processInfo.systemUptime < deadline) {
            @autoreleasepool {
                @synchronized(self) {
                    if (_closed) break;
                    if (_receiverPort && !receivingUDP) {
                        device_ip_receive_udp(_stack, _receiverPort, Datagram);
                        receivingUDP = YES;
                    }
                }
                while (YES) {
                    NSDictionary *stream;
                    @synchronized(self) {
                        if (_closed || !_pending.count) break;
                        stream = _pending.firstObject; [_pending removeObjectAtIndex:0];
                    }
                    // Consume one fd outside the lock: opening can emit USB data and block.
                    // Failure leaves the rest of the queue owned for the finally cleanup.
                    if (!device_ip_open(_stack, [stream[@"fd"] intValue], [stream[@"port"] unsignedShortValue]))
                        ASDeviceTransportFail(@"Native network stream open failed");
                }
                if (!device_ip_tick(_stack)) ASDeviceTransportFail(@"Native network stream failed");
                struct pollfd fd = {_usb.socket, POLLIN, 0};
                if (poll(&fd, 1, 2) < 0 && errno != EINTR) ASDeviceTransportFail(@"USB poll failed");
                if (fd.revents) [_input appendData:[_usb receive]];
                if (_input.length > 256 * 1024) ASDeviceTransportFail(@"USB receive budget exceeded");
                while (_input.length >= 40) {
                    const uint8_t *p = _input.bytes;
                    if ((p[0] >> 4) != 6) ASDeviceTransportFail(@"USB packet framing invalid");
                    NSUInteger length = 40 + Read16(p + 4);
                    if (_input.length < length) break;
                    NSData *packet = [_input subdataWithRange:NSMakeRange(0, length)];
                    [_input replaceBytesInRange:NSMakeRange(0, length) withBytes:NULL length:0];
                    if (!device_ip_input(_stack, packet.bytes, packet.length)) ASDeviceTransportFail(@"Native packet input failed");
                }
            }
        }
    } @catch (NSException *exception) {
        @synchronized(self) { _failed = YES; }
    } @finally {
        @synchronized(self) {
            _closed = YES;
            for (NSDictionary *stream in _pending) close([stream[@"fd"] intValue]);
            [_pending removeAllObjects];
        }
        device_ip_destroy(_stack); _stack = NULL;
        [_usb close];
    }
}
- (BOOL)close {
    @synchronized(self) { _closed = YES; }
    if (!_worker) { [_usb close]; return YES; }
    return dispatch_group_wait(_worker, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0;
}
- (void)dealloc { [_usb close]; }
@end
