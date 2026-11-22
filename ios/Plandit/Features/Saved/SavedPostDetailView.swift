import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct SavedPostDetailView: View {
    let postID: UUID
    @Environment(PlanditStore.self) private var store
    @Environment(SheetRouter.self) private var router
    /// Where "Add to today's plan" goes: your own plan, or the group plan picked in Today.
    @TodayContext private var today
    @Environment(\.dismiss) private var dismiss
    @State private var isSearchingForPlace = false
    @State private var searchName = ""
    @State private var searchAddress = ""
    @State private var didConfirmPlace = false
    @State private var selectedVideo: PhotosPickerItem?
    @State private var isChoosingVideo = false
    @State private var isProcessingVideo = false
    @State private var videoErrorMessage: String?

    var body: some View {
        if let post = store.post(id: postID) {
            let isInToday = today.contains(post)
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    switch post.status {
                    case .processing:
                        // What was shared, while Plandit looks for the place (PRC-2).
                        SourceCard(post: post)
                        FindingPlaceCard(
                            phrase: post.platform.postPhrase,
                            startedAt: store.findingStartedAt[post.id]
                        )
                        .transition(.opacity)
                    case .needsEvidence, .failed:
                        couldNotPlace(post)
                            .transition(.opacity)
                    case .needsConfirmation:
                        CandidateList(
                            post: post,
                            onConfirm: { candidateID in
                                if store.confirm(postID: post.id, candidateID: candidateID) {
                                    didConfirmPlace = true
                                }
                            },
                            onSearch: {
                                isSearchingForPlace = true
                            }
                        )
                        if isSearchingForPlace {
                            PlaceSearchEditor(name: $searchName, address: $searchAddress) {
                                isSearchingForPlace = false
                                search(post)
                            }
                        }
                    case .ready, .needsReview:
                        if let place = post.place {
                            PlaceSummary(post: post, place: place)
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                    }

                    if post.isMappable || didConfirmPlace {
                        VStack(spacing: Space.sm) {
                            if post.isMappable {
                                if isInToday {
                                    HStack(spacing: Space.xs) {
                                        Icon(.circleCheck, size: 18)
                                        Text("In \(today.planName)")
                                    }
                                    .font(.label)
                                    .foregroundStyle(.emeraldDeep)
                                    .frame(maxWidth: .infinity, minHeight: 48)
                                    .transition(.scale(scale: 0.9).combined(with: .opacity))

                                    TodayPlacement(postID: post.id)

                                    Button {
                                        router.show(.today)
                                    } label: {
                                        HStack(spacing: Space.xs) {
                                            Icon(.route, size: 18)
                                            Text("View \(today.planName)")
                                        }
                                    }
                                    .buttonStyle(.secondary)
                                    .transition(.opacity)
                                } else {
                                    Button {
                                        withAnimation(.snappy) { _ = today.add(post) }
                                    } label: {
                                        HStack(spacing: Space.xs) {
                                            Icon(.plus, size: 18)
                                            Text("Add to \(today.planName)")
                                        }
                                    }
                                    .buttonStyle(.primary)
                                    .disabled(!today.canEdit)
                                    .transition(.opacity)
                                }
                            }

                            if didConfirmPlace {
                                Button("Confirm") {
                                    dismiss()
                                }
                                .buttonStyle(.secondary)
                                .accessibilityIdentifier("finish-place-confirmation")
                            }
                        }
                    }

                    if post.status != .processing {
                        SourceCard(post: post)
                    }

                    // Last on the screen, away from the main actions (W-13).
                    Button(role: .destructive) {
                        dismiss()
                        withAnimation(.snappy) { store.removePost(post.id) }
                    } label: {
                        Text("Remove from saved")
                            .font(.label)
                            .foregroundStyle(.error)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .accessibilityIdentifier("remove-saved-place")
                }
                .padding(Space.lg)
                .animation(.snappy(duration: 0.35), value: post.status)
                .animation(.snappy(duration: 0.35), value: isInToday)
            }
            .background(Color.surface)
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: selectedVideo) { _, item in
                guard let item else { return }
                isProcessingVideo = true
                videoErrorMessage = nil
                Task {
                    do {
                        guard let video = try await item.loadTransferable(type: PickedVideo.self) else {
                            throw VideoEvidenceError.unsupportedType
                        }
                        defer { try? FileManager.default.removeItem(at: video.url) }
                        try await store.processVideo(postID: post.id, fileURL: video.url)
                    } catch {
                        videoErrorMessage = error.localizedDescription
                    }
                    selectedVideo = nil
                    isProcessingVideo = false
                }
            }
            .fileImporter(
                isPresented: $isChoosingVideo,
                allowedContentTypes: [.movie],
                allowsMultipleSelection: false
            ) { result in
                guard case .success(let urls) = result, let url = urls.first else {
                    if case .failure(let error) = result {
                        videoErrorMessage = error.localizedDescription
                    }
                    return
                }
                processVideo(postID: post.id, at: url)
            }
            .alert(
                "Saved place unavailable",
                isPresented: Binding(
                    get: { store.savedErrorMessage != nil },
                    set: { if !$0 { store.savedErrorMessage = nil } }
                )
            ) {
                Button("OK") { store.savedErrorMessage = nil }
            } message: {
                Text(store.savedErrorMessage ?? "")
            }
            .sensoryFeedback(.success, trigger: isInToday) { _, added in added }
        } else {
            ContentUnavailableView("Removed", image: "Icons/bookmark", description: Text("This post is no longer saved."))
        }
    }

    /// A post Plandit couldn't place: one title, Try again when the lookup failed, a name-or-address
    /// search that starts empty, then the video as the second choice (W-12, PRC-3).
    @ViewBuilder
    private func couldNotPlace(_ post: SavedPost) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text(post.status == .failed ? "We couldn't find a place" : "Add the place")
                .font(.pageHeading)
                .foregroundStyle(.ink)
                .accessibilityAddTraits(.isHeader)
                .fixedSize(horizontal: false, vertical: true)
            Text(post.failureMessage ?? "Search for the place's name or address.")
                .font(.bodyText)
                .foregroundStyle(.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            if post.status == .failed {
                Button("Try again") { withAnimation(.snappy) { store.retryExtraction(post.id) } }
                    .buttonStyle(.secondary)
                    .accessibilityIdentifier("retry-extraction")
            }
        }

        PlaceSearchEditor(name: $searchName, address: $searchAddress, showsHeading: false) {
            search(post)
        }

        videoFallback(for: post)
    }

    private func search(_ post: SavedPost) {
        let query = [searchName, searchAddress]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        guard !query.isEmpty else { return }
        store.submitEvidence(postID: post.id, text: query)
    }

    @ViewBuilder
    private func videoFallback(for post: SavedPost) -> some View {
        if post.platform != .video {
            VStack(alignment: .leading, spacing: Space.sm) {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text("Use the video instead")
                        .font(.cardHeading)
                        .foregroundStyle(.ink)
                    Text("Plandit reads it on this device and deletes the temporary copy.")
                        .font(.bodyText)
                        .foregroundStyle(.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VideoSourceButtons(
                    selection: $selectedVideo,
                    isChoosingFile: $isChoosingVideo,
                    isDisabled: isProcessingVideo,
                    photosIdentifier: "fallback-video-photos",
                    filesIdentifier: "fallback-video-files"
                )

                if isProcessingVideo {
                    HStack(spacing: Space.xs) {
                        ProgressView().controlSize(.small)
                        Text("Reading video…")
                    }
                    .font(.metadata)
                    .foregroundStyle(.inkMuted)
                }

                if let videoErrorMessage {
                    Text(videoErrorMessage)
                        .font(.metadata)
                        .foregroundStyle(.error)
                }
            }
            .planditCard()
        }
    }

    private func processVideo(postID: UUID, at url: URL) {
        isProcessingVideo = true
        videoErrorMessage = nil
        Task {
            do {
                try await store.processVideo(postID: postID, fileURL: url)
            } catch {
                videoErrorMessage = error.localizedDescription
            }
            isProcessingVideo = false
        }
    }
}

