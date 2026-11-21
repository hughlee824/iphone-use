#import "../NativeChannelInternal.h"
NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSDictionary *ASReadDisplayInfo(ASNativeChannel *channel);
FOUNDATION_EXPORT void ASAXFail(NSString *reason);
FOUNDATION_EXPORT BOOL ASAXArchiveIsBounded(NSData *packet);
FOUNDATION_EXPORT NSDictionary *ASAXReadTreeLoop(int fd, NSDictionary *(^display)(void), BOOL (^_Nullable next)(void (^check)(void)), void (^_Nullable consume)(NSDictionary *));
FOUNDATION_EXPORT NSDictionary *ASAXReadTree(int fd, NSDictionary *(^display)(void));
FOUNDATION_EXPORT NSDictionary *ASAXDisplayDiagnostic(id _Nullable info, NSError * _Nullable error);
NS_ASSUME_NONNULL_END
