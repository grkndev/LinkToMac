import AppKit

/// Polls `NSPasteboard.changeCount` (there is no change notification) and reports new text.
/// We only watch — we never write the pasteboard here — so a change always means the user
/// copied something, and there is no self-induced echo to suppress on the Mac side.
@MainActor
final class PasteboardWatcher {
    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int
    private var pollTask: Task<Void, Never>?
    private let onChange: (String) -> Void

    private static let interval: Duration = .milliseconds(500)

    init(onChange: @escaping (String) -> Void) {
        self.onChange = onChange
        self.lastChangeCount = NSPasteboard.general.changeCount
    }

    func start() {
        stop()
        // Baseline to "now" so we don't broadcast whatever was already on the clipboard.
        lastChangeCount = pasteboard.changeCount
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(for: PasteboardWatcher.interval)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func poll() {
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        onChange(text)
    }
}
