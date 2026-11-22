#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// NSNumber canonicalizes small signed/unsigned values. Preserve required XPC uint64 tags explicitly.
@interface ASNativeUnsigned : NSObject
- (instancetype)initWithValue:(uint64_t)value;
@property(nonatomic, readonly) uint64_t value;
@end
// Only C/Objective-C ABI; no private Swift ABI, entitlement or caller-identity shim.
@interface ASNativeChannel : NSObject
- (instancetype)init NS_UNAVAILABLE;
// Consumes an owned descriptor on every path. Require TCP on the granted device IPv6 address.
- (nullable instancetype)initWithConnectedFileDescriptor:(int)fd deviceAddress:(NSString *)address
                                           versionFlags:(uint64_t)flags error:(NSError **)error;
- (void)request:(NSDictionary *)message completion:(void (^)(NSDictionary * _Nullable, NSError * _Nullable))completion;
// A barrier confirms local queue drainage, never device execution.
- (void)send:(NSDictionary *)message completion:(void (^)(NSError * _Nullable))completion;
- (void)cancel;
// Local event snapshot only; makes no request and does not prove peer liveness.
@property(nonatomic, readonly) NSDictionary *diagnostics;
@end

// An assertion granted by the logged-in user's pairing daemon owns this tunnel.
// Opening services is explicit; it never retries a denied RemoteServiceDiscovery lookup.
@interface ASPairedTunnel : NSObject
- (instancetype)init NS_UNAVAILABLE;
- (nullable instancetype)initWithUDID:(NSString *)udid deviceIdentifier:(NSString *)identifier
                   endpointInventory:(nullable NSString *)inventory error:(NSError **)error;
@property(nonatomic, readonly) NSString *deviceAddress;
@property(nonatomic, readonly) NSDictionary *peerInfo;
- (nullable ASNativeChannel *)openService:(NSString *)name error:(NSError **)error;
- (BOOL)close;
@end

// Bounded parser for Apple netstat -anvl output; tested against malformed host fixtures.
FOUNDATION_EXPORT NSArray<NSNumber *> *ASNativeRSDPorts(NSString *inventory, NSString *deviceAddress);

@interface ASMediaNegotiator : NSObject
- (instancetype)init NS_UNAVAILABLE;
- (nullable instancetype)initWithError:(NSError **)error;
@property(nonatomic, readonly) NSData *offer;
- (BOOL)acceptAnswer:(NSData *)answer error:(NSError **)error;
@end

// Exercise the exact value conversion used by the native channel, without a device.
FOUNDATION_EXPORT NSDictionary * _Nullable ASNativeRoundTrip(NSDictionary *value, NSError **error);
// Used only in an isolated, session-owned helper. Streams live device logs;
// callers must discard unrelated messages and never store raw log contents.
FOUNDATION_EXPORT BOOL ASReadDeviceLog(NSString *udid, void (^ready)(void),
                                     void (^line)(NSString *), NSError **error);
// Runs only in the bounded native AX subprocess; never sends input or starts Runner.
FOUNDATION_EXPORT NSDictionary * _Nullable ASReadAXSnapshot(NSString *udid, NSError **error);
FOUNDATION_EXPORT NSDictionary * _Nullable ASAXDisplayGeometry(NSDictionary *info, NSError **error);
// Session-owned USB/RSD keyboard tunnel. The caller owns the received service descriptor.
@interface ASKeyboardMediaEndpoint : NSObject
@property(nonatomic, readonly) ASNativeChannel *channel;
@property(nonatomic, readonly) NSString *localAddress, *deviceAddress;
@property(nonatomic, readonly) uint16_t receiverPort;
- (NSUInteger)receivedFromPort:(uint16_t)port ssrc:(uint32_t)ssrc;
@end
FOUNDATION_EXPORT BOOL ASProvideKeyboardPort(NSString *udid,
    NSString * _Nullable (^startMedia)(ASKeyboardMediaEndpoint *), BOOL (^stopMedia)(void));
FOUNDATION_EXPORT int ASReceiveKeyboardPort(int control, NSError * _Nullable * _Nullable error) __attribute__((swift_error(none)));
NS_ASSUME_NONNULL_END

FOUNDATION_EXPORT BOOL ASRunObservationWorker(NSString * _Nonnull device, NSString * _Nonnull kind, NSString * _Nonnull generation, NSError * _Nullable * _Nullable error);
// Fixed automation preference only; isolated helper owns the write deadline and notification.
FOUNDATION_EXPORT NSDictionary * _Nonnull ASSetAXAutomation(NSString * _Nonnull udid, BOOL enabled);
