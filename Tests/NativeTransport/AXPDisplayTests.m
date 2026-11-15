#import "AXPInternal.h"
#import <assert.h>
#import <math.h>

static NSMutableDictionary *Primary(void) {
    return [@{@"primary": @YES, @"displayId": @1, @"type": @{@"integrated": @{}},
        @"bounds": @[@[@0, @0], @[@1170, @2532]], @"pointScale": @3,
        @"currentOrientation": @"rot0", @"nativeOrientation": @"rot0", @"backlightState": @"activeOn"} mutableCopy];
}
static NSDictionary *Validate(NSArray *rows, NSString *field) {
    NSError *error = nil;
    NSDictionary *info = @{@"displays": rows};
    NSDictionary *geometry = ASAXDisplayGeometry(info, &error);
    if (field) {
        assert(!geometry && error);
        assert([error.userInfo[@"field"] isEqual:field]);
        assert([error.localizedDescription containsString:field]);
    } else {
        assert(geometry && !error);
        assert([geometry[@"width"] isEqual:@390] && [geometry[@"height"] isEqual:@844]);
    }
    NSDictionary *diagnostic = ASAXDisplayDiagnostic(info, error);
    assert([diagnostic[@"accepted"] boolValue] == (geometry != nil));
    if (field) assert([diagnostic[@"field"] isEqual:field]);
    assert([NSJSONSerialization isValidJSONObject:diagnostic]);
    return diagnostic;
}
int main(void) { @autoreleasepool {
    Validate(@[Primary()], nil);
    NSMutableDictionary *wireless = [@{@"primary": @NO, @"backlightState": @"off", @"type": @{@"wireless": @{}}} mutableCopy];
    Validate(@[Primary(), wireless], nil);
    NSArray *mutations = @[
        @[@"primary", NSNull.null, @"primary"],
        @[@"backlightState", @"unknown", @"backlightState"],
        @[@"backlightState", @"activeOn", @"backlightState"],
        @[@"backlightState", NSNull.null, @"backlightState"],
        @[@"type", NSNull.null, @"type"],
        @[@"type", @{@"integrated": @{}}, @"type.wireless"]
    ];
    for (NSArray *mutation in mutations) {
        NSMutableDictionary *row = [wireless mutableCopy];
        row[mutation[0]] = mutation[1];
        Validate(@[Primary(), row], [@"displays[1]." stringByAppendingString:mutation[2]]);
    }
    for (NSString *key in @[@"primary", @"backlightState", @"type"]) {
        NSMutableDictionary *row = [wireless mutableCopy]; [row removeObjectForKey:key];
        NSDictionary *diagnostic = Validate(@[Primary(), row], [@"displays[1]." stringByAppendingString:key]);
        assert([diagnostic[@"rows"][1][key][@"kind"] isEqual:@"missing"]);
    }
    NSDictionary *unknown = Validate(@[Primary(), @{@"primary": @NO, @"backlightState": @"unknown"}], @"displays[1].backlightState");
    assert([unknown[@"rows"][1][@"backlightState"][@"value"] isEqual:@"unknown"]);
    NSMutableDictionary *malformedPrimary = Primary(); malformedPrimary[@"type"] = NSNull.null;
    Validate(@[malformedPrimary, wireless], @"displays[0].type");
    Validate(@[Primary(), Primary()], @"displays[1].primary");
    Validate(@[], @"displays.primary");
    Validate(@[NSNull.null], @"displays[0].entry");
    for (NSArray *mutation in @[
        @[@"active", @NO, @"active"], @[@"currentOrientation", @"rot90", @"currentOrientation"],
        @[@"nativeOrientation", @"rot90", @"nativeOrientation"], @[@"backlightState", @"off", @"backlightState"],
        @[@"pointScale", @0, @"pointScale"], @[@"pointScale", @YES, @"pointScale"],
        @[@"displayId", @1.5, @"displayId"], @[@"displayId", @YES, @"displayId"],
        @[@"bounds", @[], @"bounds"], @[@"bounds", @[@[@0], @[@1, @1]], @"bounds[0]"],
        @[@"bounds", @[@[@0, @0], @[@0, @1]], @"bounds[1]"]]) {
        NSMutableDictionary *row = Primary(); row[mutation[0]] = mutation[1];
        Validate(@[row], [@"displays[0]." stringByAppendingString:mutation[2]]);
    }
    NSMutableDictionary *main = Primary();main[@"backlightState"] = @"activeDimmed";Validate(@[main], nil);
    // Large inventories retain the offending row even beyond the bounded prefix.
    NSMutableArray *many = [NSMutableArray arrayWithObject:Primary()];
    for (NSUInteger i = 1; i < 100; i++) [many addObject:wireless];
    many[99] = @{@"primary": @NO, @"backlightState": @"unknown"};
    NSDictionary *large = Validate(many, @"displays[99].backlightState");
    assert([large[@"rows"] count] == 9 && [large[@"omittedRows"] integerValue] == 91);
    assert([large[@"rows"][8][@"index"] integerValue] == 99);
    // Device strings, arbitrary keys and display IDs used as names must not reach diagnostics.
    NSString *secret = [@"private-display-name" stringByPaddingToLength:1000000 withString:@"private" startingAtIndex:0];
    main = Primary(); main[@"name"] = secret; main[@"uniqueId"] = secret; main[@"backlightState"] = secret;
    main[@"type"] = @{secret: secret}; main[@"bounds"] = @[@[secret, @0], @[@1170, @2532]];
    NSDictionary *redacted = Validate(@[main], @"displays[0].backlightState");
    NSData *data = [NSJSONSerialization dataWithJSONObject:redacted options:0 error:nil];
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    assert(data.length < 32768 && ![text containsString:@"private"]);
    assert([text containsString:@"unrecognized"]);
    main = Primary(); main[@"pointScale"] = @(NAN);
    Validate(@[main], @"displays[0].pointScale");
    // A later valid sample must be validated afresh, not inherit a prior failure or identity.
    Validate(@[Primary(), @{@"primary": @NO, @"backlightState": @"unknown"}], @"displays[1].backlightState");
    Validate(@[Primary()], nil);
    puts("AX display validation: rejection fields, unchanged decisions, bounded metadata passed");
} return 0; }
