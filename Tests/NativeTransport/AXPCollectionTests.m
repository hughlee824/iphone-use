#import <Foundation/Foundation.h>
#import "AXPCollection.h"

@interface AXPTranslationObject : NSObject
@property NSNumber *pid;
@property NSNumber *objectID;
@property NSNumber *isApplicationElement;
@end
@implementation AXPTranslationObject
@end
void ASAXFail(NSString *reason) { @throw [NSException exceptionWithName:@"AXTest" reason:reason userInfo:nil]; }
static id Token(unsigned value) {
    AXPTranslationObject *t=[AXPTranslationObject new];t.pid=@123;t.objectID=@(value);t.isApplicationElement=@(value==1);return t;
}
static NSDictionary *Node(id token, NSString *type, NSArray *children, id visible) {
    NSMutableDictionary *fields=[@{@5003:type,@5004:@"UIView",@2001:@"same",@3003:@"example.test"} mutableCopy];
    if(visible)fields[@2025]=visible;
    return @{@"UIAccessibilitySnapshotKeyElement":token,@"UIAccessibilitySnapshotKeyAttributes":fields,
        @"UIAccessibilitySnapshotKeyChildren":children,@"UIAccessibilitySnapshotKeyChildrenCount":@(children.count)};
}
static void Check(BOOL value) { if(!value)abort(); }
static void Reject(void (^block)(void)) {
    BOOL rejected=NO;@try{block();}@catch(NSException *e){rejected=YES;}Check(rejected);
}
static void CheckKeyboardWindow(NSString *mode) {
    id root = Token(1), window = Token(2);
    NSMutableArray *tokens = [NSMutableArray new], *keys = [NSMutableArray new];
    for (NSUInteger i = 0; i < 20; i++) {
        id key = Token(100 + (unsigned)i);
        [tokens addObject:key];
        [keys addObject:Node(key, @"UIAccessibilityElementKBKey", @[], i == 4 ? @NO : @YES)];
    }
    BOOL miss = [mode isEqual:@"miss"], partial = [mode isEqual:@"partial"];
    if (partial) {
        [keys addObject:keys[1]]; // Duplicate identity.
        keys[2] = Node(tokens[2], @"UIAccessibilityElementKBKey", @[], nil);
    }
    __block NSUInteger probes = 0, batches = 0, singles = 0;
    ASAXCollectionRead read = ^id(NSUInteger attr, NSDictionary *params, id token) {
        if (attr == 63) { Check([params[@"parameter"] isEqual:@3015]); return tokens; }
        NSDictionary *options = params[@"parameter"];
        if (token == root && [options[@"maxDepth"] isEqual:@48]) return Node(root, @"Application", @[], nil);
        if (token == root) {
            probes++;
            Check([options[@"maxDepth"] isEqual:@2] && [options[@"attributes"] isEqual:@[@5003]]);
            return Node([mode isEqual:@"wrongRoot"] ? Token(11) : root, @"Application",
                        miss ? @[] : @[Node(window, @"UIRemoteKeyboardWindow", @[], nil)], nil);
        }
        if (token == window) {
            batches++;
            Check([options[@"maxDepth"] isEqual:@48] && [options[@"attributes"] containsObject:@2025]);
            return Node([mode isEqual:@"wrongWindow"] ? Token(11) : window, @"UIRemoteKeyboardWindow", keys, nil);
        }
        singles++;
        Check([options[@"maxDepth"] isEqual:@0]);
        if (miss && singles == 2) [NSThread sleepForTimeInterval:0.16];
        return Node(token, @"UIAccessibilityElementKBKey", @[], @YES);
    };
    if ([mode hasPrefix:@"wrong"]) { Reject(^{ ASAXCollect(root, read); }); return; }
    NSDictionary *result = ASAXCollect(root, read);
    Check(CFGetTypeID((__bridge CFTypeRef)result[@"keyboardWindowProbed"]) == CFBooleanGetTypeID());
    Check(probes == 1 && [result[@"keyboardWindowProbed"] isEqual:@YES]);
    Check([result[@"candidateCount"] isEqual:@20] && batches == (miss ? 0 : 1));
    Check(singles == (miss ? 2 : partial ? 3 : 1));
    Check([result[@"omittedSupplementalCandidateCount"] integerValue] == (miss ? 18 : 0));
    Check([result[@"keyboardWindowMatchedCount"] integerValue] == (miss ? 0 : 20 - singles));
    NSArray *items = result[@"supplementalElements"];
    Check(items.count == (miss ? 2 : 20));
    if (!miss) Check([items[4][@"attributes"][@"2025"] isEqual:@NO] && items[4][@"parent"] == NSNull.null);
}
int main(void) { @autoreleasepool {
    for (NSString *mode in @[@"hit", @"miss", @"partial", @"wrongRoot", @"wrongWindow"]) CheckKeyboardWindow(mode);
    id root=Token(1),keyboard=Token(2),letter=Token(3),next=Token(4),field=Token(5),extra=Token(6);
    id changed=Token(11); [changed setIsApplicationElement:@YES];
    id otherHit=Token(12); [otherHit setPid:@456];
    Check(ASAXSelectionMatches(root,field,nil) && ASAXSelectionMatches(root,nil,Token(1)));
    Check(!ASAXSelectionMatches(root,nil,nil) && !ASAXSelectionMatches(root,nil,field));
    Check(!ASAXSelectionMatches(root,nil,changed) && !ASAXSelectionMatches(root,otherHit,root));
    Check(!ASAXSelectionMatches(field,field,nil) && !ASAXSelectionMatches(root,@1,nil));
    NSDictionary *keys=Node(keyboard,@"UIKeyboardLayoutStar",@[Node(letter,@"UIAccessibilityElementKBKey",@[],nil),
        Node(next,@"UIAccessibilityElementKBKey",@[],nil)],nil);
    NSDictionary *tree=Node(root,@"UIApplication",@[keys,Node(field,@"UITextField",@[],nil)],nil);
    __block NSUInteger calls=0,scalars=0;
    ASAXCollectionRead read=^id(NSUInteger attribute,NSDictionary *parameters,id token){
        calls++;
        if(attribute==63){
            if([parameters[@"parameter"] isEqual:@3015])return @[letter,next,field,extra];
            Check([parameters[@"parameter"] isEqual:@2025]);scalars++;Check(token==field);return @YES;
        }
        Check(attribute==52);NSDictionary *options=parameters[@"parameter"];
        if(token==root){Check(![options[@"attributes"] containsObject:@2025]);return tree;}
        if(token==keyboard){Check([options[@"attributes"] isEqual:@[@2025]]);return Node(keyboard,@"",@[
            Node(letter,@"",@[],@NO),Node(next,@"",@[],@YES)],@YES);}
        Check(token==extra && [options[@"maxDepth"] isEqual:@0]);
        NSMutableDictionary *supplement=[Node(extra,@"Composite",@[],@NO) mutableCopy];
        supplement[@"UIAccessibilitySnapshotKeyChildrenCount"]=@2;return supplement;
    };
    NSDictionary *result=ASAXCollect(root,read);Check(calls==5 && scalars==1);
    Check(result[@"keyboardWindowProbed"] == (__bridge id)kCFBooleanFalse);
    Check([result[@"keyboardBatchedCandidateCount"] isEqual:@2]);Check([result[@"candidateCount"] isEqual:@4]);
    NSDictionary *out=result[@"tree"];Check([out[@"children"] count]==2);
    NSDictionary *outKeyboard=out[@"children"][0];
    Check(outKeyboard[@"attributes"][@"2025"]==nil); // noncandidate remains unknown
    Check([outKeyboard[@"children"][0][@"attributes"][@"2025"] isEqual:@NO]);
    Check([outKeyboard[@"children"][1][@"attributes"][@"2025"] isEqual:@YES]);
    NSDictionary *supplement=[result[@"supplementalElements"] firstObject];
    Check(supplement[@"parent"]==NSNull.null && [supplement[@"reportedChildCount"] isEqual:@2]);
    Check([supplement[@"attributes"][@"2025"] isEqual:@NO]);
    Check(tree[@"UIAccessibilitySnapshotKeyAttributes"][@2025]==nil);
    NSDictionary *partial=ASAXCollect(root,^id(NSUInteger attr,NSDictionary *params,id token){
        if(attr==63 && token==field)return nil;
        if(attr==52 && token==extra)return Node(extra,@"Composite",@[],nil);
        return read(attr,params,token);
    });
    Check(partial[@"tree"][@"children"][1][@"attributes"][@"2025"]==NSNull.null);
    Check(partial[@"supplementalElements"][0][@"attributes"][@"2025"]==NSNull.null);
    Check([partial[@"tree"][@"children"][0][@"children"][1][@"attributes"][@"2025"] isEqual:@YES]);
    Reject(^{ ASAXCollect(root,^id(NSUInteger attr,NSDictionary *params,id token){
        if(attr==52 && token==root)return Node(otherHit,@"AXRemoteElement",@[],nil);
        return read(attr,params,token);
    }); });
    for(NSString *failure in @[@"duplicate",@"foreign",@"oversized",@"missing-child",@"wrong-keyboard",@"nonbool",@"request-failure"]){
        Reject(^{ASAXCollect(root,^id(NSUInteger attr,NSDictionary *params,id token){
            if([failure isEqual:@"missing-child"] && token==root && attr==52){
                NSMutableDictionary *bad=[tree mutableCopy];bad[@"UIAccessibilitySnapshotKeyChildrenCount"]=@99;return bad;
            }
            if(attr==63 && [params[@"parameter"] isEqual:@3015]){
                if([failure isEqual:@"duplicate"])return @[letter,letter];
                if([failure isEqual:@"foreign"]){id foreign=Token(10);[foreign setPid:@456];return @[foreign];}
                if([failure isEqual:@"oversized"]){NSMutableArray *many=[NSMutableArray new];for(int i=0;i<257;i++)[many addObject:Token(100+i)];return many;}
            }
            if(attr==52 && token==keyboard && [failure isEqual:@"wrong-keyboard"])return Node(field,@"",@[],@YES);
            if(attr==63 && [params[@"parameter"] isEqual:@2025]){
                if([failure isEqual:@"nonbool"])return @1;
                if([failure isEqual:@"request-failure"])ASAXFail(@"timeout");
            }
            return read(attr,params,token);
        });});
    }
    // No keyboard and ambiguous keyboard roots retain exact per-candidate fallback.
    for(NSArray *children in @[@[Node(field,@"UITextField",@[],nil)],@[keys,keys]]){
        __block NSUInteger reads=0;
        NSDictionary *fallback=ASAXCollect(root,^id(NSUInteger attr,NSDictionary *params,id token){
            reads++;
            if(attr==52){Check(token==root);return Node(root,@"UIApplication",children,nil);}
            if([params[@"parameter"] isEqual:@3015])return @[[children count]==1?field:letter];
            return @NO;
        });
        Check(reads==3 && [fallback[@"keyboardBatchedCandidateCount"] isEqual:@0]);
    }
    puts("AX collection: coverage, native false/unknown, batch, supplements, fallback and failures passed");
} return 0; }
