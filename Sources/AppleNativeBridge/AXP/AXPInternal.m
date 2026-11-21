#import "AXPInternal.h"
void ASAXFail(NSString *reason) {
    @throw [NSException exceptionWithName:@"AXReadFailure" reason:reason ?: @"AX unavailable" userInfo:nil];
}
