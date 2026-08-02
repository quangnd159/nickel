#import "NKExceptionGuard.h"

BOOL NKRunWithExceptionGuard(void (NS_NOESCAPE ^block)(void)) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        NSLog(@"NKExceptionGuard: caught %@: %@", exception.name, exception.reason);
        return NO;
    }
}
