import SwiftUI
import AppKit

/// Material 3 (Expressive) design tokens + components for the dashboard window. Light and dark
/// palettes follow the system; they carry the Android app's brand (muted-blue tonal scheme, large
/// rounded tonal cards, circular tonal icon badges, two-line list items, connected groups).

/// M3 colour roles, **light and dark** (they follow the system / the window's appearance). Both
/// palettes come from the macOS redesign ("Link to Mac macOS" design): the Android tones, softened
/// for large desktop surfaces. Each role is a dynamic `NSColor`, so every view that already uses an
/// `M3.*` token adapts without knowing which scheme is active.
enum M3 {
    // MARK: Color roles (dark ↔ light)
    static let surface = Color(dark: 0x17181C, light: 0xFFFFFF)               // window content
    static let sidebar = Color(dark: 0x1F2126, light: 0xF2F3F7)               // floating sidebar
    static let surfaceContainerLowest = sidebar
    static let surfaceContainerLow = sidebar
    static let surfaceContainer = Color(dark: 0x24272D, light: 0xF2F4F8)      // cards, rows, chips (idle)
    static let surfaceContainerHigh = Color(dark: 0x2E3239, light: 0xE8EBF2)  // hover / pressed / raised
    static let surfaceContainerHighest = Color(dark: 0x383C44, light: 0xDDE1EA)
    static let primary = Color(dark: 0xAEBEEA, light: 0x3F5BA8)               // switches, links, key accents
    static let onPrimary = Color(dark: 0x17264F, light: 0xFFFFFF)
    static let primaryContainer = Color(dark: 0x2F4170, light: 0xDDE4F8)
    static let onPrimaryContainer = Color(dark: 0xDCE3F9, light: 0x1E2F63)
    static let secondaryContainer = Color(dark: 0x2F4170, light: 0xDDE4F8)    // tonal icon badges, chips, selected
    static let onSecondaryContainer = Color(dark: 0xDCE3F9, light: 0x1E2F63)  // icon/label on secondaryContainer
    static let onSurface = Color(dark: 0xE7E8ED, light: 0x1B1C21)             // titles, primary labels
    static let onSurfaceVariant = Color(dark: 0xA6AAB5, light: 0x5F6372)      // subtitles, idle labels
    static let outline = Color(dark: 0x747985, light: 0x8E929E)
    /// Hairlines and dividers (translucent, so they sit on any surface).
    static let outlineVariant = Color(dark: 0xFFFFFF, darkAlpha: 0.08, light: 0x141828, lightAlpha: 0.09)
    static let success = Color(dark: 0x4ADE80, light: 0x2E9E5B)               // connected dot
    static let warning = Color(dark: 0xF0B04A, light: 0xC47C10)
    static let error = Color(dark: 0xFFB4AB, light: 0xC93A2E)                 // destructive label
    static let errorContainer = Color(dark: 0x93000A, light: 0xF9DEDC)        // destructive badge fill
    static let field = Color(dark: 0x1B1D21, light: 0xFFFFFF)                 // text-field fill
    static let switchOff = Color(dark: 0x3A3E46, light: 0xD5D8E0)

    /// Four tonal pairs (fill, ink) the design uses to tell apps and contacts apart — blue,
    /// purple, green, orange. `tint(for:)` picks one from a name, so the same app or contact
    /// always gets the same colour.
    static let tints: [(fill: Color, ink: Color)] = [
        (Color(dark: 0x2F4170, light: 0xDDE4F8), Color(dark: 0xDCE3F9, light: 0x1E2F63)),
        (Color(dark: 0x3D3157, light: 0xEADFF5), Color(dark: 0xE8DDF5, light: 0x4A3470)),
        (Color(dark: 0x24402E, light: 0xD9EFE1), Color(dark: 0xCDEBD6, light: 0x1F5133)),
        (Color(dark: 0x4A3322, light: 0xF7E3D3), Color(dark: 0xF5DCC7, light: 0x6B3A12)),
    ]
    static func tint(for name: String) -> (fill: Color, ink: Color) {
        let sum = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return tints[sum % tints.count]
    }

