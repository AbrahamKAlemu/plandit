import SwiftUI

struct SavedPostDetailView: View {
    let postID: UUID
    @Environment(PlanditStore.self) private var store
    @Environment(SheetRouter.self) private var router
    @Environment(\.dismiss) private var dismiss

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
                    case .failed:
                        VStack(alignment: .leading, spacing: Space.sm) {
                            Text("We couldn't find a place").font(.sectionHeading).foregroundStyle(.ink)
                            Text("Nothing in \(post.platform.postPhrase) matched a place in Manhattan. Try again or view the original post.")
                                .font(.bodyText)
                                .foregroundStyle(.inkMuted)
                            Button("Try again") { withAnimation(.snappy) { store.retryExtraction(post.id) } }
                                .buttonStyle(.secondary)
                        }
                        .transition(.opacity)
                    case .ready, .needsReview:
                        if let place = post.place {
                            PlaceSummary(post: post, place: place)
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                    }

                    SourceCard(post: post)

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

                        Button(role: .destructive) {
                            dismiss()
                            withAnimation(.snappy) { store.removePost(post.id) }
                        } label: {
                            Text("Remove from saved")
                                .font(.label)
                                .foregroundStyle(.error)
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                    }
                }
                .padding(Space.lg)
                .animation(.snappy(duration: 0.35), value: post.status)
                .animation(.snappy(duration: 0.35), value: isInToday)
            }
            .background(Color.surface)
            .navigationBarTitleDisplayMode(.inline)
            .sensoryFeedback(.success, trigger: isInToday) { _, added in added }
        } else {
            ContentUnavailableView("Removed", image: "Icons/bookmark", description: Text("This post is no longer saved."))
        }
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
        .planditCard()
    }
}
