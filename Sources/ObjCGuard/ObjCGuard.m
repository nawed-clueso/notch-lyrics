#import "include/ObjCGuard.h"

NSString *_Nullable NLGuardRun(void (NS_NOESCAPE ^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *e) {
        NSString *reason = e.reason.length > 0 ? e.reason : e.name;
        return reason.length > 0 ? reason : @"unknown Objective-C exception";
    }
}
