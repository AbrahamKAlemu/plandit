import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct SavedPostDetailView: View {
    let postID: UUID
    @Environment(PlanditStore.self) private var store
    @Environment(SheetRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var evidenceText = ""
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
            let isInToday = store.isInToday(post)
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    switch post.status {
                    case .processing:
                        HStack(spacing: Space.sm) {
                            ProgressView()
                            Text("Finding the place in \(post.platform.postPhrase)…")
                                .font(.bodyText)
                                .foregroundStyle(.ink)
                        }
                        .planditCard()
                        .transition(.opacity)
                    case .needsEvidence:
                        EvidenceEditor(
                            platform: post.platform,
                            text: $evidenceText,
                            message: post.failureMessage
                                ?? "Add the restaurant or place name, neighborhood, address, or clues from the video."
                        ) {
                            store.submitEvidence(postID: post.id, text: evidenceText)
                        }
                        videoFallback(for: post)
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
                            PlaceSearchEditor(
                                name: $searchName,
                                address: $searchAddress
                            ) {
                                let query = [searchName, searchAddress]
                                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                    .filter { !$0.isEmpty }
                                    .joined(separator: ", ")
                                isSearchingForPlace = false
                                store.submitEvidence(postID: post.id, text: query)
                            }
                        }
                    case .failed:
                        VStack(alignment: .leading, spacing: Space.sm) {
                            Text("We couldn't find a place").font(.sectionHeading).foregroundStyle(.ink)
                            Text(post.failureMessage ?? "Nothing in \(post.platform.postPhrase) matched a place. Add a name or neighborhood and try again.")
                                .font(.bodyText)
                                .foregroundStyle(.inkMuted)
                            Button("Try again") { withAnimation(.snappy) { store.retryExtraction(post.id) } }
                                .buttonStyle(.secondary)
                        }
                        .transition(.opacity)
                        EvidenceEditor(
                            platform: post.platform,
                            text: $evidenceText,
                            message: "Or add the place name, neighborhood, or address yourself."
                        ) {
                            store.submitEvidence(postID: post.id, text: evidenceText)
                        }
                        videoFallback(for: post)
                    case .ready, .needsReview:
                        if let place = post.place {
                            PlaceSummary(post: post, place: place)
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                    }

                    VStack(spacing: Space.sm) {
                        if post.isMappable {
                            if isInToday {
                                HStack(spacing: Space.xs) {
                                    Icon(.circleCheck, size: 18)
                                    Text("In today's plan")
                                }
                                .font(.label)
                                .foregroundStyle(.emeraldDeep)
                                .frame(maxWidth: .infinity, minHeight: 48)
                                .transition(.scale(scale: 0.9).combined(with: .opacity))

                                Button {
                                    router.show(.today)
                                } label: {
                                    HStack(spacing: Space.xs) {
                                        Icon(.route, size: 18)
                                        Text("View today's plan")
                                    }
                                }
                                .buttonStyle(.secondary)
                                .transition(.opacity)
                            } else {
                                Button {
                                    withAnimation(.snappy) { _ = store.addToToday(post.id) }
                                } label: {
                                    HStack(spacing: Space.xs) {
                                        Icon(.plus, size: 18)
                                        Text("Add to today's plan")
                                    }
                                }
                                .buttonStyle(.primary)
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

                    SourceCard(post: post)
                }
                .padding(Space.lg)
                .animation(.snappy(duration: 0.35), value: post.status)
                .animation(.snappy(duration: 0.35), value: isInToday)
            }
            .background(Color.surface)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if evidenceText.isEmpty {
                    evidenceText = post.caption ?? ""
                }
            }
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

    @ViewBuilder
    private func videoFallback(for post: SavedPost) -> some View {
        if post.platform != .video {
            VStack(alignment: .leading, spacing: Space.sm) {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text("Use the saved video instead")
                        .font(.sectionHeading)
                        .foregroundStyle(.ink)
                    Text("Plandit reads it on this device and deletes the temporary copy.")
                        .font(.bodyText)
                        .foregroundStyle(.inkMuted)
                }

                PhotosPicker(
                    selection: $selectedVideo,
                    matching: .videos,
                    photoLibrary: .shared()
                ) {
                    Text("Choose from Photos")
                }
                .buttonStyle(.secondary)
                .disabled(isProcessingVideo)
                .accessibilityIdentifier("fallback-video-photos")

                Button("Choose from Files") {
                    isChoosingVideo = true
                }
                .buttonStyle(.plain)
                .disabled(isProcessingVideo)
                .accessibilityIdentifier("fallback-video-files")

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

private struct CandidateList: View {
    let post: SavedPost
    let onConfirm: (String) -> Void
    let onSearch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("Places found").font(.sectionHeading).foregroundStyle(.ink)
                Text("Choose the place from the video to add it to your map.")
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
    let onSubmit: () -> Void

    private var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("Search for the place")
                    .font(.sectionHeading)
                    .foregroundStyle(.ink)
                Text("Add the name, address, or both.")
                    .font(.bodyText)
                    .foregroundStyle(.inkMuted)
            }

            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Place name").font(.label).foregroundStyle(.ink)
                TextField("Place name", text: $name)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("place-search-name")
                    .searchFieldStyle()

                Text("Address").font(.label).foregroundStyle(.ink)
                TextField("Street address, neighborhood, or city", text: $address)
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

private struct EvidenceEditor: View {
    let platform: SourcePlatform
    @Binding var text: String
    let message: String
    let onSubmit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("Add details from \(platform.postPhrase)").font(.sectionHeading).foregroundStyle(.ink)
                Text(message).font(.bodyText).foregroundStyle(.inkMuted)
            }
            TextEditor(text: $text)
                .font(.bodyText)
                .frame(minHeight: 120)
                .padding(Space.xs)
                .background(Color.canvas, in: RoundedRectangle(cornerRadius: Radius.control))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.control)
                        .strokeBorder(Color.border)
                )
            Button("Find matching places", action: onSubmit)
                .buttonStyle(.primary)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .planditCard()
    }
}

private struct PlaceSummary: View {
    let post: SavedPost
    let place: Place

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
                FactRow(icon: .wallet, title: "Estimated cost", value: post.estimatedCost?.dollarsText ?? "Unknown")
                FactRow(icon: .mapPin, title: "Address", value: place.address)
                FactRow(icon: .clock, title: "Hours", value: place.hours ?? "Not listed")
            }
            .planditCard()
        }
    }
}

/// Where the place came from, with a link back to the original post.
struct SourceCard: View {
    let post: SavedPost

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.xs) {
                Icon(.video, size: 16)
                Text("Saved from \(post.platform.displayName)" + (post.creatorHandle.map { " · \($0)" } ?? ""))
                    .font(.label)
            }
            .foregroundStyle(.ink)

            if let caption = post.caption, post.platform != .video {
                Text("“\(caption)”").font(.bodyText).foregroundStyle(.ink)
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
        .planditCard()
    }
}