    // MARK: Shape corners (dp) — M3 + Expressive "increased" steps
    static let corSmall: CGFloat = 8
    static let corMedium: CGFloat = 12
    static let corLarge: CGFloat = 16
    static let corLargeIncreased: CGFloat = 20
    static let corExtraLarge: CGFloat = 28
    // Connected-list group: the group's outer corners read large, the adjoining inner corners small.
    static let corGroupOuter: CGFloat = corLargeIncreased   // 20 — top of first / bottom of last row
    static let corGroupInner: CGFloat = 6                    // where rows meet inside the group

    // MARK: Type scale (system SF stands in for Roboto; titles are emphasized/bold)
    static func headline(_ s: CGFloat = 28) -> Font { .system(size: s, weight: .bold) }
    static let titleLarge = Font.system(size: 22, weight: .semibold)
    static let titleMedium = Font.system(size: 16, weight: .semibold)
    static let bodyLarge = Font.system(size: 15, weight: .regular)
    static let bodyMedium = Font.system(size: 13.5, weight: .regular)
    static let labelLarge = Font.system(size: 14, weight: .medium)
}

extension Color {
    /// A colour that resolves per appearance (`.darkAqua` vs aqua) at draw time. This is what makes
    /// the M3 tokens follow the system's light/dark setting instead of being fixed.
    init(dark: UInt32, darkAlpha: Double = 1, light: UInt32, lightAlpha: Double = 1) {
        func ns(_ hex: UInt32, _ alpha: Double) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                    green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255,
                    alpha: alpha)
        }
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? ns(dark, darkAlpha) : ns(light, lightAlpha)
        })
    }

    init(m3 hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

/// A circular tonal icon badge (M3 secondaryContainer fill + onSecondaryContainer glyph) — the
/// product's signature list/action affordance. `fill`/`tint` overridable for dim/destructive states.
struct M3IconBadge: View {
    let icon: String
    var size: CGFloat = 48
    var fill: Color = M3.secondaryContainer
    var tint: Color = M3.onSecondaryContainer
    var body: some View {
        Circle()
            .fill(fill)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: icon)
                    .font(.system(size: size * 0.4, weight: .regular))
                    .foregroundStyle(tint)
            )
    }
}

/// A circular leading badge backed by a real image (e.g. a mirrored notification's app icon),
/// falling back to a tonal SF-Symbol `M3IconBadge` when no image is available. The image is
/// clipped to the same circle as `M3IconBadge` so notification rows read in the M3 badge language.
struct M3ImageBadge: View {
    let image: NSImage?
    var fallback: String = "bell.fill"
    var size: CGFloat = 44
    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else {
            M3IconBadge(icon: fallback, size: size)
        }
    }
}

/// A tonal status chip — M3 rounded-rect (medium corner), secondaryContainer fill (mirrors the
/// mobile app's identity chips). Not a full capsule.
struct M3Chip: View {
    let icon: String
    let text: String
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold))
            Text(text).font(M3.labelLarge)
        }
        .foregroundStyle(M3.onSecondaryContainer)
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: M3.corMedium, style: .continuous)
                .fill(M3.secondaryContainer)
        )
    }
}

/// A 2×2-grid action card — M3 Expressive: a tall filled tonal card with a centered circular badge
/// over a label (the mobile app's primary-action idiom). `enabled == false` dims the badge + label
/// for roadmap tiles. Hover raises the surface tone.
struct M3ActionTile: View {
    let icon: String
    let title: String
    var enabled: Bool = true
    var corners: M3GroupCorners = .all
    @State private var hovering = false

    private var shape: UnevenRoundedRectangle { corners.shape() }

    var body: some View {
        VStack(spacing: 14) {
            M3IconBadge(
                icon: icon, size: 52,
                fill: enabled ? M3.secondaryContainer : M3.surfaceContainerHigh,
                tint: enabled ? M3.onSecondaryContainer : M3.onSurfaceVariant
            )
            Text(title)
                .font(M3.titleMedium)
                .foregroundStyle(enabled ? M3.onSurface : M3.onSurfaceVariant)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 112)
        .background(shape.fill((hovering && enabled) ? M3.surfaceContainerHigh : M3.surfaceContainer))
        .contentShape(shape)
        .onHover { hovering = $0 }
    }
}