/// "Finding the place in this TikTok…", and after 8 s "Still looking. This can take up to a
/// minute." while a sleeping server wakes up (PRC-2).
private struct FindingPlaceCard: View {
    static let slowAfter: TimeInterval = 8
    let phrase: String
    let startedAt: Date?
    @State private var isSlow = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.sm) {
                ProgressView()
                Text("Finding the place in \(phrase)…")
                    .font(.bodyText)
                    .foregroundStyle(.ink)
            }
            if isSlow {
                Text("Still looking. This can take a minute or two.")
                    .font(.metadata)
                    .foregroundStyle(.inkMuted)
                    .accessibilityIdentifier("still-looking")
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .planditCard()
        .accessibilityElement(children: .combine)
        .task {
            let elapsed = startedAt.map { Date().timeIntervalSince($0) } ?? 0
            let wait = max(0, Self.slowAfter - elapsed)
            if wait > 0 {
                try? await Task.sleep(for: .seconds(wait))
            }
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.25)) { isSlow = true }
            AccessibilityNotification.Announcement("Still looking. This can take a minute or two.").post()
        }
    }
}

/// "Choose from Photos" and "Choose from Files", drawn as the same kind of button (W-14).
struct VideoSourceButtons: View {
    @Binding var selection: PhotosPickerItem?
    @Binding var isChoosingFile: Bool
    let isDisabled: Bool
    let photosIdentifier: String
    let filesIdentifier: String

