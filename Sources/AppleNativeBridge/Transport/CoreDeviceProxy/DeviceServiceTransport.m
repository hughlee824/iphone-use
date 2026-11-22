#import "DeviceServiceTransport.h"
#import "CoreDeviceTunnel.h"
#import "../NativeServiceFailure.h"
#import "../NativeTiming.h"

@implementation ASDeviceServiceTransport {
    ASCoreDeviceTunnel *_tunnel;
    ASNativeChannel *_discovery;
    NSDictionary *_services;
}
- (instancetype)initWithUDID:(NSString *)udid { return [self initWithUDID:udid sessionLifetime:NO]; }
- (instancetype)initWithUDID:(NSString *)udid sessionLifetime:(BOOL)sessionLifetime {
    if (!(self = [super init])) return nil;
    @try {
        NSTimeInterval mark = NSProcessInfo.processInfo.systemUptime;
        _tunnel = [[ASCoreDeviceTunnel alloc] initWithUDID:udid sessionLifetime:sessionLifetime];
        mark = ASNativeTimingMark(@"transport.tunnel_open", mark);
        NSDictionary *peer; NSError *error;
        _discovery = [[ASNativeChannel alloc] initWithConnectedFileDescriptor:[_tunnel connectPort:_tunnel.discoveryPort]
            versionFlags:0 handshake:YES peerInfo:&peer error:&error];
        if (!_discovery) ASNativeChannelFail(error, @"RSD discovery failed");
        if (![peer[@"Properties"] isKindOfClass:NSDictionary.class]
            || ![peer[@"Properties"][@"UniqueDeviceID"] isEqual:udid]
            || ![peer[@"Services"] isKindOfClass:NSDictionary.class]) ASDeviceTransportFail(@"RSD device identity mismatch");
        id flags = peer[@"Properties"][@"RemoteXPCVersionFlags"];
        if (![flags isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)flags) == CFBooleanGetTypeID()
            || !isfinite([flags doubleValue]) || [flags doubleValue] < 0
            || [flags doubleValue] != [flags unsignedLongLongValue]) ASDeviceTransportFail(@"RemoteXPC version unavailable");
        _versionFlags = [flags unsignedLongLongValue]; _services = peer[@"Services"];
        ASNativeTimingMark(@"transport.rsd_open_validate", mark);
    } @catch (NSException *exception) {
        [self close]; @throw;
    }
    return self;
}
- (int)openKeyboardService:(BOOL)pasteboard {
    NSString *name = pasteboard ? @"com.apple.coredevice.pasteboardservice" : @"com.apple.coredevice.hid.universalhidservice";
    NSDictionary *entry = _services[name];
    if (![entry isKindOfClass:NSDictionary.class] || ![entry[@"Properties"] isKindOfClass:NSDictionary.class])
        ASDeviceTransportFail(@"Requested keyboard or pasteboard service absent from RSD inventory");
    NSDictionary *properties = entry[@"Properties"];
    if ([entry[@"Entitlement"] isEqual:@"AppleInternal"] || ![properties[@"UsesRemoteXPC"] boolValue]
        || [properties[@"ServiceVersion"] integerValue] != 1)
        ASDeviceTransportFail(@"Device did not advertise an eligible RemoteXPC keyboard or pasteboard service");
    return [self openService:name];
}
- (int)openService:(NSString *)name {
    id service = _services[name];
    if (![service isKindOfClass:NSDictionary.class]) ASDeviceTransportFail(@"Device service not advertised");
    id properties = service[@"Properties"], port = service[@"Port"];
    if (![properties isKindOfClass:NSDictionary.class] || [properties[@"EncryptSocketData"] boolValue])
        ASDeviceTransportFail(@"Encrypted service socket unsupported");
    if (![port isKindOfClass:NSString.class] && ![port isKindOfClass:NSNumber.class]) ASDeviceTransportFail(@"Invalid service port");
    if ([port isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)port) == CFBooleanGetTypeID())
        ASDeviceTransportFail(@"Invalid service port");
    NSString *digits = [port description];
    if (!digits.length || [digits rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789"].invertedSet].location != NSNotFound
        || [digits longLongValue] <= 0 || [digits longLongValue] > UINT16_MAX)
        ASDeviceTransportFail(@"Invalid service port");
    return [_tunnel connectPort:(uint16_t)[digits intValue]];
}
- (BOOL)close { [_discovery cancel]; _discovery = nil; _services = nil; return [_tunnel close]; }
- (void)dealloc { [self close]; }
@end
