#import "AXPCollection.h"
#import "AXPInternal.h"
#import "../Transport/NativeTiming.h"

BOOL ASAXToken(id value) {
    return [value isKindOfClass:NSClassFromString(@"AXPTranslationObject")]
        && [[value valueForKey:@"pid"] intValue] > 0;
}
BOOL ASAXSame(id left, id right) {
    return ASAXToken(left) && ASAXToken(right) && [[left valueForKey:@"pid"] isEqual:[right valueForKey:@"pid"]]
        && [[left valueForKey:@"objectID"] isEqual:[right valueForKey:@"objectID"]];
}
static NSDictionary *ExportAttributes(NSDictionary *native) {
    if (![native isKindOfClass:NSDictionary.class]) ASAXFail(@"AX attribute dictionary invalid");
    NSMutableDictionary *attributes = [NSMutableDictionary new];
    for (NSNumber *key in @[@2001, @2002, @2003, @2004, @5019, @2006, @2025, @5003, @5004, @3003]) {
        id value = native[key];
        if (!value) continue;
        if ([key isEqual:@2025] && CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID())
            ASAXFail(@"AX visibility type invalid");
        if ([key isEqual:@2003] && [value isKindOfClass:NSValue.class] && ![value isKindOfClass:NSNumber.class]) {
            const char *type = [value objCType];
            if (strcmp(type, @encode(NSRect))) ASAXFail(@"AX geometry type invalid");
            NSRect r = [value rectValue];
            value = isfinite(r.origin.x) && isfinite(r.origin.y) && isfinite(r.size.width) && isfinite(r.size.height)
                ? @{@"x": @(r.origin.x), @"y": @(r.origin.y), @"width": @(r.size.width), @"height": @(r.size.height)} : NSNull.null;
        } else if ([value isKindOfClass:NSAttributedString.class]) value = [value string];
        else if (![value isKindOfClass:NSString.class] && ![value isKindOfClass:NSNumber.class] && value != NSNull.null)
            ASAXFail(@"AX attribute type unsupported");
        attributes[key.stringValue] = value;
    }
    return attributes;
}
static NSDictionary *Export(id record, id root, NSUInteger depth, NSUInteger *count, NSHashTable *active) {
    if (++*count > 4096 || depth > 64 || ![record isKindOfClass:NSDictionary.class] || [active containsObject:record])
        ASAXFail(@"AX tree cycle or budget exceeded");
    [active addObject:record];
    id token = record[@"UIAccessibilitySnapshotKeyElement"], native = record[@"UIAccessibilitySnapshotKeyAttributes"];
    id children = record[@"UIAccessibilitySnapshotKeyChildren"], number = record[@"UIAccessibilitySnapshotKeyChildrenCount"];
    if (!ASAXToken(token) || ![native isKindOfClass:NSDictionary.class] || ![children isKindOfClass:NSArray.class]
        || ![number isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)number) == CFBooleanGetTypeID()
        || [number doubleValue] != [children count])
        ASAXFail(@"AX incomplete tree");
    if (![[token valueForKey:@"pid"] isEqual:[root valueForKey:@"pid"]]
        && (![native[@5003] isEqual:@"AXRemoteElement"] || [children count])) ASAXFail(@"AX foreign subtree");
    NSDictionary *attributes=ExportAttributes(native);
    NSMutableArray *exported = [NSMutableArray new];
    for (id child in children) [exported addObject:Export(child, root, depth + 1, count, active)];
    [active removeObject:record];
    return @{@"element": @{@"pid": [token valueForKey:@"pid"], @"objectID": [[token valueForKey:@"objectID"] stringValue],
        @"application": [token valueForKey:@"isApplicationElement"]}, @"attributes": attributes,
        @"childCount": number, @"children": exported};
}
static NSString *ExportIdentity(NSDictionary *element) {
    return [NSString stringWithFormat:@"%@/%@",element[@"pid"],element[@"objectID"]];
}
static void CollectIdentities(NSDictionary *tree, NSMutableSet *identities) {
    [identities addObject:ExportIdentity(tree[@"element"])];
    for (NSDictionary *child in tree[@"children"]) CollectIdentities(child,identities);
}
static NSDictionary *MergeVisibility(NSDictionary *tree, NSDictionary *visibility, NSUInteger *matched) {
    NSMutableDictionary *copy=[tree mutableCopy];
    NSNumber *value=visibility[ExportIdentity(tree[@"element"])];
    if (value) {
        NSMutableDictionary *fields=[tree[@"attributes"] mutableCopy];
        fields[@"2025"]=value;copy[@"attributes"]=fields;(*matched)++;
    }
    NSMutableArray *children=[NSMutableArray new];
    for (NSDictionary *child in tree[@"children"]) [children addObject:MergeVisibility(child,visibility,matched)];
    copy[@"children"]=children;
    return copy;
}
// Keyboard identity is taken only from this observation's validated full structure.
static void FindKeyboardRecords(NSDictionary *record, NSMutableArray *records) {
    if ([record[@"UIAccessibilitySnapshotKeyAttributes"][@5003] isEqual:@"UIKeyboardLayoutStar"])
        [records addObject:record];
    for (NSDictionary *child in record[@"UIAccessibilitySnapshotKeyChildren"]) FindKeyboardRecords(child,records);
}
static void CollectVisibleValues(NSDictionary *node, NSMutableDictionary *values) {
    id value=node[@"attributes"][@"2025"];
    if (value && CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID())
        values[ExportIdentity(node[@"element"])]=value;
    for (NSDictionary *child in node[@"children"]) CollectVisibleValues(child,values);
}

