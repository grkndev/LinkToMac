import Foundation

/// Locks the Mac screen on request from the paired phone.
///
/// Uses the private `SACLockScreenimmediate` from `login.framework` — the same call the
/// system uses for "Lock Screen". It locks in place (no fast-user-switch to the login
/// window) and needs no entitlement, which is fine here: the app isn't sandboxed and the
/// hardened runtime is off (see `project.yml`). If the symbol can't be resolved on some
/// future macOS, we fall back to `CGSession -suspend`, which drops to the login window.
enum ScreenLock {
    static func lock() {
        if lockViaLoginFramework() { return }
        suspendSession()
    }

    /// `Bool` so the caller can fall back if the private symbol is unavailable.
    private static func lockViaLoginFramework() -> Bool {
        let path = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"
        guard let handle = dlopen(path, RTLD_NOW) else { return false }
        defer { dlclose(handle) }
        guard let sym = dlsym(handle, "SACLockScreenImmediate") else { return false }
        typealias LockFn = @convention(c) () -> Int32
        _ = unsafeBitCast(sym, to: LockFn.self)()
        return true
    }

    /// Fallback: fast-user-switch to the login window via the CGSession helper.
    private static func suspendSession() {
        let process = Process()
        process.executableURL = URL(
            fileURLWithPath:
                "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession"
        )
        process.arguments = ["-suspend"]
        try? process.run()
    }
}
