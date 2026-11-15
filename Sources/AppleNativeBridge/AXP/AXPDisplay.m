#import "AXPInternal.h"
#import <math.h>

static BOOL Number(id value) { return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID() && isfinite([value doubleValue]); }
static void Reject(NSString *reason, NSString *field, NSString *expected, NSInteger index) {
    NSString *path = index < 0 ? field : [NSString stringWithFormat:@"displays[%ld].%@", (long)index, field];
    @throw [NSException exceptionWithName:@"AXDisplayValidation" reason:[NSString stringWithFormat:@"%@ (%@: expected %@)", reason, path, expected]
        userInfo:@{@"field": path, @"expected": expected, @"displayIndex": @(index)}];
}
NSDictionary *ASAXDisplayGeometry(NSDictionary *info, NSError **error) {
    @try {
        if (![info isKindOfClass:NSDictionary.class]) Reject(@"AX displays unavailable", @"output", @"dictionary", -1);
        if (![info[@"displays"] isKindOfClass:NSArray.class]) Reject(@"AX displays unavailable", @"displays", @"array", -1);
        NSDictionary *primary;
        NSInteger index = -1, primaryIndex = -1;
        NSUInteger dormant = 0;
        for (id display in info[@"displays"]) {
            ++index;
            if (![display isKindOfClass:NSDictionary.class]) Reject(@"AX display shape invalid", @"entry", @"dictionary", index);
            if ([display[@"primary"] isEqual:@YES]) {
                if (primary) Reject(@"AX ambiguous primary display", @"primary", @"one primary display", index);
                primary = display; primaryIndex = index;
            } else {
                if (![display[@"primary"] isEqual:@NO]) Reject(@"AX display topology unsupported", @"primary", @"false for non-primary display", index);
                if (![display[@"backlightState"] isEqual:@"off"]) Reject(@"AX display topology unsupported", @"backlightState", @"off for non-primary display", index);
                if (![display[@"type"] isKindOfClass:NSDictionary.class]) Reject(@"AX display topology unsupported", @"type", @"dictionary", index);
                if (!display[@"type"][@"wireless"]) Reject(@"AX display topology unsupported", @"type.wireless", @"present", index);
                dormant++;
            }
        }
        if (!primary) Reject(@"AX primary display unavailable", @"displays.primary", @"one primary display", -1);
        if ([primary[@"active"] isEqual:@NO]) Reject(@"AX primary display unavailable", @"active", @"not false", primaryIndex);
        if (dormant && ![primary[@"type"] isKindOfClass:NSDictionary.class]) Reject(@"AX primary display unavailable", @"type", @"dictionary with dormant wireless displays", primaryIndex);
        if (dormant && !primary[@"type"][@"integrated"]) Reject(@"AX primary display unavailable", @"type.integrated", @"present with dormant wireless displays", primaryIndex);
        if (![primary[@"currentOrientation"] isEqual:@"rot0"]) Reject(@"AX orientation unsupported", @"currentOrientation", @"rot0", primaryIndex);
        if (![primary[@"nativeOrientation"] isEqual:@"rot0"]) Reject(@"AX orientation unsupported", @"nativeOrientation", @"rot0", primaryIndex);
        if (![@[@"activeOn", @"activeDimmed"] containsObject:primary[@"backlightState"] ?: info[@"backlightState"] ?: NSNull.null])
            Reject(@"AX display not lit", primary[@"backlightState"] ? @"backlightState" : @"output.backlightState", @"activeOn or activeDimmed", primary[@"backlightState"] ? primaryIndex : -1);
        id bounds = primary[@"bounds"], scale = primary[@"pointScale"], identifier = primary[@"displayId"];
        if (![bounds isKindOfClass:NSArray.class] || [bounds count] != 2) Reject(@"AX display identity or scale invalid", @"bounds", @"two pairs", primaryIndex);
        if (!Number(scale) || [scale doubleValue] <= 0) Reject(@"AX display identity or scale invalid", @"pointScale", @"positive finite number", primaryIndex);
        if (!Number(identifier) || [identifier doubleValue] <= 0 || [identifier doubleValue] != [identifier unsignedLongLongValue])
            Reject(@"AX display identity or scale invalid", @"displayId", @"positive integer", primaryIndex);
        NSUInteger pairIndex = 0;
        for (id pair in bounds) {
            if (![pair isKindOfClass:NSArray.class] || [pair count] != 2 || !Number(pair[0]) || !Number(pair[1]))
                Reject(@"AX display bounds invalid", [NSString stringWithFormat:@"bounds[%lu]", (unsigned long)pairIndex], @"two finite numbers", primaryIndex);
            pairIndex++;
        }
        if ([bounds[1][0] doubleValue] <= 0 || [bounds[1][1] doubleValue] <= 0) Reject(@"AX display bounds invalid", @"bounds[1]", @"positive dimensions", primaryIndex);
        return @{@"x": @([bounds[0][0] doubleValue] / [scale doubleValue]), @"y": @([bounds[0][1] doubleValue] / [scale doubleValue]),
            @"width": @([bounds[1][0] doubleValue] / [scale doubleValue]), @"height": @([bounds[1][1] doubleValue] / [scale doubleValue]),
            @"displayID": identifier, @"displayUniqueID": [primary[@"uniqueId"] isKindOfClass:NSString.class] ? primary[@"uniqueId"] : NSNull.null};
    } @catch (NSException *exception) {
        NSMutableDictionary *details = [exception.userInfo mutableCopy] ?: [NSMutableDictionary new];
        details[NSLocalizedDescriptionKey] = exception.reason ?: @"AX display unavailable";
        if (error) *error = [NSError errorWithDomain:@"iPhone-use.AXP" code:1 userInfo:details];
        return nil;
    }
}

