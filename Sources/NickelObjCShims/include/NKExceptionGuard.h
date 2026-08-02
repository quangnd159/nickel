#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block`, catching any Objective-C exception it raises. Returns YES if
/// the block completed, NO if an exception was caught (logged via NSLog).
///
/// Swift cannot catch NSExceptions, but some AppKit-internal observers (e.g.
/// ViewBridge's NSRemoteView on macOS betas) throw them during ordinary
/// window operations. This guard exists solely to keep such an OS-level throw
/// from aborting the process.
BOOL NKRunWithExceptionGuard(void (NS_NOESCAPE ^block)(void));

NS_ASSUME_NONNULL_END