    var body: some View {
        VStack(spacing: Space.sm) {
            PhotosPicker(selection: $selection, matching: .videos, photoLibrary: .shared()) {
                Text("Choose from Photos")
            }
            .buttonStyle(.secondary)
            .disabled(isDisabled)
            .accessibilityIdentifier(photosIdentifier)

            Button("Choose from Files") {
                isChoosingFile = true
            }
            .buttonStyle(.secondary)
            .disabled(isDisabled)
            .accessibilityIdentifier(filesIdentifier)
        }
    }
}

private struct CandidateList: View {
    let post: SavedPost
    let onConfirm: (String) -> Void
    let onSearch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("Places found").font(.sectionHeading).foregroundStyle(.ink)
                Text("Choose the place from \(post.platform.postPhrase) to add it to your map.")
                    .font(.bodyText)
                    .foregroundStyle(.inkMuted)
            }


            ForEach(Array(post.candidates.prefix(3))) { candidate in
                CandidateCard(
                    candidate: candidate,
                    onConfirm: onConfirm
                )
            }

            Button("Not the right one?") {
                onSearch()
            }
            .buttonStyle(.secondary)
            .accessibilityIdentifier("not-right-place")
        }
    }
}

private struct CandidateCard: View {
    let candidate: PlaceCandidate
    let onConfirm: (String) -> Void

    var body: some View {
        Button {
            onConfirm(candidate.id)
        } label: {
            HStack(spacing: Space.sm) {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(candidate.place.name)
                        .font(.manrope(.bold, size: 16))
                        .foregroundStyle(.ink)
                        .lineLimit(1)
                    Text(candidate.place.address)
                        .font(.metadata)
                        .foregroundStyle(.inkMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: Space.xs)
                Icon(.chevronRight, size: 18)
                    .foregroundStyle(.inkMuted)
            }
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .planditCard(padding: Space.sm)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "Confirm \(candidate.place.name), \(candidate.place.address)"
        )
    }
}

private struct PlaceSearchEditor: View {
    @Binding var name: String
    @Binding var address: String
    /// Off where the screen's own title already says what to do (W-12).
    var showsHeading = true
    let onSubmit: () -> Void

