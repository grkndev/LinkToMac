import Foundation
@preconcurrency import UserNotifications

/// Thin wrapper over `UNUserNotificationCenter` for raising a native macOS banner when a mirrored
/// phone notification arrives. Authorization is requested lazily on first use (a one-time system
/// prompt); until the user grants it, `post` is a silent no-op.
///
/// The app is an unsandboxed, ad-hoc-signed `.app` bundle, so local notifications work with no
/// extra entitlement. When an `iconPNG` is supplied (the posting app's icon, mirrored from Android)
/// it rides as a `UNNotificationAttachment`, so the banner shows e.g. the WhatsApp / Discord icon.
/// (macOS still draws *our* app icon in the banner's top-left corner — that is fixed to the bundle
/// for local notifications and can't be overridden; the attachment is the supported way to surface
/// the source app's artwork.) **The attachment is strictly best-effort: if the system rejects it
/// the banner is re-posted text-only, so an icon problem can never suppress the banner itself.**
@MainActor
enum MacNotifier {
    private static var requested = false
    /// Non-nil while the (one-time) authorization request is in flight. `post` awaits this
    /// before reading settings, so a banner that races the very first request doesn't read a
    /// stale `.notDetermined` and get silently dropped (the first-launch race).
    private static var pendingAuthorization: Task<Void, Never>?

    /// Ask for banner authorization once. Safe to call repeatedly; only the first call prompts.
    static func requestAuthorizationIfNeeded() {
        guard !requested else { return }
        requested = true
        pendingAuthorization = Task {
            do {
                _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            } catch {
                print("[MacNotifier] authorization error: \(error.localizedDescription)")
            }
            pendingAuthorization = nil
        }
    }

    /// Current OS authorization state — lets UI (Settings' "Notification banners" toggle) react
    /// to a denial with an "open System Settings" affordance instead of leaving the toggle a
    /// silent no-op forever (there is no in-app re-request once the user has said no).
    static func currentStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Raise a banner. No-op if the user hasn't authorized notifications. `iconPNG`, when present, is
    /// the source app's icon (PNG bytes) shown as the banner's attachment thumbnail.
    static func post(title: String, body: String, iconPNG: Data? = nil) async {
        requestAuthorizationIfNeeded()
        await pendingAuthorization?.value
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        else { return }
        deliver(title: title, body: body, iconURL: iconPNG.flatMap { writeTempIcon($0) })
    }

    /// Build + add the request. `nonisolated` so it runs in `getNotificationSettings`'s off-main
    /// `@Sendable` callback and can re-invoke itself (text-only) if the attachment is rejected.
    private nonisolated static func deliver(title: String, body: String, iconURL: URL?) {
        let content = UNMutableNotificationContent()
        content.title = title
        if !body.isEmpty { content.body = body }
        content.sound = .default
        if let iconURL,
           let attachment = try? UNNotificationAttachment(
               identifier: UUID().uuidString, url: iconURL,
               options: [UNNotificationAttachmentOptionsTypeHintKey: "public.png"]) {
            content.attachments = [attachment]
        }
        let hadAttachment = !content.attachments.isEmpty
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let iconURL { try? FileManager.default.removeItem(at: iconURL) }
            // If the attachment made the request invalid, the banner is dropped — re-post it
            // text-only so the notification still appears (the icon is a nice-to-have).
            if error != nil, hadAttachment {
                deliver(title: title, body: body, iconURL: nil)
            }
        }
    }

    /// Write `png` to a unique temp file for use as a notification attachment; nil on failure.
    /// `nonisolated` so it can run inside `getNotificationSettings`'s off-main `@Sendable` callback.
    private nonisolated static func writeTempIcon(_ png: Data) -> URL? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linktomac-note-icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(UUID().uuidString + ".png")
        return (try? png.write(to: url)) != nil ? url : nil
    }
}
