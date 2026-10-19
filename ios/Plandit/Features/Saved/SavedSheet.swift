import SwiftUI

/// TikToks, Reels and links shared into Plandit, each turned into a place on the map.
struct SavedSheet: View {
    @Environment(PlanditStore.self) private var store
    @State private var filter: PlaceCategory?
    @State private var isAddingLink = false
    @AppStorage("plandit.saved.showShareTip") private var showShareTip = true

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Saved", subtitle: subtitle) {
                CircleIconButton(.plus, label: "Add a link") { isAddingLink = true }
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.sm) {
                    if showShareTip {
                        ShareTipCard(onPaste: { isAddingLink = true }, onDismiss: { showShareTip = false })
                    }

                    ScrollView(.horizontal) {
                        HStack(spacing: Space.xs) {
                            Chip(title: "All", isSelected: filter == nil) { filter = nil }
                            ForEach(categories) { category in
                                Chip(title: category.label, icon: category.icon, isSelected: filter == category) {
                                    filter = filter == category ? nil : category
                                }
                            }
                        }
                    }
                    .scrollIndicators(.hidden)

                    ForEach(posts) { post in
                        NavigationLink(value: post.id) {
                            SavedPostRow(post: post, isInToday: store.isInToday(post))
                        }
                        .buttonStyle(.plain)
                        Hairline()
                    }

                    if posts.isEmpty {
                        Text("No saved places in this category yet.")
                            .font(.bodyText)
                            .foregroundStyle(.inkMuted)
                            .padding(.vertical, Space.lg)
                    }
                }
                .padding(.horizontal, Space.lg)
                .padding(.bottom, Space.lg)
            }
            .scrollIndicators(.hidden)
            .hiddenWhenSheetCollapsed()
        }
        .background(Color.surface)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $isAddingLink) {
            AddLinkSheet()
        }
    }

    private var subtitle: String {
        let mapped = store.saved.filter(\.isMappable).count
        let pending = store.saved.filter {
            [.processing, .needsEvidence, .needsConfirmation].contains($0.status)
        }.count
        return pending > 0 ? "\(mapped) places · \(pending) to finish" : "\(mapped) places"
    }

    /// Only categories that actually have saved places.
    private var categories: [PlaceCategory] {
        let present = Set(store.saved.compactMap { $0.place?.category })
        return PlaceCategory.allCases.filter(present.contains)
    }

    private var posts: [SavedPost] {
        guard let filter else { return store.saved }
        return store.saved.filter { $0.place?.category == filter }
    }
}

private struct ShareTipCard: View {
    let onPaste: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text("Save from TikTok and Reels").font(.cardHeading).foregroundStyle(.ink)
                    Text("Tap Share in TikTok or Instagram, then choose Plandit. We'll add the place to your map with its price and hours.")
                        .font(.bodyText)
                        .foregroundStyle(.inkMuted)
                }
                Spacer(minLength: Space.xs)
                Button(action: onDismiss) {
                    Icon(.x, size: 18)
                        .foregroundStyle(.inkMuted)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss tip")
                .padding(.top, -Space.sm)
                .padding(.trailing, -Space.sm)
            }
            Button(action: onPaste) {
                HStack(spacing: Space.xs) {
                    Icon(.clipboardPaste, size: 18)
                    Text("Paste a link")
                }
            }
            .buttonStyle(.secondary)
        }
        .planditCard()
    }
}

struct SavedPostRow: View {
    let post: SavedPost
    let isInToday: Bool

    var body: some View {
        HStack(spacing: Space.sm) {
            SavedThumbnail(post: post)

            VStack(alignment: .leading, spacing: 2) {
                Text(post.title)
                    .font(.manrope(.bold, size: 16))
                    .foregroundStyle(post.place == nil ? Color.inkMuted : Color.ink)
                    .lineLimit(1)
                if let place = post.place {
                    Text([place.category.label, place.neighborhood, post.estimatedCost?.dollarsText].compactMap { $0 }.joined(separator: " · "))
                        .font(.metadata)
                        .foregroundStyle(.inkMuted)
                        .lineLimit(1)
                }
                Text(post.sourceLine)
                    .font(.metadata)
                    .foregroundStyle(.inkMuted)
                    .lineLimit(1)
            }

            Spacer(minLength: Space.xs)
            SavedStatus(post: post, isInToday: isInToday)
        }
        .padding(.vertical, Space.xs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct SavedThumbnail: View {
    let post: SavedPost
    var size: CGFloat = 52

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(Color.canvas)
            if let url = post.thumbnailURL {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    fallbackIcon
                }
            } else {
                fallbackIcon
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Color.border))
        .accessibilityHidden(true)
    }

    private var fallbackIcon: some View {
        Icon(post.place?.category.icon ?? .video, size: size * 0.42).foregroundStyle(.ink)
    }
}

/// Trailing status. Red appears only for the "unavailable" case, and always with text.
private struct SavedStatus: View {
    let post: SavedPost
    let isInToday: Bool

    var body: some View {
        Group {
            switch post.status {
            case .processing:
                HStack(spacing: Space.xxs) {
                    ProgressView().controlSize(.small)
                    Text("Mapping")
                }
                .foregroundStyle(.inkMuted)
            case .needsEvidence:
                HStack(spacing: Space.xxs) {
                    Icon(.circleAlert, size: 16)
                    Text("Add details")
                }
                .foregroundStyle(.ink)
            case .needsConfirmation:
                HStack(spacing: Space.xxs) {
                    Icon(.mapPin, size: 16)
                    Text("Confirm")
                }
                .foregroundStyle(.emeraldDeep)
            case .needsReview:
                HStack(spacing: Space.xxs) {
                    Icon(.circleAlert, size: 16)
                    Text("Review")
                }
                .foregroundStyle(.ink)
            case .failed:
                HStack(spacing: Space.xxs) {
                    Icon(.circleAlert, size: 16)
                    Text("Not found")
                }
                .foregroundStyle(.error)
            case .ready where isInToday:
                HStack(spacing: Space.xxs) {
                    Icon(.circleCheck, size: 16)
                    Text("In plan")
                }
                .foregroundStyle(.emeraldDeep)
            case .ready:
                Icon(.chevronRight, size: 16).foregroundStyle(.inkMuted)
            }
        }
        .font(.label)
    }
}