    private var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            if showsHeading {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text("Search for the place")
                        .font(.sectionHeading)
                        .foregroundStyle(.ink)
                    Text("Add the name, address, or both.")
                        .font(.bodyText)
                        .foregroundStyle(.inkMuted)
                }
            }

            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Place name").font(.label).foregroundStyle(.ink)
                TextField("Name, like Levain Bakery", text: $name)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("place-search-name")
                    .searchFieldStyle()

                Text("Address").font(.label).foregroundStyle(.ink)
                TextField("Street, neighborhood or city", text: $address)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("place-search-address")
                    .searchFieldStyle()
            }

            Button("Search", action: onSubmit)
                .buttonStyle(.primary)
                .disabled(!canSubmit)
                .accessibilityIdentifier("search-for-place")
        }
        .planditCard()
    }
}

private extension View {
    func searchFieldStyle() -> some View {
        self
            .font(.bodyText)
            .padding(.horizontal, Space.sm)
            .frame(minHeight: 48)
            .background(
                Color.canvas,
                in: RoundedRectangle(cornerRadius: Radius.control)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Radius.control)
                    .strokeBorder(Color.border, lineWidth: 1)
            }
    }
}

private struct PlaceSummary: View {
    let post: SavedPost
    let place: Place
    @State private var isEditingCost = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(place.name).font(.pageHeading).foregroundStyle(.ink)
                Text("\(place.category.label) · \(place.neighborhood)").font(.bodyText).foregroundStyle(.inkMuted)
            }

            if post.status == .needsReview {
                HStack(alignment: .top, spacing: Space.xs) {
                    Icon(.circleAlert, size: 18).foregroundStyle(.ink)
                    Text("Hours weren't listed in the post. Confirm before you go.")
                        .font(.bodyText)
                        .foregroundStyle(.ink)
                }
                .planditCard(padding: Space.sm)
            }

            VStack(alignment: .leading, spacing: Space.md) {
                Button { isEditingCost = true } label: {
                    HStack {
                        FactRow(icon: .wallet, title: costTitle, value: costValue)
                        Icon(.chevronRight, size: 16).foregroundStyle(.inkMuted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Change what this place costs")
                .accessibilityIdentifier("post-cost")
                FactRow(icon: .mapPin, title: "Address", value: place.address)
                FactRow(icon: .clock, title: "Hours", value: place.hours ?? "Not listed")
            }
            .planditCard()
        }
        .sheet(isPresented: $isEditingCost) { PostCostSheet(postID: post.id) }
    }

    private var costTitle: String {
        post.userCost != nil ? "Your estimate" : (post.estimatedCost != nil ? "Estimated cost" : "Usual cost")
    }

    /// "$8", or "Usually $15–30 per person" when the post didn't say.
    private var costValue: String {
        if let userCost = post.userCost { return userCost.dollarsText }
        return post.postedPrice?.perPersonText ?? "Unknown"
    }
}

/// Where the place came from: platform, creator, caption and thumbnail when known, and a link back
/// to the original post. The caption never shows the post's link (W-12).
struct SourceCard: View {
    let post: SavedPost

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .top, spacing: Space.sm) {
                if post.thumbnailURL != nil {
                    SavedThumbnail(post: post, size: 64)
                }
                VStack(alignment: .leading, spacing: Space.xs) {
                    HStack(spacing: Space.xs) {
                        Icon(.video, size: 16)
                        Text(sourceLine)
                            .font(.label)
                    }
                    .foregroundStyle(.ink)

                    if let caption = SourceCard.caption(for: post) {
                        Text("“\(caption)”").font(.bodyText).foregroundStyle(.ink)
                    }
                }
            }

            if ["http", "https"].contains(post.url.scheme?.lowercased() ?? "") {
                Link(destination: post.url) {
                    HStack(spacing: Space.xxs) {
                        Text("View original post").underline()
                        Icon(.externalLink, size: 14)
                    }
                    .font(.label)
                    .foregroundStyle(.emeraldDeep)
                    .frame(minHeight: 44)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .planditCard()
        .accessibilityIdentifier("post-source")
    }

    /// "Saved from TikTok · @creator", or "Saved from a video".
    private var sourceLine: String {
        let source = post.platform == .video ? "Saved from a video" : "Saved from \(post.platform.displayName)"
        return source + (post.creatorHandle.map { " · \($0)" } ?? "")
    }

    /// The post's words without its link; nothing for a video (its text is what Plandit read).
    static func caption(for post: SavedPost) -> String? {
        guard post.platform != .video else { return nil }
        return LinkParser.textWithoutLinks(post.caption)
    }
}

