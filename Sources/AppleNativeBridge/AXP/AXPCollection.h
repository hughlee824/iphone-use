#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT BOOL ASAXToken(id _Nullable value);
FOUNDATION_EXPORT BOOL ASAXSame(id _Nullable left, id _Nullable right);
// Every available selection witness must agree with the application root.
FOUNDATION_EXPORT BOOL ASAXSelectionMatches(id root, id _Nullable hit, id _Nullable frontmost);
// Only attribute 52 (snapshot), or 63 with native 3015/2025, may be read.
typedef id _Nullable (^ASAXCollectionRead)(NSUInteger attribute, NSDictionary *parameters, id token);
FOUNDATION_EXPORT NSDictionary *ASAXCollect(id root, ASAXCollectionRead read);
NS_ASSUME_NONNULL_END