/// One segment of the right-panel tab bar — an M3 filter-chip in a **connected button group**: pass
/// `position` so the strip's outer corners round large and the inner (adjoining) corners round small.
/// Selected fills secondaryContainer (tonal); idle stays on surfaceContainer.
struct M3Tab: View {
    let icon: String
    let title: String
    let selected: Bool
    var position: M3GroupPosition = .single
    let action: () -> Void
    @State private var hovering = false

    private var shape: UnevenRoundedRectangle { position.shape(axis: .horizontal) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 15, weight: .semibold))
                Text(title).font(M3.labelLarge)
            }
            .foregroundStyle(selected ? M3.onSecondaryContainer : M3.onSurfaceVariant)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(shape.fill(selected ? M3.secondaryContainer
                                            : (hovering ? M3.surfaceContainerHigh : M3.surfaceContainer)))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Which of a connected-group cell's four corners round large (the group's outer edge) vs. small
/// (inner corners that abut a sibling). The single source of truth for connected-group corner shaping
/// — used by the row list, the tab strip, and the 2×2 action grid.
struct M3GroupCorners {
    var topLeading = false, bottomLeading = false, bottomTrailing = false, topTrailing = false

    /// A lone, fully-rounded cell (all four corners large) — the default for standalone callers.
    static let all = M3GroupCorners(topLeading: true, bottomLeading: true, bottomTrailing: true, topTrailing: true)

    /// Corners for the cell at (`row`, `col`) of a `rows`×`cols` grid — only the grid's four outermost
    /// corners round large; every inner corner that meets a sibling rounds small.
    static func grid(row: Int, col: Int, rows: Int, cols: Int) -> M3GroupCorners {
        M3GroupCorners(
            topLeading:     row == 0 && col == 0,
            bottomLeading:  row == rows - 1 && col == 0,
            bottomTrailing: row == rows - 1 && col == cols - 1,
            topTrailing:    row == 0 && col == cols - 1
        )
    }

    func shape(big: CGFloat = M3.corGroupOuter, small: CGFloat = M3.corGroupInner) -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: topLeading ? big : small,
            bottomLeadingRadius: bottomLeading ? big : small,
            bottomTrailingRadius: bottomTrailing ? big : small,
            topTrailingRadius: topTrailing ? big : small,
            style: .continuous
        )
    }
}

/// Position of a cell inside a 1-D connected M3 group (a list run **or** a tab strip) — drives which
/// corners round large (the group's outer edge) vs. small (where cells meet). `.single` is a lone,
/// fully-rounded cell (the default, so standalone callers are unchanged).
enum M3GroupPosition {
    case single, first, middle, last

    /// The cell's corners along `axis`. Vertical → first=top/last=bottom; horizontal → first=leading/last=trailing.
    func corners(axis: Axis) -> M3GroupCorners {
        switch (self, axis) {
        case (.single, _):          return .all
        case (.middle, _):          return M3GroupCorners()
        case (.first, .vertical):   return M3GroupCorners(topLeading: true, topTrailing: true)
        case (.last, .vertical):    return M3GroupCorners(bottomLeading: true, bottomTrailing: true)
        case (.first, .horizontal): return M3GroupCorners(topLeading: true, bottomLeading: true)
        case (.last, .horizontal):  return M3GroupCorners(bottomTrailing: true, topTrailing: true)
        }
    }

    func shape(axis: Axis, big: CGFloat = M3.corGroupOuter, small: CGFloat = M3.corGroupInner) -> UnevenRoundedRectangle {
        corners(axis: axis).shape(big: big, small: small)
    }
}

/// A two-line M3 list row — leading circular tonal badge, title + subtitle, optional trailing label
/// (matches the mobile app's settings/clipboard rows). In a connected group, pass `position` so the
/// outer corners round large and the inner (adjoining) corners round small. Hover raises the tone.
struct M3Row: View {
    let icon: String
    /// Optional leading image (e.g. a notification's app icon). When nil, the `icon` SF Symbol shows.
    var iconImage: NSImage? = nil
    let title: String
    var subtitle: String? = nil
    var trailing: String? = nil
    var position: M3GroupPosition = .single
    @State private var hovering = false

    private var shape: UnevenRoundedRectangle { position.shape(axis: .vertical) }

