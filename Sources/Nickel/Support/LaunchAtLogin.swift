import Foundation
import ServiceManagement

/// Thin wrapper around `SMAppService.mainApp` for the "Launch at Login"
/// overflow-menu toggle. Registration errors are logged only, per spec:
/// there's no user-facing recovery for a login-item registration failure.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("LaunchAtLogin: failed to \(enabled ? "register" : "unregister"): \(error)")
        }
    }
}
