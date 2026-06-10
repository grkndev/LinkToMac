import ServiceManagement

/// Registers the app itself as a login item via `SMAppService.mainApp` (macOS 13+).
/// The registration is tied to the app's on-disk path — running from a stable location
/// like /Applications is expected; moving the bundle breaks the login item until
/// it is re-registered.
@MainActor
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func setEnabled(_ on: Bool) throws {
        if on {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