static NSArray *Candidates(id root, ASAXCollectionRead read) {
    id tokens = read(63, @{@"parameter": @3015}, root);
    if (![tokens isKindOfClass:NSArray.class] || [tokens count] > 256) ASAXFail(@"AX candidate budget or shape invalid");
    NSMutableSet *seen = [NSMutableSet new];
    for (id token in tokens) {
        if (!ASAXToken(token) || ![[token valueForKey:@"pid"] isEqual:[root valueForKey:@"pid"]])
            ASAXFail(@"AX candidate identity invalid");
        NSString *identity = [[token valueForKey:@"objectID"] stringValue];
        if ([seen containsObject:identity]) ASAXFail(@"AX duplicate candidate");
        [seen addObject:identity];
    }
    return tokens;
}
NSDictionary *ASAXCollect(id root, ASAXCollectionRead read) {
    NSArray *attributes = @[@2001, @2002, @2003, @2004, @5019, @2006, @5003, @5004, @3003];
    NSDictionary *options = @{@"attributes": attributes, @"maxDepth": @48, @"maxChildren": @512,
        @"maxArrayCount": @512, @"traverseFromParentsToChildren": @YES, @"snapshotKeyHonorModalViews": @NO};
    NSTimeInterval mark = NSProcessInfo.processInfo.systemUptime;
    id tree = read(52, @{@"parameter": options}, root);
    if (![tree isKindOfClass:NSDictionary.class] || !ASAXSame(tree[@"UIAccessibilitySnapshotKeyElement"], root))
        ASAXFail(@"AX root mismatch");
    NSUInteger count = 0;
    NSDictionary *exported = Export(tree, root, 0, &count, [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality]);
    mark = ASNativeTimingMark(@"ax.structure", mark);
    NSMutableSet *identities = [NSMutableSet new]; CollectIdentities(exported, identities);
    NSArray *tokens = Candidates(root, read);
    mark = ASNativeTimingMark(@"ax.candidates", mark);
    NSMutableDictionary *keyboardValues = [NSMutableDictionary new];
    NSMutableArray *roots = [NSMutableArray new]; FindKeyboardRecords(tree, roots);
    if (roots.count == 1) {
        id token = roots.firstObject[@"UIAccessibilitySnapshotKeyElement"];
        NSMutableDictionary *batchOptions = [options mutableCopy]; batchOptions[@"attributes"] = @[@2025];
        id batch = read(52, @{@"parameter": batchOptions}, token);
        if (![batch isKindOfClass:NSDictionary.class] || !ASAXSame(batch[@"UIAccessibilitySnapshotKeyElement"], token))
            ASAXFail(@"AX keyboard snapshot correlation failed");
        NSUInteger batchCount = 0;
        NSDictionary *batchTree = Export(batch, token, 0, &batchCount, [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality]);
        CollectVisibleValues(batchTree, keyboardValues);
    }
    mark = ASNativeTimingMark(@"ax.keyboard_visibility", mark);
    NSMutableDictionary *visibility = [NSMutableDictionary new];
    NSMutableArray *supplements = [NSMutableArray new];
    NSUInteger batched = 0;
    for (id token in tokens) {
        NSDictionary *element = @{@"pid": [token valueForKey:@"pid"],
            @"objectID": [[token valueForKey:@"objectID"] stringValue], @"application": [token valueForKey:@"isApplicationElement"]};
        NSString *identity = ExportIdentity(element);
        if (![identities containsObject:identity]) {
            if (++count > 4096) ASAXFail(@"AX combined node budget exceeded");
            NSMutableDictionary *single = [options mutableCopy];
            single[@"attributes"] = [attributes arrayByAddingObject:@2025]; single[@"maxDepth"] = @0;
            id record = read(52, @{@"parameter": single}, token);
            if (![record isKindOfClass:NSDictionary.class] || !ASAXSame(record[@"UIAccessibilitySnapshotKeyElement"], token))
                ASAXFail(@"AX supplemental correlation failed");
            id reported = record[@"UIAccessibilitySnapshotKeyChildrenCount"], children = record[@"UIAccessibilitySnapshotKeyChildren"];
            if (![reported isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)reported) == CFBooleanGetTypeID()
                || [reported doubleValue] < 0 || [reported doubleValue] != [reported unsignedIntegerValue]
                || ![children isKindOfClass:NSArray.class] || [children count]) ASAXFail(@"AX supplemental shape invalid");
            NSDictionary *fields = ExportAttributes(record[@"UIAccessibilitySnapshotKeyAttributes"]);
            id visible = fields[@"2025"];
            if (!visible || CFGetTypeID((__bridge CFTypeRef)visible) != CFBooleanGetTypeID()) ASAXFail(@"AX supplemental visibility invalid");
            [supplements addObject:@{@"element": element, @"attributes": fields, @"reportedChildCount": reported,
                @"childrenTraversed": @NO, @"parent": NSNull.null, @"hierarchyKnown": @NO}];
            continue;
        }
        id value = keyboardValues[identity];
        if (value) batched++;
        else value = read(63, @{@"parameter": @2025}, token);
        if (!value || CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID()) ASAXFail(@"AX candidate visibility invalid");
        visibility[identity] = value;
    }
    ASNativeTimingMark(@"ax.candidate_visibility", mark);
    NSUInteger matched = 0;
    NSDictionary *merged = MergeVisibility(exported, visibility, &matched);
    if (matched + supplements.count < tokens.count) ASAXFail(@"AX candidate coverage incomplete");
    return @{@"tree": merged, @"supplementalElements": supplements,
        @"collectionStrategy": @"full_tree_candidate_visibility_keyboard_batch_v1",
        @"visibilityCoverage": @"semantic_candidates", @"candidateCount": @(tokens.count),
        @"keyboardBatchedCandidateCount": @(batched)};
}
