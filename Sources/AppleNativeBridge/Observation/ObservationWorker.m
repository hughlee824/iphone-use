#import "ObservationWorker.h"
#import <poll.h>
#import <unistd.h>
@implementation ASObservationCommands {
    NSString *_generation, *_request;
    NSTimeInterval _lastActivity;
    NSNumber *_screenshotStartDeadline;
}
- (instancetype)initWithGeneration:(NSString *)generation {
    if ((self = [super init])) { _generation = [generation copy]; _lastActivity = NSProcessInfo.processInfo.systemUptime; }
    return self;
}
- (void)write:(NSDictionary *)value {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    if (!data || data.length > 48 * 1024 * 1024) ASAXFail(@"Observation response budget exceeded");
    if (fwrite(data.bytes, 1, data.length, stdout) != data.length || fputc('\n', stdout) == EOF || fflush(stdout))
        ASAXFail(@"Observation parent disconnected");
}
- (BOOL)canStartScreenshotAt:(NSTimeInterval)uptime {
    return !_screenshotStartDeadline || uptime < _screenshotStartDeadline.doubleValue;
}
- (void)ready { [self write:@{@"event":@"ready", @"generation":_generation}]; }
- (BOOL)next { return [self nextWithHealthCheck:^{}]; }
- (BOOL)nextWithHealthCheck:(void (^)(void))check {
    while (NSProcessInfo.processInfo.systemUptime - _lastActivity < 1800) { @autoreleasepool {
        check();
        struct pollfd fd = {STDIN_FILENO, POLLIN, 0};
        int count = poll(&fd, 1, 20);
        if (count < 0 && errno != EINTR) ASAXFail(@"Observation command poll failed");
        if (count > 0) {
            char line[4096];
            if (!fgets(line, sizeof(line), stdin)) return NO;
            size_t length = strlen(line);
            if (!length || line[length - 1] != '\n') ASAXFail(@"Observation command too large");
            id command = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:line length:length] options:0 error:nil];
            if (![command isKindOfClass:NSDictionary.class] || ![command[@"generation"] isEqual:_generation])
                ASAXFail(@"Observation command generation invalid");
            if ([command[@"op"] isEqual:@"close"]) return NO;
            if (![command[@"op"] isEqual:@"capture"] || ![command[@"id"] isKindOfClass:NSString.class]
                || ![[NSUUID alloc] initWithUUIDString:command[@"id"]]) ASAXFail(@"Observation command invalid");
            NSNumber *cutoff = command[@"screenshotStartDeadline"];
            if (cutoff && (![cutoff isKindOfClass:NSNumber.class] || !isfinite(cutoff.doubleValue) || cutoff.doubleValue <= 0))
                ASAXFail(@"Invalid screenshot start deadline");
            NSDictionary *point = command[@"focusPoint"];
            _focusPoint = nil;
            if (point) {
                if (![point isKindOfClass:NSDictionary.class]) ASAXFail(@"Invalid focus point");
                NSNumber *x = point[@"x"], *y = point[@"y"];
                if (![x isKindOfClass:NSNumber.class] || ![y isKindOfClass:NSNumber.class]
                    || !isfinite(x.doubleValue) || !isfinite(y.doubleValue)) ASAXFail(@"Invalid focus point");
                _focusPoint = [NSValue valueWithPoint:NSMakePoint(x.doubleValue, y.doubleValue)];
            }
            _screenshotStartDeadline = cutoff;
            _request = command[@"id"]; return YES;
        }
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.002]];
    }}
    return NO;
}
- (void)publish:(NSDictionary *)value {
    [self write:@{@"event":@"result", @"generation":_generation, @"id":_request, @"value":value}];
    _lastActivity = NSProcessInfo.processInfo.systemUptime;
}
- (void)closed:(NSDictionary *)facts error:(NSString *)error {
    [self closed:facts error:error kind:@"failure"];
}
- (void)closed:(NSDictionary *)facts error:(NSString *)error kind:(NSString *)kind {
    [self write:@{@"event":@"closed", @"generation":_generation, @"cleanup":facts ?: @{},
        @"error":error ?: (id)NSNull.null, @"errorKind":error ? kind : (id)NSNull.null}];
}
@end
BOOL ASRunObservationWorker(NSString *device, NSString *kind, NSString *generation, NSError **error) {
    ASObservationCommands *commands = [[ASObservationCommands alloc] initWithGeneration:generation];
    @try {
        NSDictionary *facts;
        if ([kind isEqual:@"ax"]) facts = ASRunAXObservation(device, commands);
        else if ([kind isEqual:@"screenshot"]) facts = ASRunScreenshotObservation(device, commands);
        else ASAXFail(@"Unknown observation service");
        [commands closed:facts error:nil]; return YES;
    } @catch (NSException *exception) {
        @try { [commands closed:exception.userInfo[@"cleanup"] error:exception.reason ?: @"Observation worker failed"
            kind:ASNativeFailureKind(exception)]; } @catch (NSException *ignored) {}
        if (error) *error = [NSError errorWithDomain:@"iPhone-use.Observation" code:1 userInfo:@{NSLocalizedDescriptionKey:exception.reason ?: @"Observation worker failed"}];
        return NO;
    }
}
