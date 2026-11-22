import SwiftUI

/// TikToks, Reels and links shared into Plandit, each turned into a place on the map.
struct SavedSheet: View {
    @Environment(PlanditStore.self) private var store
    @Environment(SheetRouter.self) private var router
    /// Where + puts a place: your own plan, or the group plan picked in Today.
    @TodayContext private var today
    @State private var query = SavedListQuery()
    /// Counts + taps that added a place, for the success haptic.
    @State private var adds = 0
    @State private var isAddingLink = false
    /// An invite link pasted in "Add a link": its join sheet opens once that sheet has gone.
    @State private var inviteFromLink: String?
    @AppStorage("plandit.saved.showShareTip") private var showShareTip = true

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Saved", subtitle: subtitle) {
                CircleIconButton(.plus, label: "Add a link") { isAddingLink = true }
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.sm) {
                    if store.saved.isEmpty {
                        EmptyState(
                            icon: .bookmark,
                            title: "Nothing saved yet",
                            message: "Share a TikTok or Reel to Plandit, or paste a link."
                        ) {
                            Button {
                                isAddingLink = true
                            } label: {
                                HStack(spacing: Space.xs) {
                                    Icon(.clipboardPaste, size: 18)
                                    Text("Paste a link")
                                }
                            }
                            .buttonStyle(.secondary)
                        }
                        .padding(.top, Space.md)
                        .transition(.opacity)
                    } else {
                        if showShareTip {
                            ShareTipCard(onPaste: { isAddingLink = true }, onDismiss: { withAnimation(.snappy) { showShareTip = false } })
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }

                        if !groups.isEmpty {
                            categoryPictures
                        }

                        HStack(spacing: Space.xs) {
                            SavedMenuControl(
                                title: query.filterTitle,
                                accessibilityName: "Filter",
                                isActive: query.filter != .all,
                                identifier: "saved-filter",
                                selection: $query.filter,
                                options: SavedFilter.allCases,
                                optionLabel: \.label
                            )
                            SavedMenuControl(
                                title: query.sortTitle,
                                accessibilityName: "Sort",
                                isActive: query.sort != .newest,
                                identifier: "saved-sort",
                                selection: $query.sort,
                                options: SavedSort.allCases,
                                optionLabel: \.label
                            )
                            Spacer(minLength: 0)
                        }

                        VStack(spacing: 0) {
                            ForEach(posts) { post in
                                SavedListRow(post: post, isInToday: today.contains(post)) {
                                    add(post)
                                }
                                .contextMenu {
                                    SavedPostActions(post: post) { add(post) }
                                }
                                .transition(.opacity.combined(with: .move(edge: .leading)))
                                Hairline()
                            }
                        }

                        if posts.isEmpty {
                            Text(emptyFilterMessage)
                                .font(.bodyText)
                                .foregroundStyle(.inkMuted)
                                .padding(.vertical, Space.lg)
                                .transition(.opacity)
                        }
                    }
                }
                .padding(.horizontal, Space.lg)
                .padding(.bottom, Space.lg)
                .animation(.snappy(duration: 0.35), value: posts.map(\.id))
                .animation(.snappy(duration: 0.35), value: store.saved.map(\.status))
            }
            .scrollIndicators(.hidden)
            .hiddenWhenSheetCollapsed()
        }
        .background(Color.surface)
        .sensoryFeedback(.success, trigger: adds)
        // New shares show on top: back to all places, newest first (PRC-1).
        .onChange(of: router.sharesShown) {
            withAnimation(.snappy(duration: 0.3)) { query = SavedListQuery() }
        }
        // Once a selected category's last place is gone, forget the selection for good, so a new
        // place of that kind doesn't switch the filter back on by itself.
        .onChange(of: groups.map(\.group)) {
            query.forgetMissingGroup(in: store.saved)
        }
        .onAppear { query.forgetMissingGroup(in: store.saved) }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $isAddingLink, onDismiss: openInviteFromLink) {
            AddLinkSheet(onSaved: { id in
                // Land on the new post so the user watches it get mapped.
                router.savedPath = [id]
            }, onInvite: { inviteFromLink = $0 })
        }
    }

    private func openInviteFromLink() {
        guard let token = inviteFromLink else { return }
        inviteFromLink = nil
        router.join(invite: token)
    }

    private var categoryPictures: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Space.xs) {
                ForEach(groups, id: \.group) { entry in
                    CategoryPicture(
                        group: entry.group,
                        accessibilityLabel: entry.accessibilityLabel,
                        isSelected: activeQuery.group == entry.group
                    ) {
                        withAnimation(.snappy(duration: 0.3)) {
                            query = activeQuery
                            query.toggle(entry.group)
                        }
                    }
                }
            }
            .padding(.horizontal, Space.lg)
        }
        .scrollIndicators(.hidden)
        .padding(.horizontal, -Space.lg)
    }

    /// + on a row: adds the place to today's plan. If that can't happen, open the post instead, so
    /// the tap never looks like it did nothing.
    private func add(_ post: SavedPost) {
        var added: UUID?
        withAnimation(.snappy) { added = today.add(post) }
        if added != nil {
            adds += 1
            // The + button goes away, so VoiceOver focus has nowhere to land: say what happened.
            AccessibilityNotification.Announcement("Added to \(today.planName)").post()
        } else {
            router.savedPath = [post.id]
        }
    }

    private var subtitle: String {
        let mapped = store.saved.filter(\.isMappable).count
        let pending = store.saved.filter {
            [.processing, .needsEvidence, .needsConfirmation].contains($0.status)
        }.count
        let places = mapped == 1 ? "1 place" : "\(mapped) places"
        return pending > 0 ? "\(places) · \(pending) to finish" : places
    }

    private var groups: [SavedListQuery.GroupCount] { SavedListQuery.groups(in: store.saved) }

    /// The query, minus a selected category whose last place was removed.
    private var activeQuery: SavedListQuery { query.resolved(for: store.saved) }

    private var posts: [SavedPost] { activeQuery.apply(to: store.saved) }

    private var emptyFilterMessage: String {
        switch (activeQuery.group, activeQuery.filter) {
        case (.some, .freeOnly): "No free places in this category yet."
        case (.none, .freeOnly): "No free places saved yet."
        default: "No saved places in this category yet."
        }
    }
}

/// Context-menu actions for a saved post.
struct SavedPostActions: View {
    let post: SavedPost
    /// Adds the place the way the row's + does, with the same haptic and announcement.
    let onAdd: () -> Void
    @Environment(PlanditStore.self) private var store
    @TodayContext private var today

    var body: some View {
        // Offered exactly when the row shows +, so a needs-review place gets checked first.
        if SavedRowTrailing(post: post, isInToday: today.contains(post)) == .add {
            Button(action: onAdd) {
                Label("Add to \(today.planName)", image: "Icons/plus")
            }
        }
        if post.status == .failed {
            Button {
                withAnimation(.snappy) { store.retryExtraction(post.id) }
            } label: {
                Label("Try again", image: "Icons/loader-circle")
            }
        }
        Button(role: .destructive) {
            withAnimation(.snappy) { store.removePost(post.id) }
        } label: {
            Label("Remove from saved", image: "Icons/trash-2")
        }
    }
}

private struct ShareTipCard: View {
    let onPaste: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text("Save from TikTok and Instagram").font(.cardHeading).foregroundStyle(.ink)
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