    var body: some View {
        HStack(spacing: 14) {
            M3ImageBadge(image: iconImage, fallback: icon, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(M3.titleMedium).foregroundStyle(M3.onSurface).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(M3.bodyMedium).foregroundStyle(M3.onSurfaceVariant).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing).font(M3.bodyMedium).foregroundStyle(M3.onSurfaceVariant)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 68)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(hovering ? M3.surfaceContainerHigh : M3.surfaceContainer))
        .contentShape(shape)
        .onHover { hovering = $0 }
    }
}

// MARK: - Settings rows (M3 interactive)
// The functional counterparts to the display-only M3Row, used to rebuild the Settings sub-screen in
// the dashboard's language: tonal badge + two-line text, packed into connected groups via M3GroupPosition.

/// Uppercased group header above a connected M3 settings group.
struct M3SectionHeader: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(M3.onSurfaceVariant)
            .padding(.leading, 6)
    }
}

/// A tappable M3 settings row — leading tonal badge, title + optional subtitle, optional trailing
/// value + symbol. `role: .destructive` recolours the badge/title red. Connected-group aware.
struct M3SettingsRow: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var value: String? = nil
    var trailingSymbol: String? = "chevron.right"
    var role: ButtonRole? = nil
    var position: M3GroupPosition = .single
    let action: () -> Void
    @State private var hovering = false

    private var shape: UnevenRoundedRectangle { position.shape(axis: .vertical) }
    private var destructive: Bool { role == .destructive }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                M3IconBadge(icon: icon, size: 44,
                            fill: destructive ? M3.errorContainer : M3.secondaryContainer,
                            tint: destructive ? M3.error : M3.onSecondaryContainer)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(M3.titleMedium)
                        .foregroundStyle(destructive ? M3.error : M3.onSurface).lineLimit(1)
                    if let subtitle {
                        Text(subtitle).font(M3.bodyMedium)
                            .foregroundStyle(M3.onSurfaceVariant).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if let value {
                    Text(value).font(M3.bodyMedium).foregroundStyle(M3.onSurfaceVariant)
                }
                if let trailingSymbol {
                    Image(systemName: trailingSymbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(M3.onSurfaceVariant)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 64)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(hovering ? M3.surfaceContainerHigh : M3.surfaceContainer))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// An M3 settings row with a trailing switch — leading tonal badge, title + optional subtitle.
struct M3ToggleRow: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool
    var position: M3GroupPosition = .single

    private var shape: UnevenRoundedRectangle { position.shape(axis: .vertical) }

    var body: some View {
        HStack(spacing: 14) {
            M3IconBadge(icon: icon, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(M3.titleMedium).foregroundStyle(M3.onSurface).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(M3.bodyMedium).foregroundStyle(M3.onSurfaceVariant).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(M3.primary)
        }
        .padding(.horizontal, 16)
        .frame(height: 64)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(M3.surfaceContainer))
    }
}

/// An M3 filled text-field row — leading tonal badge, a small label over an inline (borderless)
/// text/secure field. `invalid` recolours the label red. Connected-group aware.
struct M3FieldRow: View {
    let icon: String
    let label: String
    var placeholder: String = ""
    var secure: Bool = false
    var invalid: Bool = false
    @Binding var text: String
    var position: M3GroupPosition = .single

    private var shape: UnevenRoundedRectangle { position.shape(axis: .vertical) }

    var body: some View {
        HStack(spacing: 14) {
            M3IconBadge(icon: icon, size: 44)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(M3.bodyMedium)
                    .foregroundStyle(invalid ? M3.error : M3.onSurfaceVariant)
                Group {
                    if secure { SecureField(placeholder, text: $text) }
                    else { TextField(placeholder, text: $text) }
                }
                .textFieldStyle(.plain)
                .font(M3.bodyLarge)
                .foregroundStyle(M3.onSurface)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 16)
        .frame(height: 64)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(M3.surfaceContainer))
    }
}

