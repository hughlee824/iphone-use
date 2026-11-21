// Exercise the production AX wait loops with a synthetic DTX peer; no phone/framework connection.
#import "../../Sources/AppleNativeBridge/AXP/AXPReader.m"
#import <assert.h>
void ASAXFail(NSString *reason) { @throw [NSException exceptionWithName:@"TestAXFailure" reason:reason userInfo:nil]; }
@interface DTXMessage : NSObject
- (instancetype)initWithSelector:(SEL)selector objects:(id)objects;
@end
@implementation DTXMessage
- (instancetype)initWithSelector:(SEL)selector objects:(id)objects {
    if ([NSStringFromSelector(selector) isEqual:@"processDataFromHost:"])
        assert([objects count] == 1 && [objects[0] isKindOfClass:NSData.class]);
    else assert([objects count] == 0);
    return [super init];
}
@end
@interface AXPTranslatorRequest : NSObject <NSSecureCoding>
@property id requestType, attributeType, actionType, clientType, translation, parameters;
@end
@implementation AXPTranslatorRequest
+ (BOOL)supportsSecureCoding { return YES; }
- (void)encodeWithCoder:(NSCoder *)coder { [coder encodeObject:self.requestType forKey:@"request"]; }
- (instancetype)initWithCoder:(NSCoder *)coder { return [super init]; }
@end
@interface TestReply : NSObject
- (id)object;
- (unsigned)errorStatus;
@end
@implementation TestReply
- (id)object { return @26; }
- (unsigned)errorStatus { return 0; }
@end
@interface TestConnection : NSObject
@property double delay;
@property unsigned sends;
- (void)sendMessage:(id)message replyHandler:(void (^)(id))handler;
@end
@implementation TestConnection
- (void)sendMessage:(id)message replyHandler:(void (^)(id))handler {
    self.sends++;
    if(self.delay<0)return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(self.delay*NSEC_PER_SEC)),dispatch_get_global_queue(0,0),^{handler([TestReply new]);});
}
@end
int main(int argc,const char **argv) { @autoreleasepool {
    assert(argc==2);NSString *mode=@(argv[1]);TestConnection *peer=[TestConnection new];ASDTXReadConnectionState *state=[ASDTXReadConnectionState new];
    NSTimeInterval began=NSProcessInfo.processInfo.systemUptime;
    if([mode isEqual:@"recovered"]){peer.delay=1.1;assert([Call(peer,state,@"deviceAPIVersion",@[]) isEqual:@26]);}
    else {
        BOOL threw=NO;
        @try {
            if([mode isEqual:@"call-timeout"]){peer.delay=5;Call(peer,state,@"deviceAPIVersion",@[]);}
            else {peer.delay=0;Read(peer,[ASAXReaderTarget new],state,1,@{},nil);}
        } @catch(NSException *exception){threw=YES;}
        assert(threw);
    }
    double elapsed=NSProcessInfo.processInfo.systemUptime-began;
    assert(peer.sends==1); // transport recovery must never replay a semantic invocation
    if([mode isEqual:@"recovered"])assert(elapsed>=1&&elapsed<3);
    else if([mode isEqual:@"call-timeout"])assert(elapsed>=3&&elapsed<5);
    else assert(elapsed>=4&&elapsed<5);
    printf("%s: %.3f seconds, one semantic invocation\n",argv[1],elapsed);
    return 0;
} }
