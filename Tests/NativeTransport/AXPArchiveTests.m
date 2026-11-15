#import "AXPInternal.h"
#import <dlfcn.h>
#import <assert.h>

static NSData *Plist(id value) {
    return [NSPropertyListSerialization dataWithPropertyList:value format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
}
int main(void) {
    @autoreleasepool {
        NSData *valid = [NSKeyedArchiver archivedDataWithRootObject:@{@"label": @"fixture", @"children": @[@1, @2]}
                                            requiringSecureCoding:YES error:nil];
        assert(ASAXArchiveIsBounded(valid));
        assert(!ASAXArchiveIsBounded(NSData.data));
        assert(!ASAXArchiveIsBounded([NSMutableData dataWithLength:20 * 1024 * 1024 + 1]));
        assert(!ASAXArchiveIsBounded(Plist(@{@"not": @"an archive"})));
        CFTypeRef (*uid)(CFAllocatorRef, uint32_t) = dlsym(RTLD_DEFAULT, "_CFKeyedArchiverUIDCreate"); assert(uid);
        id zero = CFBridgingRelease(uid(kCFAllocatorDefault, 0)), one = CFBridgingRelease(uid(kCFAllocatorDefault, 1));
        NSMutableDictionary *archive = [@{@"$archiver": @"NSKeyedArchiver", @"$top": @{@"root": zero},
                                          @"$objects": @[@{@"next": one}]} mutableCopy];
        assert(!ASAXArchiveIsBounded(Plist(archive))); // out-of-range UID
        archive[@"$objects"] = @[@{@"next": one}, @{@"next": zero}];
        assert(!ASAXArchiveIsBounded(Plist(archive))); // cycle before unarchiving
        NSMutableArray *chain = [NSMutableArray new];
        for (uint32_t i = 0; i < 600; i++) [chain addObject:@{@"next": CFBridgingRelease(uid(kCFAllocatorDefault, i + 1))}];
        [chain addObject:@"end"]; archive[@"$objects"] = chain;
        assert(!ASAXArchiveIsBounded(Plist(archive))); // deep reference graph
        archive[@"$objects"] = @[@{@"left": one, @"right": one}, @"shared"];
        assert(ASAXArchiveIsBounded(Plist(archive))); // repeated references are not cycles
        while (chain.count <= 50000) [chain addObject:@"entry"];
        archive[@"$objects"] = chain;
        assert(!ASAXArchiveIsBounded(Plist(archive)));
        puts("AX archive budgets passed");
    }
}
