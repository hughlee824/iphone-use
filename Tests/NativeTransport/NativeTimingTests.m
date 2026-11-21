#import "NativeTiming.h"
int main(void) { @autoreleasepool {
    NSTimeInterval started = NSProcessInfo.processInfo.systemUptime - 0.025;
    NSTimeInterval next = ASNativeTimingMark(@"test.completed", started);
    if (next < started || next > NSProcessInfo.processInfo.systemUptime) return 1;
    return 0;
}}
