import Cocoa
import UniformTypeIdentifiers

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
        view = NSView(frame: .zero)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
              let attachment = item.attachments?.first
        else { return complete() }

        attachment.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { [weak self] data, _ in
            guard let data,
                  let url = URL(dataRepresentation: data, relativeTo: nil),
                  let handoff = Self.handoffURL(for: url)
            else {
                DispatchQueue.main.async { self?.complete() }
                return
            }
            DispatchQueue.main.async {
                self?.extensionContext?.open(handoff) { _ in self?.complete() }
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
