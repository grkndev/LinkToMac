import SwiftUI
import AppKit

/// Files: the transfer in flight (sending and/or receiving) and the history of what went to and
/// came from the phone. Drop anywhere in the window, or use the toolbar buttons.
struct FilesPage: View {
    let client: RelayClient

    var body: some View {
        DashColumnPage(width: 760) {
            VStack(alignment: .leading, spacing: 16) {
                if let batch = client.outgoingBatch { sendingCard(batch) }
                if let incoming = client.incomingFile { receivingCard(incoming) }
                dropHint
                history
            }
        }
    }

    // MARK: - In flight

    private func sendingCard(_ batch: BatchProgress) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                DSCircleIcon(icon: "arrow.up", size: 38, fill: M3.primaryContainer, ink: M3.onPrimaryContainer)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text("Sending \(batch.currentName)").font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(M3.onSurface).lineLimit(1).truncationMode(.middle)
                        Text("(\(batch.currentPercent)%)").font(.system(size: 13.5)).foregroundStyle(M3.onSurfaceVariant)
                    }
                    Text(sendingDetail(batch)).font(.system(size: 12)).foregroundStyle(M3.onSurfaceVariant).lineLimit(1)
                }
                Spacer(minLength: 8)
                Button(action: client.cancelOutgoing) {
                    Text("Cancel").font(.system(size: 13, weight: .medium)).foregroundStyle(M3.onSurface)
                        .padding(.horizontal, 16).frame(height: 30)
                        .background(Capsule().fill(M3.surfaceContainerHigh))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            DSProgressBar(fraction: batch.overallFraction, height: 6)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(M3.surfaceContainer))
    }

    private func sendingDetail(_ batch: BatchProgress) -> String {
        let phone = client.phoneName ?? "your phone"
        let files = batch.count > 1 ? "\(batch.index) / \(batch.count) files · " : ""
        return "\(files)to \(phone) · Downloads"
    }

    private func receivingCard(_ file: TransferProgress) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                DSCircleIcon(icon: "arrow.down", size: 38, fill: M3.primaryContainer, ink: M3.onPrimaryContainer)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Receiving \(file.name)").font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(M3.onSurface).lineLimit(1).truncationMode(.middle)
                    Text("from \(client.phoneName ?? "your phone") · \(file.percent)%")
                        .font(.system(size: 12)).foregroundStyle(M3.onSurfaceVariant)
                }
                Spacer(minLength: 0)
            }
            DSProgressBar(fraction: file.fraction, height: 6)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(M3.surfaceContainer))
    }

    private var dropHint: some View {
        HStack(spacing: 12) {
            Image(systemName: "tray.and.arrow.down").font(.system(size: 16)).foregroundStyle(M3.primary)
            Text("Drop files or folders anywhere in this window, or use Finder ▸ Share ▸ Send to Phone.")
                .font(.system(size: 13)).foregroundStyle(M3.onSurfaceVariant)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).frame(minHeight: 47)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(M3.outlineVariant, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        )
    }

    // MARK: - History

    @ViewBuilder private var history: some View {
        let rows = client.fileHistory
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("History").font(.system(size: 12, weight: .semibold)).foregroundStyle(M3.onSurfaceVariant)
                Spacer(minLength: 0)
                if !rows.isEmpty {
                    Button { client.clearFileHistory() } label: {
                        Text("Clear").font(.system(size: 12.5, weight: .medium)).foregroundStyle(M3.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 4)
            if rows.isEmpty {
                Text("Files you send or receive appear here.")
                    .font(.system(size: 12.5)).foregroundStyle(M3.onSurfaceVariant)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).frame(height: 60)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(M3.surfaceContainer))
            } else {
                VStack(spacing: 3) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        FileRow(row: row, folder: client.fileDrop.folder.lastPathComponent,
                                position: dashGroupPosition(index, count: rows.count)) {
                            if row.canResume { client.resumeTransfer(row) }
                            else if let url = row.location { FileRow.open(url) }
                        }
                    }
                }
            }
        }
    }

    private struct FileRow: View {
        let row: FileTransferRecord
        let folder: String
        let position: M3GroupPosition
        let action: () -> Void

        private var failed: Bool { if case .failed = row.status { return true } else { return false } }
        private var interactive: Bool { row.canResume || row.location != nil }

        private var subtitle: String {
            let when = DashTime.relative(row.date)
            if case let .failed(reason) = row.status {
                return row.canResume ? "Failed: \(reason) · click to resume" : "Failed: \(reason) · \(when)"
            }
            let size = ByteCountFormatter.string(fromByteCount: Int64(row.bytes), countStyle: .file)
            let count = row.fileCount > 1 ? "\(row.fileCount) files · " : ""
            switch row.direction {
            case .received: return "From your phone · \(folder) · \(size) · \(when)"
            case .sent: return "To your phone · \(count)\(size) · \(when)"
            }
        }

        var body: some View {
            Button(action: action) {
                DSListRow(title: row.name, subtitle: subtitle,
                          subtitleColor: failed ? M3.error : M3.onSurfaceVariant,
                          position: position, interactive: interactive) {
                    DSCircleIcon(icon: row.direction == .received ? "arrow.down" : "arrow.up",
                                 fill: failed ? M3.error.opacity(0.18) : M3.surfaceContainerHigh,
                                 ink: failed ? M3.error : M3.onSurfaceVariant)
                } trailing: {
                    if row.canResume {
                        Image(systemName: "arrow.clockwise").font(.system(size: 15, weight: .medium))
                            .foregroundStyle(M3.error)
                    } else if row.location != nil {
                        Image(systemName: "arrow.up.forward.square").font(.system(size: 14))
                            .foregroundStyle(M3.outline)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(!interactive)
        }

        /// Open a received file; if it was moved or deleted, show its folder instead.
        @MainActor static func open(_ url: URL) {
            if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.open(url) }
            else { NSWorkspace.shared.open(url.deletingLastPathComponent()) }
        }
    }
}