/// An M3 settings row whose trailing control is a pop-up menu, shown as a tonal pill of the current
/// value. Connected-group aware.
struct M3PickerRow<Value: Hashable>: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String
    var position: M3GroupPosition = .single

    private var shape: UnevenRoundedRectangle { position.shape(axis: .vertical) }

    var body: some View {
        HStack(spacing: 14) {
            M3IconBadge(icon: icon, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(M3.titleMedium).foregroundStyle(M3.onSurface).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(M3.bodyMedium).foregroundStyle(M3.onSurfaceVariant).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Menu {
                ForEach(options, id: \.self) { option in
                    Button(label(option)) { selection = option }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(label(selection)).font(M3.labelLarge)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(M3.onSecondaryContainer)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(Capsule().fill(M3.secondaryContainer))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .frame(height: 64)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(M3.surfaceContainer))
    }
}

/// A filled M3 button (primary tonal pill). Dims when disabled.
struct M3Button: View {
    let title: String
    var enabled: Bool = true
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(M3.labelLarge)
                .foregroundStyle(enabled ? M3.onPrimary : M3.onSurfaceVariant)
                .padding(.horizontal, 24)
                .frame(height: 40)
                .background(
                    Capsule().fill(enabled ? M3.primary.opacity(hovering ? 0.9 : 1)
                                           : M3.surfaceContainerHigh)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
    }
}


// MARK: - Design kit (shared by the redesigned pages)

/// Lays children out left to right in proportion to `weights` (the design's `flex: 1.25 / 1`),
/// aligned to the top. SwiftUI's `HStack` can't share space unevenly.
struct WeightedHStack: Layout {
    var weights: [CGFloat]
    var spacing: CGFloat = 16

    private func widths(_ total: CGFloat, count: Int) -> [CGFloat] {
        let avail = total - spacing * CGFloat(max(0, count - 1))
        let sum = weights.prefix(count).reduce(0, +)
        return (0..<count).map { avail * weights[$0] / sum }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let total = proposal.width ?? 600
        let ws = widths(total, count: subviews.count)
        let h = zip(subviews, ws).map { $0.sizeThatFits(.init(width: $1, height: nil)).height }.max() ?? 0
        return CGSize(width: total, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (view, w) in zip(subviews, widths(bounds.width, count: subviews.count)) {
            view.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading, proposal: .init(width: w, height: nil))
            x += w + spacing
        }
    }
}

/// The design's list row: 60 pt, a leading avatar, a bold title over a 12 pt subtitle, a trailing
/// accessory; connected groups round the outer corners to 14 and the inner ones to 5.
struct DSListRow<Leading: View, Trailing: View>: View {
    let title: String
    var titleFont: Font = .system(size: 13.5, weight: .semibold)
    let subtitle: String
    var subtitleColor: Color = M3.onSurfaceVariant
    var position: M3GroupPosition = .single
    var interactive = false
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing
    @State private var hovering = false

    private var shape: UnevenRoundedRectangle { position.shape(axis: .vertical, big: 14, small: 5) }

    var body: some View {
        HStack(spacing: 12) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(titleFont).foregroundStyle(M3.onSurface).lineLimit(1).truncationMode(.middle)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(subtitleColor).lineLimit(1)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 14)
        .frame(height: 60)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(hovering && interactive ? M3.surfaceContainerHigh : M3.surfaceContainer))
        .contentShape(shape)
        .onHover { hovering = $0 }
    }
}

/// A round avatar with an SF Symbol (34 pt in lists, 30 in the menu panel).
struct DSCircleIcon: View {
    let icon: String
    var size: CGFloat = 34
    var fill: Color = M3.surfaceContainerHigh
    var ink: Color = M3.onSurfaceVariant
    var body: some View {
        Circle().fill(fill).frame(width: size, height: size)
            .overlay(Image(systemName: icon).font(.system(size: size * 0.45)).foregroundStyle(ink))
    }
}

/// The toolbar's buttons: a 32 pt pill, tonal or primary.
struct DSToolbarButton: View {
    enum Style { case tonal, primary }
    let icon: String
    var title: String? = nil
    var style: Style = .tonal
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 14))
                if let title { Text(title).font(.system(size: 13, weight: .medium)) }
            }
            .foregroundStyle(style == .primary ? M3.onPrimary : M3.onSurface)
            .padding(.leading, title == nil ? 0 : 11).padding(.trailing, title == nil ? 0 : 14)
            .frame(width: title == nil ? 32 : nil, height: 32)
            .background(Capsule().fill(style == .primary ? M3.primary : M3.surfaceContainer))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}


