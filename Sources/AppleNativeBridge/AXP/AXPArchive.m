#import "AXPInternal.h"
#import <dlfcn.h>

// Validate the property-list graph before system NSSecureCoding allocates its objects.
// The subprocess is also bounded by byte counts and a parent-owned deadline.
typedef CFTypeID (*UIDType)(void);
typedef uint32_t (*UIDValue)(CFTypeRef);
static BOOL Visit(id value, NSArray *objects, NSMutableIndexSet *active, NSMutableIndexSet *seen,
                  NSUInteger depth, NSUInteger *budget, CFTypeID uidType, UIDValue uidValue) {
    if (depth > 512 || !*budget) return NO;
    --*budget;
    if (CFGetTypeID((__bridge CFTypeRef)value) == uidType) {
        NSUInteger index = uidValue((__bridge CFTypeRef)value);
        if (index >= objects.count || [active containsIndex:index]) return NO;
        if ([seen containsIndex:index]) return YES;
        [active addIndex:index];
        BOOL valid = Visit(objects[index], objects, active, seen, depth + 1, budget, uidType, uidValue);
        [active removeIndex:index]; [seen addIndex:index];
        return valid;
    }
    if ([value isKindOfClass:NSDictionary.class]) {
        for (id key in value) {
            if (![key isKindOfClass:NSString.class]
                || !Visit(value[key], objects, active, seen, depth + 1, budget, uidType, uidValue)) return NO;
        }
        return YES;
    }
    if ([value isKindOfClass:NSArray.class]) {
        for (id child in value) if (!Visit(child, objects, active, seen, depth + 1, budget, uidType, uidValue)) return NO;
        return YES;
    }
    return [value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class]
        || [value isKindOfClass:NSData.class] || [value isKindOfClass:NSNull.class];
}
BOOL ASAXArchiveIsBounded(NSData *packet) {
    if (![packet isKindOfClass:NSData.class] || !packet.length || packet.length > 20 * 1024 * 1024) return NO;
    UIDType type = dlsym(RTLD_DEFAULT, "_CFKeyedArchiverUIDGetTypeID");
    UIDValue value = dlsym(RTLD_DEFAULT, "_CFKeyedArchiverUIDGetValue");
    if (!type || !value) return NO;
    id archive = [NSPropertyListSerialization propertyListWithData:packet options:NSPropertyListImmutable format:NULL error:nil];
    if (![archive isKindOfClass:NSDictionary.class] || ![archive[@"$archiver"] isEqual:@"NSKeyedArchiver"]
        || ![archive[@"$objects"] isKindOfClass:NSArray.class] || [archive[@"$objects"] count] > 50000
        || ![archive[@"$top"] isKindOfClass:NSDictionary.class] || !archive[@"$top"][@"root"]) return NO;
    NSUInteger budget = 200000;
    return Visit(archive[@"$top"][@"root"], archive[@"$objects"], [NSMutableIndexSet new], [NSMutableIndexSet new],
                 0, &budget, type(), value);
}
