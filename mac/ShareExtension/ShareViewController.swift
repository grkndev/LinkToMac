import Cocoa
import UniformTypeIdentifiers

/// **This does not run today, and it is not a bug in this file.** `amfid` refuses the binary with
/// `AppleMobileFileIntegrityError -423` ("The file is adhoc signed or signed by an unknown
/// certificate chain"): macOS requires app extensions to carry a real certificate chain, and this
/// app is deliberately ad-hoc signed (no Apple Developer account — the same choice that lets the
/// private `SACLockScreenImmediate` work). The extension registers fine and the menu entry appears
/// — registration (`pluginkit`) and execution (`amfid`) are separate gates — but the process is
/// torn down before `viewDidLoad`, so the menu item silently does nothing. Kept here, inert, for
/// whenever a signing identity exists; the alternative that needs no identity is an `NSServices`
/// entry on the app itself. Verify with:
///     log show --last 5m --predicate 'process == "SendToPhone"' --info --debug
///
/// The Finder "Share ▸ Send to Phone" entry — the Mac-side mirror of the phone's share-sheet
/// targets. Right-click any file, share it, and it goes to the phone's Downloads.
///
/// **No UI.** macOS share extensions usually present a compose sheet; this one has nothing to
/// compose, so it completes as soon as it has the file. The user already chose the file and the
/// destination by picking this entry.
///
/// **How it reaches the app.** An extension is sandboxed even though the host app is not, so it
/// can't do the sending itself — the relay/LAN connection and the pairing key live in the app.
/// It hands the path over with `linktomac://send?path=…` through `NSExtensionContext.open`, and
/// the app (unsandboxed, so no bookmark needed) reads the file directly. A shared app-group
/// container would be the usual channel, but app groups need a real team identity and this app is
/// ad-hoc signed with no Apple Developer account.
/// `@objc(ShareViewController)` is load-bearing: `NSExtensionPrincipalClass` in Info.plist is
/// looked up through the Objective-C runtime, and a plain Swift class registers under its
/// *module-qualified* name (`SendToPhone.ShareViewController`), which that lookup would miss.
@objc(ShareViewController)
final class ShareViewController: NSViewController {

    override func loadView() {
        // A real (if tiny) frame: the system presents this controller's view, and a zero-sized one
        // is a good way to have the presentation quietly fail before viewDidLoad ever runs.
        view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 1))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NSLog("[SendToPhone] viewDidLoad, inputItems=%d", extensionContext?.inputItems.count ?? -1)

        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
              let attachment = item.attachments?.first
        else {
            NSLog("[SendToPhone] no attachment on the extension item")
            return complete()
        }
        NSLog("[SendToPhone] offered types: %@", attachment.registeredTypeIdentifiers.joined(separator: ", "))

        // `loadItem`, not `loadDataRepresentation`: a Finder share hands over an NSURL, and which
        // concrete form arrives varies, so accept all three rather than betting on one.
        attachment.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] coded, error in
            let url: URL? = (coded as? URL)
                ?? (coded as? NSURL) as URL?
                ?? (coded as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
            if let error {
                NSLog("[SendToPhone] loadItem failed: %@", error.localizedDescription)
            }
            guard let url, let handoff = Self.handoffURL(for: url) else {
                NSLog("[SendToPhone] no usable file URL (got %@)", String(describing: coded))
                DispatchQueue.main.async { self?.complete() }
                return
            }
            NSLog("[SendToPhone] opening %@", handoff.absoluteString)
            DispatchQueue.main.async {
                self?.extensionContext?.open(handoff) { ok in
                    NSLog("[SendToPhone] open returned %@", ok ? "true" : "false")
                    self?.complete()
                }
            }
        }
    }

    /// `linktomac://send?path=<percent-encoded absolute path>`.
    private static func handoffURL(for file: URL) -> URL? {
        var components = URLComponents()
        components.scheme = "linktomac"
        components.host = "send"
        components.queryItems = [URLQueryItem(name: "path", value: file.path)]
        return components.url
    }

    private func complete() {
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}
