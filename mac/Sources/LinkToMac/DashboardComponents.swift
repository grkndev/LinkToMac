import SwiftUI
import AppKit

/// Material 3 (Expressive) design tokens + components for the dashboard window. The dark scheme is
/// **sampled from the Jetpack-Compose mobile app** (`local-assets/Screenshot_*.jpg`) so the Mac reads
/// as the same product: a muted-blue tonal scheme over a near-black surface, large rounded tonal
/// cards, circular tonal icon badges, two-line list items, a light-blue primary accent, and the M3
/// type scale. **Phase 1: placeholder data.**

/// Routes shown on the dashboard's sub-screen stack.
enum DashRoute: Hashable {
    case clipboard
    case settings
    case relay
    case about
}

/// M3 dark colour roles (sampled) + shape/type helpers.
enum M3 {
    // MARK: Color roles (dark)
    static let surface = Color(m3: 0x0C0E12)                 // window background (near-black)
    static let surfaceContainerLowest = Color(m3: 0x090A0E)
    static let surfaceContainerLow = Color(m3: 0x14161B)     // recessive
    static let surfaceContainer = Color(m3: 0x1B1E24)        // cards, rows, chips (idle)
    static let surfaceContainerHigh = Color(m3: 0x252931)    // hover / pressed / raised
    static let surfaceContainerHighest = Color(m3: 0x30343C)
    static let primary = Color(m3: 0xA8C7FA)                 // switches, links, key accents
    static let onPrimary = Color(m3: 0x0A305F)
    static let primaryContainer = Color(m3: 0x274777)
    static let onPrimaryContainer = Color(m3: 0xD7E3FF)
    static let secondaryContainer = Color(m3: 0x3A4456)      // tonal icon badges, chips, selected
    static let onSecondaryContainer = Color(m3: 0xDBE6F8)    // icon/label on secondaryContainer
    static let onSurface = Color(m3: 0xE4E2E9)              // bold titles, primary labels
    static let onSurfaceVariant = Color(m3: 0xAAAEB9)        // subtitles, idle labels
    static let outline = Color(m3: 0x8B919C)
    static let outlineVariant = Color(m3: 0x3C424A)         // dividers, hairlines
    static let success = Color(m3: 0x4ADE80)               // connected dot
    static let error = Color(m3: 0xFFB4AB)                 // destructive label
    static let errorContainer = Color(m3: 0x93000A)        // destructive badge fill

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
