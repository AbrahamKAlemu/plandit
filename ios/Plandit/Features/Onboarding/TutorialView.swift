import SwiftUI

/// D-1's three pages, in order.
nonisolated enum TutorialPage: Int, CaseIterable, Identifiable {
    case share, shape, plan

    var id: Int { rawValue }
    var number: Int { rawValue + 1 }
    var pageLabel: String { "Page \(number) of \(Self.allCases.count)" }
    /// Nil on the last page, where Continue finishes.
    var next: TutorialPage? { TutorialPage(rawValue: rawValue + 1) }

    var title: String {
        switch self {
        case .share: "Share the saved places you want to visit"
        case .shape: "Tell us what you want your day to look like"
        case .plan: "Get a plan for your day"
        }
    }

    var subtitle: String {
        switch self {
        case .share: "Add a place from Instagram or TikTok."
        case .shape: "Pick your saved places, then set your time and budget."
        case .plan: "See your stops in order and how to get between them."
        }
    }
}

/// First-run tutorial (D-1), after the design draft: the logo and Skip on top, a card with a
/// drawing over the title and subtitle, Continue at the bottom. Swipe or Continue moves forward;
/// Skip on any page, or Continue on the last, finishes it.
struct TutorialView: View {
    let onFinish: () -> Void
    @State private var page: TutorialPage = .share
    @State private var isTurning = false
    @AccessibilityFocusState private var focusedTitle: TutorialPage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header
            TabView(selection: $page) {
                ForEach(TutorialPage.allCases) { page in
                    TutorialPageView(page: page, focusedTitle: $focusedTitle)
                        .tag(page)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            Button("Continue", action: advance)
                .buttonStyle(.primary)
                .accessibilityIdentifier("tutorial-continue")
                .padding(.horizontal, Space.lg)
                .padding(.top, Space.sm)
                .padding(.bottom, Space.md)
        }
        .background(Color.canvas)
        // VoiceOver starts on the page's title, which reads "Page N of 3", and follows each page change.
        .onAppear { focusedTitle = page }
        .onChange(of: page) { _, page in focusedTitle = page }
    }

    private var header: some View {
        HStack(spacing: Space.sm) {
            // A logo, read as "Plandit": past the standard sizes it would crowd Skip, so it stops growing.
            TutorialWordmark()
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            Spacer(minLength: Space.sm)
            Button(action: onFinish) {
                Text("Skip")
                    .font(.label)
                    .foregroundStyle(.ink)
                    .padding(.horizontal, Space.md)
                    .frame(minHeight: 36)
                    .background(Color.surface, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.ink, lineWidth: 1))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("tutorial-skip")
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.xs)
    }

    private func advance() {
        // A second tap while the page turns would otherwise skip the next page unread.
        guard !isTurning else { return }
        guard let next = page.next else { return onFinish() }
        isTurning = true
        withAnimation(reduceMotion ? nil : .snappy) { page = next }
        // The paged TabView slides in UIKit, out of reach of an animation's completion, so wait
        // about as long as the slide. With Reduce Motion there is none, but a quick double tap
        // still mustn't skip a page.
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            isTurning = false
        }
    }
}

/// The mark beside "Plandit" in Manrope, colored like the lockup ("it" in emerald).
private struct TutorialWordmark: View {
    @ScaledMetric(relativeTo: .title2) private var markSize: CGFloat = 32

    var body: some View {
        HStack(spacing: Space.xs) {
            BrandArt.markSquare.image
                .resizable()
                .scaledToFit()
                .frame(width: markSize, height: markSize)
            Text("\(Text("Pland").foregroundStyle(Color.ink))\(Text("it").foregroundStyle(Color.emerald))")
                .font(.manrope(.extraBold, size: 22, relativeTo: .title2))
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Plandit")
    }
}

/// One page: the card scrolls when large text makes it taller than the screen.
private struct TutorialPageView: View {
    let page: TutorialPage
    var focusedTitle: AccessibilityFocusState<TutorialPage?>.Binding
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // At accessibility text sizes the words come first; the drawing is decoration.
                if !dynamicTypeSize.isAccessibilitySize {
                    TutorialIllustration(page: page)
                        .frame(maxWidth: .infinity)
                        .background(Color.canvas)
                    Hairline()
                }
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(page.title)
                        .font(.sectionHeading)
                        .foregroundStyle(.ink)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityValue(page.pageLabel)
                        .accessibilityFocused(focusedTitle, equals: page)
                        .accessibilityIdentifier("tutorial-title-\(page.number)")
                    Text(page.subtitle)
                        .font(.bodyText)
                        .foregroundStyle(.inkMuted)
                        .accessibilityIdentifier("tutorial-subtitle-\(page.number)")
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Space.lg)
            }
            .background(Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Color.border))
            .padding(.horizontal, Space.lg)
            .padding(.top, Space.md)
            .padding(.bottom, Space.lg)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}
