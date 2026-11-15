#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import "../../Sources/AppleNativeBridge/include/AppleNativeBridge.h"
#import "../../Sources/AppleNativeBridge/Transport/DeviceLockdown.h"

static NSMutableArray *events;
static int connectCode, validateCode, startCode, setCode;
static BOOL paired, ambiguous, usb, present;
static NSString *missing;
static BOOL lastEnabled;
void ASDeviceTransportFail(NSString *reason) { @throw [NSException exceptionWithName:@"Transport" reason:reason userInfo:nil]; }
static CFArrayRef devices(void) {
    NSArray *list = present ? (ambiguous ? @[@"one", @"two"] : @[@"one"]) : @[];
    return CFBridgingRetain(list);
}
static CFStringRef identifier(CFTypeRef device) { return CFBridgingRetain(@"device"); }
static int interface(CFTypeRef device) { return usb ? 1 : 2; }
static int connectDevice(CFTypeRef device) { [events addObject:@"connect"]; return connectCode; }
static int isPaired(CFTypeRef device) { return paired; }
static int validate(CFTypeRef device) { [events addObject:@"validate"]; return validateCode; }
static int start(CFTypeRef device) { [events addObject:@"start"]; return startCode; }
static int stop(CFTypeRef device) { [events addObject:@"stop"]; return 0; }
static int disconnect(CFTypeRef device) { [events addObject:@"disconnect"]; return 0; }
static int set(CFTypeRef device, CFStringRef domain, CFStringRef key, CFTypeRef value) {
    assert(CFEqual(domain, CFSTR("com.apple.Accessibility")));
    assert(CFEqual(key, CFSTR("AutomationEnabled")));
    assert(value == kCFBooleanTrue || value == kCFBooleanFalse);
    lastEnabled = value == kCFBooleanTrue;
    [events addObject:@"set"]; return setCode;
}
void *TestDlopen(const char *path, int flags) { return (void *)1; }
void *TestDlsym(void *handle, const char *symbol) {
    if (missing && [missing isEqual:@(symbol)]) return NULL;
#define MAP(name, function) if (!strcmp(symbol, name)) return (void *)function
    MAP("AMDCreateDeviceList", devices);
    MAP("AMDeviceCopyDeviceIdentifier", identifier);
    MAP("AMDeviceGetInterfaceType", interface);
    MAP("AMDeviceConnect", connectDevice);
    MAP("AMDeviceIsPaired", isPaired);
    MAP("AMDeviceValidatePairing", validate);
    MAP("AMDeviceStartSession", start);
    MAP("AMDeviceStopSession", stop);
    MAP("AMDeviceDisconnect", disconnect);
    MAP("AMDeviceSetValue", set);
#undef MAP
    abort();
}
static void reset(void) {
    events = [NSMutableArray array]; connectCode = validateCode = startCode = setCode = 0;
    paired = usb = present = YES; ambiguous = NO; missing = nil;
}
static void expect(NSArray *expected) { assert([events isEqual:expected]); }
int main(void) { @autoreleasepool {
    for (NSNumber *enabled in @[@YES, @NO]) {
        reset(); NSDictionary *result = ASSetAXAutomation(@"device", enabled.boolValue);
        assert([result[@"writeAttempted"] boolValue] && [result[@"writeAcknowledged"] boolValue]);
        assert(lastEnabled == enabled.boolValue);
        expect(@[@"connect", @"validate", @"start", @"set", @"stop", @"disconnect"]);
    }
    reset(); setCode = 17;
    NSDictionary *result = ASSetAXAutomation(@"device", YES);
    assert([result[@"writeAttempted"] boolValue] && ![result[@"writeAcknowledged"] boolValue]);
    assert([result[@"resultCode"] intValue] == 17);
    expect(@[@"connect", @"validate", @"start", @"set", @"stop", @"disconnect"]);
    reset(); missing = @"AMDeviceSetValue";
    result = ASSetAXAutomation(@"device", YES);
    assert(![result[@"writeAttempted"] boolValue]);
    expect(@[@"connect", @"validate", @"start", @"stop", @"disconnect"]);
    reset(); paired = NO; ASSetAXAutomation(@"device", YES); expect(@[@"connect", @"disconnect"]);
    reset(); connectCode = 1; ASSetAXAutomation(@"device", YES); expect(@[@"connect"]);
    reset(); validateCode = 1; ASSetAXAutomation(@"device", YES); expect(@[@"connect", @"validate", @"disconnect"]);
    reset(); startCode = 1; ASSetAXAutomation(@"device", YES); expect(@[@"connect", @"validate", @"start", @"disconnect"]);
    reset(); ambiguous = YES; ASSetAXAutomation(@"device", YES); expect(@[]);
    reset(); usb = NO; ASSetAXAutomation(@"device", YES); expect(@[]);
    reset(); present = NO; ASSetAXAutomation(@"device", YES); expect(@[]);
    reset(); missing = @"AMDeviceStopSession"; ASSetAXAutomation(@"device", YES); expect(@[]);
    reset();
    @try { ASWithLockdownDevice(@"device", ^(CFTypeRef device, void *library) {
        @throw [NSException exceptionWithName:@"InjectedServiceFailure" reason:nil userInfo:nil];
    }); abort(); } @catch (NSException *exception) { assert([exception.name isEqual:@"InjectedServiceFailure"]); }
    expect(@[@"connect", @"validate", @"start", @"stop", @"disconnect"]);
    puts("AX automation lockdown runtime: passed");
} return 0; }
