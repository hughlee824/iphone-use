#import "AXPInternal.h"
#import "AXPCollection.h"
#import "../Transport/DTXReadOnlyRequest.h"
#import "../Transport/NativeServiceFailure.h"
#import "../Transport/NativeTiming.h"
#import <objc/message.h>
#import <dlfcn.h>
#import <unistd.h>

#import "AXPReceiveQueue.h"
static void Tick(void) { [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.002]]; }
static id Call(id connection, ASDTXReadConnectionState *state, NSString *selector, NSArray *objects) {
    return ASDTXReadOnlyRequestWithObjects(connection, selector, objects, 3, state, @"AX DTX");
}
// A notification may precede the matching reply; accumulate every wait/decode segment.
static void Accumulate(NSMutableDictionary *timings, NSString *key, NSTimeInterval since) {
    if (!timings) return;
    double elapsed = (NSProcessInfo.processInfo.systemUptime - since) * 1000;
    timings[key] = @([timings[key] doubleValue] + elapsed);
}
static id ReadAttribute(id connection, ASAXReaderTarget *target, ASDTXReadConnectionState *state, NSUInteger kind, NSDictionary *parameters, id token, NSUInteger attribute, NSMutableDictionary *timings) {
    if ((kind == 2 && attribute != 52 && attribute != 63) || (kind != 2 && attribute)) ASAXFail(@"AX attribute guard");
    if (attribute == 63 && ![parameters isEqual:@{@"parameter": @3015}] && ![parameters isEqual:@{@"parameter": @2025}] && ![parameters isEqual:@{@"parameter": @3002}]) ASAXFail(@"AX read-only attribute guard");
    if (kind != 1 && kind != 2 && kind != 4 && kind != 6) ASAXFail(@"AX read-only request guard");
    NSTimeInterval mark = NSProcessInfo.processInfo.systemUptime;
    id request = [NSClassFromString(@"AXPTranslatorRequest") new];
    [request setValue:@(kind) forKey:@"requestType"];
    [request setValue:@(attribute) forKey:@"attributeType"];
    [request setValue:@0 forKey:@"actionType"]; [request setValue:@0 forKey:@"clientType"];
    if (kind == 6) {
        token = [NSClassFromString(@"AXPTranslationObject") new];
        uint64_t identifier; arc4random_buf(&identifier, sizeof(identifier));
        [token setValue:@(identifier) forKey:@"objectID"];
    }
    [request setValue:token forKey:@"translation"]; [request setValue:parameters forKey:@"parameters"];
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:request requiringSecureCoding:YES error:nil];
    if (!data) ASAXFail(@"AX secure request encoding failed");
    mark = ASNativeTimingMark([NSString stringWithFormat:@"request.%lu.encode", (unsigned long)kind], mark);
    Call(connection, state, @"processDataFromHost:", @[data]);
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 4;
    Accumulate(timings, @"ax.structure_ack", mark);
    mark = ASNativeTimingMark([NSString stringWithFormat:@"request.%lu.ack", (unsigned long)kind], mark);
    NSUInteger notifications = 0;
    while (NSProcessInfo.processInfo.systemUptime < deadline) {
        NSData *packet = [target takePacket];
        if (!packet) { Tick(); continue; }
        Accumulate(timings, @"ax.structure_wait", mark);
        mark = ASNativeTimingMark([NSString stringWithFormat:@"request.%lu.response_wait", (unsigned long)kind], mark);
        if (!ASAXArchiveIsBounded(packet)) ASAXFail(@"AX archive structure invalid");
        NSSet *classes = [NSSet setWithArray:@[NSClassFromString(@"AXPTranslatorResponse"), NSClassFromString(@"AXPTranslationObject"),
            NSDictionary.class, NSArray.class, NSString.class, NSNumber.class, NSData.class, NSValue.class,
            NSNull.class, NSAttributedString.class, NSError.class, NSUUID.class]];
        id reply = [NSKeyedUnarchiver unarchivedObjectOfClasses:classes fromData:packet error:nil];
        if (![reply isKindOfClass:NSClassFromString(@"AXPTranslatorResponse")]) ASAXFail(@"AX secure decoding failed");
        Accumulate(timings, @"ax.structure_unpack", mark);
        mark = ASNativeTimingMark([NSString stringWithFormat:@"request.%lu.decode", (unsigned long)kind], mark);
        if ([[reply valueForKey:@"associatedRequestType"] unsignedIntegerValue] != kind) {
            if (++notifications > 128) ASAXFail(@"AX notification budget exceeded");
            continue;
        }
        NSUInteger semanticError = [[reply valueForKey:@"error"] unsignedIntegerValue];
        // A point with no AX hit can still belong to an accessible foreground app.
        if (kind == 6 && semanticError == 8) return nil;
        if (semanticError) ASNativeSemanticFail([NSString stringWithFormat:@"AX semantic request refused (read=%lu, error=%lu)",
                                    (unsigned long)kind, (unsigned long)semanticError]);
        if (kind == 2 && ([[reply valueForKey:@"attribute"] unsignedIntegerValue] != attribute
            || !ASAXSame([reply valueForKey:@"associatedTranslationObject"], token))) ASAXFail(@"AX snapshot correlation failed");
        ASNativeTimingMark([NSString stringWithFormat:@"request.%lu.validate", (unsigned long)kind], mark);
        return [reply valueForKey:@"resultData"];
    }
    ASNativeConnectionFail([NSString stringWithFormat:@"AX semantic reply timed out (read=%lu, bytes=%lu)", (unsigned long)kind, (unsigned long)[[target budgetMetrics][@"totalReceivedBytes"] unsignedLongLongValue]]); return nil;
}
static id Read(id connection, ASAXReaderTarget *target, ASDTXReadConnectionState *state, NSUInteger kind, NSDictionary *parameters, id token) {
    return ReadAttribute(connection, target, state, kind, parameters, token, kind == 2 ? 52 : 0, nil);
}
// Request 4 selects the current frontmost application on this AX connection.
static id FrontmostApplication(id connection, ASAXReaderTarget *target, ASDTXReadConnectionState *state,
                               NSMutableDictionary *timings, NSString *stage) {
    NSTimeInterval start = NSProcessInfo.processInfo.systemUptime;
    id app = Read(connection, target, state, 4, @{}, nil);
    ASNativeTimingCollect(timings, stage, start);
    if (!ASAXToken(app) || ![[app valueForKey:@"isApplicationElement"] boolValue])
        ASAXFail(@"AX frontmost application unavailable");
    return app;
}

