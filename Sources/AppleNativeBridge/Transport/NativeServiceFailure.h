#import <Foundation/Foundation.h>

// Only explicit transport failures permit a fresh read-only acquisition.
// Unknown errors, invalid data, resource limits and remote refusals fail closed.
static inline void ASNativeConnectionFail(NSString *reason) {
    @throw [NSException exceptionWithName:@"ObservationConnectionFailure" reason:reason userInfo:nil];
}
static inline void ASNativeSemanticFail(NSString *reason) {
    @throw [NSException exceptionWithName:@"ObservationSemanticFailure" reason:reason userInfo:nil];
}
static inline NSString *ASNativeFailureKind(NSException *exception) {
    if ([exception.name isEqual:@"ObservationConnectionFailure"]) return @"connection";
    if ([exception.name isEqual:@"ObservationSemanticFailure"]) return @"semantic";
    return @"failure";
}
static inline void ASNativeChannelFail(NSError *error, NSString *fallback) {
    NSString *code = error.userInfo[@"somaCode"];
    if ([@[@"native_connection_lost", @"native_connection_closed", @"native_connect_failed",
           @"native_handshake_timeout"] containsObject:code ?: @""])
        ASNativeConnectionFail(error.localizedDescription ?: fallback);
    @throw [NSException exceptionWithName:@"ObservationFailure" reason:error.localizedDescription ?: fallback userInfo:nil];
}