/// Where a saved place landed in today's plan, and anything that needs a look:
/// "Stop 4 · 2:30–3:15 PM", "Closes at 9 PM", "$5 over today's budget".
private struct TodayPlacement: View {
    let postID: UUID
    @TodayContext private var today

    var body: some View {
        let plan = today.plan
        if let index = plan.stops.firstIndex(where: { $0.sourcePostID == postID }) {
            let stop = plan.stops[index]
            VStack(spacing: Space.xxs) {
                Text("Stop \(index + 1) · \(stop.start.shortTime)–\(stop.end.shortTime)")
                    .font(.bodyText)
                    .foregroundStyle(.ink)
                    .accessibilityIdentifier("today-placement")
                if index > 0, let trip = plan.legs.first(where: { $0.toStopID == stop.id }) {
                    Text(TodayPlacementText.trip(trip, from: plan.stops[index - 1]))
                        .font(.metadata)
                        .foregroundStyle(.inkMuted)
                        .accessibilityIdentifier("today-placement-trip")
                }
                ForEach(warnings(stop, in: plan), id: \.self) { warning in
                    Text(warning).font(.metadata).foregroundStyle(Color.error).multilineTextAlignment(.center)
                }
                // Takes it out of today only; the place stays in Saved.
                if today.canEdit {
                    Button {
                        withAnimation(.snappy) { today.remove(stop.id) }
                    } label: {
                        Text(today.isGroup ? "Remove from \(today.planName)" : "Remove from today")
                            .font(.label)
                            .foregroundStyle(.ink)
                            .underline()
                            .frame(minHeight: 44)
                    }
                    .accessibilityHint("Keeps it in your saved places")
                    .accessibilityIdentifier("remove-from-today")
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func warnings(_ stop: PlanStop, in plan: DayPlan) -> [String] {
        var lines: [String] = []
        if let close = stop.place.closingTime(on: stop.start) {
            let minutes = Int(close.timeIntervalSince(stop.start) / 60)
            if minutes <= 0 {
                lines.append("\(stop.place.name) closes at \(close.shortTime), before you'd get there.")
            } else if minutes < DayPlanner.minimumStayMinutes {
                lines.append("\(stop.place.name) closes at \(close.shortTime), so you'd only have \(minutes.durationText) there.")
            }
        }
        let late = plan.stopsArrivingAfterClose().filter { $0.id != stop.id }
        if !late.isEmpty {
            lines.append("You'd get to \(late.map(\.place.name).formatted(.list(type: .and))) after closing.")
        }
        if plan.remaining < 0 {
            lines.append("Today is \((-plan.remaining).wholeDollarsText) over budget.")
        }
        return lines
    }
}

enum TodayPlacementText {
    /// "12 min walk from The Met", "35 min subway ride from The Met · $2.90", "18 min drive from The Met · about $14".
    static func trip(_ leg: TravelLeg, from previous: PlanStop) -> String {
        let way = switch leg.mode {
        case .walk: "walk"
        case .subway: "subway ride"
        case .bus: "bus ride"
        case .drive: "drive"
        }
        let trip = "\(leg.minutes.durationText) \(way) from \(previous.place.name)"
        guard leg.cost > 0 else { return trip }
        return leg.mode == .drive ? "\(trip) · about \(leg.cost.wholeDollarsText)" : "\(trip) · \(leg.cost.dollarsText)"
    }
}
