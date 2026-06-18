import SwiftUI

/// Shared System-Settings-style building blocks for the menu-bar panel and the standalone
/// windows (e.g. `AboutView`). Kept in one place so every surface reads as the same design.

/// Small uppercased group title, System-Settings style.
struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.leading, 4)
    }
}

/// Rounded grouped container holding stacked rows; clips so row hover stays inside corners.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            )
    }
}

/// Hairline separator inset to start after the leading icon column.
struct RowDivider: View {
    var body: some View {
        Divider().padding(.leading, 38)
    }
}

struct RowIcon: View {
    let name: String
    var body: some View {
        Image(systemName: name)
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
            .frame(width: 20, alignment: .center)
    }
}

struct ToggleRow: View {
    let icon: String
    let title: String
    @Binding var isOn: Bool
    var body: some View {
        HStack(spacing: 8) {
            RowIcon(name: icon)
            Text(title).font(.system(size: 13))
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }
}

/// A row with a leading icon, a title, and a trailing pop-up menu picker.
struct PickerRow<Value: Hashable>: View {
    let icon: String
    let title: String
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String
    var body: some View {
        HStack(spacing: 8) {
            RowIcon(name: icon)
            Text(title).font(.system(size: 13))
            Spacer(minLength: 8)
            Picker("", selection: $selection) {
                ForEach(options, id: \.self) { option in
                    Text(label(option)).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

struct ButtonRow: View {
    let icon: String
    let title: String
    var showsChevron: Bool = false
    /// Trailing SF Symbol drawn when `showsChevron` is set — `arrow.up.right` for links, etc.
    var trailingSymbol: String = "chevron.right"
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                RowIcon(name: icon)
                Text(title).font(.system(size: 13))
                Spacer(minLength: 8)
                if showsChevron {
                    Image(systemName: trailingSymbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .background(hovering ? Color.primary.opacity(0.06) : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct InfoRow: View {
    let icon: String
    let title: String
    let value: String
    var body: some View {
        HStack(spacing: 8) {
            RowIcon(name: icon)
            Text(title).font(.system(size: 13))
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 150, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }
}
