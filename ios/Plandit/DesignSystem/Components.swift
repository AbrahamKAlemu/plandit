import SwiftUI

/// Pinned header at the top of each sheet tab; it stays visible at the peek detent.
struct SheetHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: Space.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.pageHeading)
                    .foregroundStyle(.ink)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(.metadata)
                        .foregroundStyle(.inkMuted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.horizontal, Space.lg)
        .padding(.top, Space.lg)
        .padding(.bottom, Space.sm)
    }
}

/// 44pt circular icon button for header actions.
struct CircleIconButton: View {
    let icon: Lucide
    let label: String
    let action: () -> Void

    init(_ icon: Lucide, label: String, action: @escaping () -> Void) {
        self.icon = icon
        self.label = label
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            CircleIconLabel(icon: icon)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

struct CircleIconLabel: View {
    let icon: Lucide

    var body: some View {
        Icon(icon, size: 20)
            .foregroundStyle(.ink)
            .frame(width: 44, height: 44)
            .background(Color.canvas, in: Circle())
            .overlay(Circle().strokeBorder(Color.border))
    }
}

/// Compact interactive choice. Selected uses a black fill, per the style guide.
struct Chip: View {
    let title: String
    var icon: Lucide?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Icon(icon, size: 16) }
                Text(title).font(.label)
            }
            .foregroundStyle(isSelected ? Color.onInk : Color.ink)
            .padding(.horizontal, Space.sm)
            .frame(minHeight: 36)
            .background(isSelected ? Color.ink : Color.surface, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(isSelected ? Color.ink : Color.border))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Icon + metadata text, e.g. a price, duration or distance.
struct MetaLabel: View {
    let icon: Lucide
    let text: String

    init(_ icon: Lucide, _ text: String) {
        self.icon = icon
        self.text = text
    }

    var body: some View {
        HStack(spacing: Space.xxs) {
            Icon(icon, size: 14)
            Text(text)
        }
        .font(.metadata)
        .foregroundStyle(.inkMuted)
    }
}

/// Stop number: emerald circle with a black numeral. Done stops go white; the current stop gets an ink ring.
struct StopBadge: View {
    let number: Int
    let status: StopStatus
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            Circle().fill(status == .done ? Color.surface : Color.emerald)
            switch status {
            case .done: Circle().strokeBorder(Color.ink, lineWidth: 1.5)
            case .now: Circle().strokeBorder(Color.ink, lineWidth: 2.5)
            case .upcoming: EmptyView()
            }
            Text("\(number)")
                .font(.manrope(.extraBold, size: size * 0.46))
                .foregroundStyle(status == .done ? Color.ink : Color.onEmerald)
        }
        .frame(width: size, height: size)
        .animation(.snappy(duration: 0.3), value: status)
        .accessibilityElement()
        .accessibilityLabel("Stop \(number), \(status.label)")
    }
}

/// Status never relies on color alone: always text, plus an icon for done.
struct StopStatusTag: View {
    let status: StopStatus

    var body: some View {
        switch status {
        case .done:
            HStack(spacing: Space.xxs) {
                Icon(.circleCheck, size: 14)
                Text("Done")
            }
            .font(.label)
            .foregroundStyle(.inkMuted)
        case .now:
            Text("Now")
                .font(.manrope(.bold, size: 13))
                .foregroundStyle(.onEmerald)
                .padding(.horizontal, Space.xs)
                .padding(.vertical, 2)
                .background(Color.emerald, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        case .upcoming:
            EmptyView()
        }
    }
}

struct SectionTitle: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.cardHeading)
            .foregroundStyle(.ink)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Icon, small label, and value, grouped tightly for detail screens.
struct FactRow: View {
    let icon: Lucide
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: Space.sm) {
            Icon(icon, size: 18)
                .foregroundStyle(.ink)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.metadata).foregroundStyle(.inkMuted)
                Text(value).font(.bodyText).foregroundStyle(.ink)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

struct Hairline: View {
    var body: some View {
        Rectangle().fill(Color.border).frame(height: 1)
    }
}

extension EnvironmentValues {
    /// True while the sheet sits at its peek detent, where only the header and tab bar should show.
    @Entry var isSheetCollapsed = false
}

/// Hides a sheet's scrolling body at the peek detent so nothing half-shows above the tab bar.
private struct HiddenWhenSheetCollapsed: ViewModifier {
    @Environment(\.isSheetCollapsed) private var isCollapsed

    func body(content: Content) -> some View {
        content
            .opacity(isCollapsed ? 0 : 1)
            .allowsHitTesting(!isCollapsed)
            .accessibilityHidden(isCollapsed)
            .animation(.easeOut(duration: 0.2), value: isCollapsed)
    }
}

extension View {
    func hiddenWhenSheetCollapsed() -> some View {
        modifier(HiddenWhenSheetCollapsed())
    }

    /// White surface, 1px border, 16pt radius. No shadow: shadows are reserved for floating sheets.
    func planditCard(padding: CGFloat = Space.md) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Color.border))
    }
}

extension LegState {
    /// Ink for structure, emerald for the active leg, muted for legs already traveled.
    var color: Color {
        switch self {
        case .completed: .inkMuted
        case .active: .emerald
        case .upcoming: .ink
        }
    }

    var lineWidth: CGFloat {
        switch self {
        case .completed: 4
        case .active: 7
        case .upcoming: 5
        }
    }

    var opacity: Double {
        switch self {
        case .completed: 0.6
        case .active: 1
        case .upcoming: 0.9
        }
    }
}

/// What a sheet shows when a section has nothing in it yet: icon, title, one line, and the next step.
struct EmptyState<Action: View>: View {
    let icon: Lucide
    let title: String
    let message: String
    @ViewBuilder var action: () -> Action

    var body: some View {
        VStack(spacing: Space.sm) {
            Icon(icon, size: 26)
                .foregroundStyle(.ink)
                .frame(width: 56, height: 56)
                .background(Color.canvas, in: Circle())
                .overlay(Circle().strokeBorder(Color.border))
            Text(title)
                .font(.cardHeading)
                .foregroundStyle(.ink)
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .font(.bodyText)
                .foregroundStyle(.inkMuted)
                .multilineTextAlignment(.center)
            action()
                .padding(.top, Space.xs)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.lg)
        .padding(.horizontal, Space.md)
    }
}