// Bounded, allowlisted metadata only: never serialize display names, unique IDs, AX text,
// arbitrary dictionary keys or unexpected strings from the device.
static NSDictionary *Value(id value) {
    if (!value) return @{@"kind": @"missing"};
    if (value == NSNull.null) return @{@"kind": @"null"};
    if ([value isKindOfClass:NSNumber.class]) {
        if (CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return @{@"kind": @"boolean", @"value": value};
        return isfinite([value doubleValue]) ? @{@"kind": @"number", @"value": value} : @{@"kind": @"nonfinite-number"};
    }
    if ([value isKindOfClass:NSString.class]) {
        NSArray *states = @[@"off", @"unknown", @"activeOn", @"activeDimmed", @"rot0", @"rot90", @"rot180", @"rot270"];
        return @{@"kind": @"string", @"value": [states containsObject:value] ? value : @"<unrecognized>", @"length": @([value length])};
    }
    if ([value isKindOfClass:NSDictionary.class]) return @{@"kind": @"dictionary", @"count": @([value count])};
    if ([value isKindOfClass:NSArray.class]) return @{@"kind": @"array", @"count": @([value count])};
    return @{@"kind": @"other"};
}
static NSDictionary *Row(id row, NSUInteger index) {
    NSMutableDictionary *out = [@{@"index": @(index), @"entry": Value(row)} mutableCopy];
    if (![row isKindOfClass:NSDictionary.class]) return out;
    for (NSString *key in @[@"primary", @"active", @"backlightState", @"displayId", @"pointScale", @"currentOrientation", @"nativeOrientation"])
        out[key] = Value(row[key]);
    id type = row[@"type"];
    out[@"type"] = Value(type);
    if ([type isKindOfClass:NSDictionary.class]) {
        out[@"type.wireless"] = Value(type[@"wireless"]);
        out[@"type.integrated"] = Value(type[@"integrated"]);
    }
    id bounds = row[@"bounds"];
    out[@"bounds"] = Value(bounds);
    if ([bounds isKindOfClass:NSArray.class]) {
        NSMutableArray *pairs = [NSMutableArray new];
        for (NSUInteger i = 0; i < MIN([bounds count], 2); i++) {
            id pair = bounds[i];
            NSMutableDictionary *entry = [@{@"pair": Value(pair)} mutableCopy];
            if ([pair isKindOfClass:NSArray.class]) {
                NSMutableArray *values = [NSMutableArray new];
                for (NSUInteger j = 0; j < MIN([pair count], 2); j++) [values addObject:Value(pair[j])];
                entry[@"values"] = values;
            }
            [pairs addObject:entry];
        }
        out[@"boundsPairs"] = pairs;
    }
    return out;
}
NSDictionary *ASAXDisplayDiagnostic(id info, NSError *error) {
    NSMutableDictionary *out = [@{@"schema": @1, @"accepted": @(!error), @"output": Value(info)} mutableCopy];
    if (error) {
        // These are locally generated identifiers, not arbitrary remote error text.
        for (NSString *key in @[@"field", @"expected", @"displayIndex"])
            if (error.userInfo[key]) out[key] = error.userInfo[key];
        if (!out[@"field"]) out[@"field"] = @"validation.exception";
    }
    if ([info isKindOfClass:NSDictionary.class]) {
        out[@"backlightState"] = Value(info[@"backlightState"]);
        id rows = info[@"displays"];
        out[@"displays"] = Value(rows);
        if ([rows isKindOfClass:NSArray.class]) {
            NSMutableArray *items = [NSMutableArray new];
            for (NSUInteger i = 0; i < MIN([rows count], 8); i++) [items addObject:Row(rows[i], i)];
            NSInteger failed = [error.userInfo[@"displayIndex"] integerValue];
            if (failed >= 8 && (NSUInteger)failed < [rows count]) [items addObject:Row(rows[failed], (NSUInteger)failed)];
            out[@"rows"] = items;
            out[@"omittedRows"] = @([rows count] - items.count);
        }
    }
    return out;
}
