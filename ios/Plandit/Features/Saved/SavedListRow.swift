import SwiftUI

/// One slim Saved row: the name, "Category · Neighborhood" (plus "Free" and a star), then In plan,
/// a + that adds the place to today's plan, or the post's status word, then a chevron.
struct SavedListRow: View {
    let post: SavedPost
    let isInToday: Bool
    let onAdd: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var trailing: SavedRowTrailing { SavedRowTrailing(post: post, isInToday: isInToday) }

    var body: some View {
        HStack(spacing: Space.xs) {
            NavigationLink(value: post.id) {
                summary
                    .padding(.vertical, Space.sm)
                    .contentShape(Rectangle())
                    .accessibilityElement(children: .combine)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("saved-row-\(post.id.uuidString)")

            if trailing == .add {
                Button(action: onAdd) {
                    Icon(.plus, size: 16)
                        .foregroundStyle(.emeraldDeep)
                        .frame(width: 28, height: 28)
                        .overlay(Circle().strokeBorder(Color.emeraldDeep, lineWidth: 1.5))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add \(post.title) to today's plan")
                .transition(.scale.combined(with: .opacity))
            }

            // A second way into the post; VoiceOver already has the row itself.
            NavigationLink(value: post.id) {
                Icon(.chevronRight, size: 16)
                    .foregroundStyle(.inkMuted)
                    .frame(minWidth: 16, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .animation(.snappy(duration: 0.3), value: post.status)
        .animation(.snappy(duration: 0.3), value: isInToday)
    }

    /// Name and details, with the status beside them, or under them at accessibility text sizes,
    /// so a status never squeezes the name (W-9).
    @ViewBuilder private var summary: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.xxs))
            : AnyLayout(HStackLayout(spacing: Space.xs))
        layout {
            VStack(alignment: .leading, spacing: 2) {
                Text(post.title)
                    .font(.manrope(.bold, size: 16))
                    .foregroundStyle(post.place == nil ? Color.inkMuted : Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = post.savedRowDetail {
                    HStack(spacing: Space.xxs) {
                        Text(detail)
                            .lineLimit(1)
                        if post.isFreeInSaved {
                            Icon(.star, size: 12)
                                .foregroundStyle(.emeraldDeep)
                        }
                    }
                    .font(.metadata)
                    .foregroundStyle(.inkMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            if let text = trailing.text {
                SavedRowStatus(trailing: trailing, status: post.status, text: text)
                    .fixedSize()
                    .transition(.scale.combined(with: .opacity))
            }
        }
    }
}

/// In plan as an emerald pill; status words with their icon. Red appears only for "Couldn't find
/// it", and always with text.
private struct SavedRowStatus: View {
    let trailing: SavedRowTrailing
    let status: ExtractionStatus
    let text: String

    var body: some View {
        Group {
            if trailing == .inPlan {
                HStack(spacing: Space.xxs) {
                    Icon(.check, size: 14)
                    Text(text)
                }
                .foregroundStyle(.emeraldDeep)
                .padding(.horizontal, Space.xs)
                .padding(.vertical, Space.xxs)
                .background(Color.emeraldTint, in: Capsule())
            } else {
                HStack(spacing: Space.xxs) {
                    switch status {
                    case .processing:
                        ProgressView().controlSize(.small)
                    case .needsConfirmation:
                        Icon(.mapPin, size: 16)
                    default:
                        Icon(.circleAlert, size: 16)
                    }
                    Text(text)
                }
                .foregroundStyle(color)
            }
        }
        .font(.label)
    }

    private var color: Color {
        switch status {
        case .processing: .inkMuted
        case .needsConfirmation: .emeraldDeep
        case .failed: .error
        default: .ink
        }
    }
}

/// A watercolor category picture with its name. Selected: pale emerald behind it, emerald label.
struct CategoryPicture: View {
    let group: SavedCategoryGroup
    let accessibilityLabel: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: Space.xxs) {
                Image(group.imageName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 68, height: 68)
                Text(group.label)
                    .font(.label)
                    .foregroundStyle(isSelected ? Color.emeraldDeep : Color.ink)
                    .lineLimit(1)
            }
            .padding(.horizontal, Space.xxs)
            .padding(.vertical, Space.xs)
            .frame(minWidth: 84)
            .background(isSelected ? Color.emeraldTint : Color.clear, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(isSelected ? Color.emeraldDeep : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("saved-category-\(group.rawValue)")
    }
}

/// Filter and Sort: an outlined control with a chevron that opens a menu of choices. A non-default
/// choice shows in the label and tints the control.
struct SavedMenuControl<Option: Hashable>: View {
    let title: String
    let accessibilityName: String
    let isActive: Bool
    let identifier: String
    @Binding var selection: Option
    let options: [Option]
    let optionLabel: (Option) -> String

    var body: some View {
        Menu {
            Picker(accessibilityName, selection: $selection.animation(.snappy(duration: 0.3))) {
                ForEach(options, id: \.self) { option in
                    Text(optionLabel(option)).tag(option)
                }
            }
        } label: {
            HStack(spacing: Space.xxs) {
                Text(title).font(.label)
                Icon(.chevronDown, size: 16)
            }
            .foregroundStyle(isActive ? Color.emeraldDeep : Color.ink)
            .padding(.horizontal, Space.sm)
            .frame(minHeight: 36)
            .background(isActive ? Color.emeraldTint : Color.surface, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .strokeBorder(isActive ? Color.emeraldDeep : Color.border)
            )
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .menuOrder(.fixed)
        .accessibilityLabel(accessibilityName)
        .accessibilityValue(optionLabel(selection))
        .accessibilityIdentifier(identifier)
    }
}
