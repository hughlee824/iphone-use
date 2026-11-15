#import <Foundation/Foundation.h>

// Opt-in completed-stage timings only. No device identifiers, requests, or UI content.
// Nested stages overlap their parent; do not sum records across scopes.
static inline NSTimeInterval ASNativeTimingMark(NSString *stage, NSTimeInterval started) {
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if ([NSProcessInfo.processInfo.environment[@"IPHONE_USE_NATIVE_TIMINGS"] isEqual:@"1"]) {
        NSDictionary *record = @{@"version": @1, @"stage": stage, @"startedUptime": @(started),
                                  @"finishedUptime": @(now), @"elapsedMs": @((now - started) * 1000)};
        NSData *data = [NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:nil];
        if (data.length && data.length <= 2048)
            fprintf(stderr, "NATIVE_STAGE_TIMING %.*s\n", (int)data.length, (const char *)data.bytes);
    }
    // Logging is excluded from the next stage, without changing any operation deadline.
    return NSProcessInfo.processInfo.systemUptime;
}
