import SwiftUI

struct SavedPostDetailView: View {
    let postID: UUID
    @Environment(PlanditStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var evidenceText = ""

    var body: some View {
        if let post = store.post(id: postID) {
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
                    case .needsEvidence:
                        EvidenceEditor(
                            platform: post.platform,
                            text: $evidenceText,
                            message: post.failureMessage
                                ?? "Add the restaurant or place name, neighborhood, address, or clues from the video."
                        ) {
                            store.submitEvidence(postID: post.id, text: evidenceText)
                        }
                    case .needsConfirmation:
                        CandidateList(post: post) { candidateID in
                            store.confirm(postID: post.id, candidateID: candidateID)
                        }
                    case .failed:
                        VStack(alignment: .leading, spacing: Space.sm) {
                            Text("We couldn't find a place").font(.sectionHeading).foregroundStyle(.ink)
                            Text(post.failureMessage ?? "Nothing in \(post.platform.postPhrase) matched a place. Add a name or neighborhood and try again.")
                                .font(.bodyText)
                                .foregroundStyle(.inkMuted)
                            Button("Try again") { store.retryExtraction(post.id) }
                                .buttonStyle(.secondary)
                        }
                        EvidenceEditor(
                            platform: post.platform,
                            text: $evidenceText,
                            message: "Or add the place name, neighborhood, or address yourself."
                        ) {
                            store.submitEvidence(postID: post.id, text: evidenceText)
                        }
                    case .ready, .needsReview:
                        if let place = post.place {
                            PlaceSummary(post: post, place: place)
                        }
                    }

                    SourceCard(post: post)

                    VStack(spacing: Space.sm) {
                        if post.isMappable {
                            if store.isInToday(post) {
                                HStack(spacing: Space.xs) {
                                    Icon(.circleCheck, size: 18)
                                    Text("In today's plan")
                                }
                                .font(.label)
                                .foregroundStyle(.emeraldDeep)
                                .frame(maxWidth: .infinity, minHeight: 48)
                            } else {
                                Button {
                                    store.addToToday(post.id)
                                } label: {
                                    HStack(spacing: Space.xs) {
                                        Icon(.plus, size: 18)
                                        Text("Add to today's plan")
                                    }
                                }
                                .buttonStyle(.primary)
                            }
                        }

                        Button(role: .destructive) {
                            dismiss()
                            store.removePost(post.id)
                        } label: {
                            Text("Remove from saved")
                                .font(.label)
                                .foregroundStyle(.error)
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                    }
                }
                .padding(Space.lg)
            }
            .background(Color.surface)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if evidenceText.isEmpty {
                    evidenceText = post.caption ?? ""
                }
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
        } else {
            ContentUnavailableView("Removed", image: "Icons/bookmark", description: Text("This post is no longer saved."))
        }
    }
}

private struct CandidateList: View {
    let post: SavedPost
    let onConfirm: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("Confirm the place").font(.sectionHeading).foregroundStyle(.ink)
                Text("Nothing is added to your map until you choose the right match.")
                    .font(.bodyText)
                    .foregroundStyle(.inkMuted)
            }

            ForEach(post.candidates) { candidate in
                VStack(alignment: .leading, spacing: Space.sm) {
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text(candidate.place.name).font(.cardHeading).foregroundStyle(.ink)
                        Text("\(candidate.place.neighborhood) · \(candidate.place.address)")
                            .font(.bodyText)
                            .foregroundStyle(.inkMuted)
                        Text("\(candidate.confidence.label) · \(candidate.reason)")
                            .font(.metadata)
                            .foregroundStyle(.inkMuted)
                    }
                    Button("Confirm \(candidate.place.name)") {
                        onConfirm(candidate.id)
                    }
                    .buttonStyle(.primary)
                }
                .planditCard()
            }
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

            if let caption = post.caption {
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