static BOOL HasTextEditor(NSDictionary *record) {
    NSString *type = record[@"attributes"][@"5004"];
    if (type && [@[@"UITextField", @"UITextView", @"UISearchBarTextField"] containsObject:type]) return YES;
    for (NSDictionary *child in record[@"children"]) if (HasTextEditor(child)) return YES;
    return NO;
}

// On the supported iOS AXP version, application attribute 3002 reads the responder element.
// A refused optional read leaves focus unknown. Transport and correlation failures still retire the read.
static NSDictionary *TextResponder(id connection, ASAXReaderTarget *target, ASDTXReadConnectionState *state, id root) {
    @try {
        id responder = ReadAttribute(connection, target, state, 2, @{@"parameter": @3002}, root, 63, nil);
        if (!ASAXToken(responder) || ![[responder valueForKey:@"pid"] isEqual:[root valueForKey:@"pid"]]) return nil;
        id front = Read(connection, target, state, 4, @{}, nil);
        if (!ASAXSame(front, root) || ![[front valueForKey:@"isApplicationElement"] boolValue]) return nil;
        return @{@"pid": [responder valueForKey:@"pid"], @"objectID": [[responder valueForKey:@"objectID"] stringValue]};
    } @catch (NSException *exception) {
        if ([exception.name isEqual:@"ObservationSemanticFailure"]) return nil;
        @throw;
    }
}