// MARK: - Settings form kit (the design's own controls, used by the Settings window)

/// A titled group: a 13 pt bold header over a rounded card of rows, with an optional footnote.
struct DSSection<Content: View>: View {
    var title: String?
    var footnote: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(M3.onSurface)
            }
            VStack(spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(M3.surfaceContainer))
            if let footnote {
                Text(footnote).font(.system(size: 11.5)).foregroundStyle(M3.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 2)
            }
        }
    }
}

/// One row of a `DSSection`: a label (+ optional note) and a trailing control. Rows are separated
/// by a hairline; pass `divider: false` on the first.
struct DSRow<Trailing: View>: View {
    let label: String
    var note: String? = nil
    var noteColor: Color = M3.onSurfaceVariant
    var labelColor: Color = M3.onSurface
    var dot: Color? = nil
    var divider = true
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            if divider { Rectangle().fill(M3.outlineVariant).frame(height: 0.5).padding(.leading, 14) }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if let dot { Circle().fill(dot).frame(width: 8, height: 8) }
                        Text(label).font(.system(size: 13)).foregroundStyle(labelColor).lineLimit(1)
                    }
                    if let note {
                        Text(note).font(.system(size: 11.5)).foregroundStyle(noteColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                trailing
            }
            .padding(.horizontal, 14).padding(.vertical, note == nil ? 10 : 9)
            .frame(minHeight: note == nil ? 40 : 50)
        }
    }
}

extension DSRow where Trailing == EmptyView {
    init(label: String, note: String? = nil, divider: Bool = true) {
        self.init(label: label, note: note, divider: divider) { EmptyView() }
    }
}

/// The design's 34 × 20 switch.
struct DSSwitch: View {
    @Binding var isOn: Bool
    var body: some View {
        Button { withAnimation(.snappy(duration: 0.18)) { isOn.toggle() } } label: {
            Capsule().fill(isOn ? M3.primary : M3.switchOff).frame(width: 34, height: 20)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle().fill(isOn ? M3.onPrimary : Color.white).frame(width: 16, height: 16).padding(2)
                }
        }
        .buttonStyle(.plain)
    }
}

/// A 24 pt button: tonal (the default), primary, or destructive text.
struct DSSmallButton: View {
    enum Style { case tonal, primary, destructive }
    let title: String
    var style: Style = .tonal
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .medium))
                .foregroundStyle(style == .primary ? M3.onPrimary : (style == .destructive ? M3.error : M3.onSurface))
                .padding(.horizontal, 10).frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(style == .primary ? M3.primary : M3.field))
                .opacity(enabled ? 1 : 0.45)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// A 24 pt text field on the field fill.
struct DSField: View {
    @Binding var text: String
    var prompt = ""
    var width: CGFloat = 200
    var secure = false
    var invalid = false

    var body: some View {
        Group {
            if secure { SecureField("", text: $text, prompt: Text(prompt).foregroundColor(M3.outline)) }
            else { TextField("", text: $text, prompt: Text(prompt).foregroundColor(M3.outline)) }
        }
        .textFieldStyle(.plain).font(.system(size: 13))
        .foregroundStyle(invalid ? M3.error : M3.onSurface)
        .padding(.horizontal, 8).frame(width: width, height: 24)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(M3.field))
    }
}

/// A segmented control (Near / Balanced / Far): a tonal track with the selected segment raised.
struct DSSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                Button { selection = option } label: {
                    Text(label(option)).font(.system(size: 12.5, weight: selection == option ? .medium : .regular))
                        .foregroundStyle(selection == option ? M3.onSurface : M3.onSurfaceVariant)
                        .padding(.horizontal, 10).frame(height: 22)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(selection == option ? M3.field : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(M3.surfaceContainerHigh))
    }
}

/// A pop-up menu shown as the design's field-coloured pill with an up/down glyph.
struct DSPopup<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in Button(label(option)) { selection = option } }
        } label: {
            HStack(spacing: 8) {
                Text(label(selection)).font(.system(size: 13)).foregroundStyle(M3.onSurface)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(M3.onSurfaceVariant)
            }
            .padding(.horizontal, 8).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(M3.field))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }
}
