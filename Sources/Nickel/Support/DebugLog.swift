import Foundation

/// `true` iff `NICKEL_DEBUG=1` is set in the environment. Checked once at
/// launch so `debugLog` is a cheap no-op in normal (non-debug) runs.
private let isDebugLoggingEnabled = ProcessInfo.processInfo.environment["NICKEL_DEBUG"] == "1"

/// Logs `message` via `NSLog` when `NICKEL_DEBUG=1` is set; otherwise does
/// nothing. Used to trace hotkey detection and capture behavior without any
/// logging overhead in normal use.
func debugLog(_ message: @autoclosure () -> String) {
    guard isDebugLoggingEnabled else { return }
    NSLog("[Nickel] %@", message())
}