NSDictionary *ASAXReadTreeLoop(int fd, NSDictionary *(^display)(void), BOOL (^next)(void (^check)(void)), void (^consume)(NSDictionary *)) {
    NSTimeInterval mark = NSProcessInfo.processInfo.systemUptime;
    id connection; BOOL subscribed = NO;
    dispatch_semaphore_t disconnected = dispatch_semaphore_create(0);
    ASDTXReadConnectionState *state = [ASDTXReadConnectionState new];
    ASAXReaderTarget *target = [ASAXReaderTarget new];
    NSMutableDictionary *result;
    NSException *readFailure; NSDictionary *cleanup;
    @try {
        if (!dlopen("/System/Library/PrivateFrameworks/DTXConnectionServices.framework/DTXConnectionServices", RTLD_NOW | RTLD_LOCAL)
            || !dlopen("/System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework/AccessibilityPlatformTranslation", RTLD_NOW | RTLD_LOCAL))
            ASAXFail(@"System AX frameworks unavailable");
        mark = ASNativeTimingMark(@"ax.frameworks", mark);
        int owned = fd;
        id transport = ((id (*)(id, SEL, int, id))objc_msgSend)([NSClassFromString(@"DTXSocketTransport") alloc],
            NSSelectorFromString(@"initWithConnectedSocket:disconnectAction:"), owned, ^{ [state markDisconnected]; close(owned); dispatch_semaphore_signal(disconnected); });
        if (!transport) ASAXFail(@"AX transport unavailable");
        fd = -1;
        connection = ((id (*)(id, SEL, id))objc_msgSend)([NSClassFromString(@"DTXConnection") alloc], NSSelectorFromString(@"initWithTransport:"), transport);
        if (!connection) ASAXFail(@"AX connection unavailable");
        ((void (*)(id, SEL, id))objc_msgSend)(connection, NSSelectorFromString(@"setDispatchTarget:"), target);
        ((void (*)(id, SEL))objc_msgSend)(connection, NSSelectorFromString(@"resume"));
        mark = ASNativeTimingMark(@"ax.dtx_open", mark);
        if (![Call(connection, state, @"deviceAPIVersion", @[]) isEqual:@26]) ASAXFail(@"AX API version unsupported");
        mark = ASNativeTimingMark(@"ax.api_version", mark);
        subscribed = YES; Call(connection, state, @"clientNeedsAccessibility:", @[@YES]);
        mark = ASNativeTimingMark(@"ax.subscribe", mark);
        BOOL first = YES;
        while (next ? next(^{ [target checkHealth]; }) : first) { @autoreleasepool {
        first = NO; result = nil;
        [target beginObservation];
        mark = NSProcessInfo.processInfo.systemUptime;
        NSMutableDictionary *timings = [NSMutableDictionary new];
        NSTimeInterval observedAt = NSDate.date.timeIntervalSince1970;
        NSDictionary *screen = display();
        mark = ASNativeTimingCollect(timings, @"ax.display_before", mark);
        NSPoint point = NSMakePoint([screen[@"x"] doubleValue] + [screen[@"width"] doubleValue] / 2,
                                   [screen[@"y"] doubleValue] + [screen[@"height"] doubleValue] / 2);
        NSDictionary *hitParameters = @{@"point": [NSValue valueWithPoint:point], @"displayId": @0};
        id hit = Read(connection, target, state, 6, hitParameters, nil);
        id front = hit ? nil : FrontmostApplication(connection, target, state, timings, @"ax.frontmost_before");
        if (hit && !ASAXToken(hit)) ASAXFail(@"AX hit selection unavailable");
        mark = ASNativeTimingCollect(timings, @"ax.hit_before", mark);
        NSNumber *pid = [(hit ?: front) valueForKey:@"pid"];
        id root = Read(connection, target, state, 1, @{@"pid": pid}, nil);
        if (!ASAXSelectionMatches(root, hit, front))
            ASAXFail(@"AX application identity invalid");
        mark = ASNativeTimingCollect(timings, @"ax.root_before", mark);
        NSDictionary *collection = ASAXCollect(root, ^id(NSUInteger attribute, NSDictionary *parameters, id token) {
            BOOL fullTree = attribute == 52 && token == root && [parameters[@"parameter"][@"maxDepth"] integerValue] == 48;
            return ReadAttribute(connection, target, state, 2, parameters, token, attribute, fullTree ? timings : nil);
        });
        mark = ASNativeTimingCollect(timings, @"ax.tree", mark);
        if (!ASAXSame(root, Read(connection, target, state, 1, @{@"pid": pid}, nil))) ASAXFail(@"AX root changed");
        mark = ASNativeTimingCollect(timings, @"ax.root_after", mark);
        id after = Read(connection, target, state, 6, hitParameters, nil);
        id currentFront = (front || !after)
            ? FrontmostApplication(connection, target, state, timings, @"ax.frontmost_after") : nil;
        mark = ASNativeTimingCollect(timings, @"ax.hit_after", mark);
        if (!ASAXSelectionMatches(root, after, currentFront) || ![screen isEqual:display()]) ASAXFail(@"AX selection changed");
        mark = ASNativeTimingCollect(timings, @"ax.display_after", mark);
        result = [collection mutableCopy]; result[@"stageTimingsMs"] = timings;
        if (HasTextEditor(collection[@"tree"])) result[@"textResponder"] = TextResponder(connection, target, state, root);
        [result addEntriesFromDictionary:@{@"display": screen, @"rootStable": @YES, @"selectionStable": @YES}];
        result[@"startedAt"] = @(observedAt); result[@"finishedAt"] = @(NSDate.date.timeIntervalSince1970);
        result[@"receiveBudget"] = [target finishObservation];
        if (consume) consume(result);
        }}

    } @catch (NSException *exception) { readFailure = exception; } @finally {
        mark = NSProcessInfo.processInfo.systemUptime;
        BOOL stopped = NO;
        if (subscribed) {
            @try { Call(connection, state, @"clientNeedsAccessibility:", @[@NO]); stopped = YES; }
            @catch (NSException *exception) { /* Closing this owned stream releases the client. */ }
        }
        mark = ASNativeTimingMark(@"ax.unsubscribe", mark);
        if (connection) ((void (*)(id, SEL))objc_msgSend)(connection, NSSelectorFromString(@"cancel"));
        if (fd >= 0) close(fd);
        BOOL closed = dispatch_semaphore_wait(disconnected, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0;
        ASNativeTimingMark(@"ax.dtx_close", mark);
        cleanup = @{@"subscriptionStopAcknowledged": @(stopped), @"connectionClosed": @(closed)};
        if (next && !result) result = [NSMutableDictionary new];
        if (result) result[@"cleanup"] = cleanup;
    }
    if (readFailure) @throw [NSException exceptionWithName:readFailure.name reason:readFailure.reason userInfo:@{@"cleanup":cleanup}];
    return result;
}

NSDictionary *ASAXReadTree(int fd, NSDictionary *(^display)(void)) { return ASAXReadTreeLoop(fd, display, nil, nil); }
