import SwiftUI

/// Profile in the 1.0.1 draft's order (D-6): who you are, Preferences, Activity, Past plans,
/// Account, then the logo and version. Appearance and Account moved here from 1.0's Settings tab.
struct ProfileSheet: View {
    @Environment(PlanditStore.self) private var store
    @Environment(AppearanceSettings.self) private var appearance
    @Environment(AccountModel.self) private var account
    @State private var isConfirmingDelete = false

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Profile") {
                EmptyView()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    header
                    preferences
                    activity
                    pastPlans
                    accountSection
                    footer
                }
                .padding(.horizontal, Space.lg)
                .padding(.top, Space.xs)
                .padding(.bottom, Space.lg)
            }
            .scrollIndicators(.hidden)
            .hiddenWhenSheetCollapsed()
        }
        .background(Color.surface)
        .toolbar(.hidden, for: .navigationBar)
    }

    // MARK: - Sections

    /// Initial, name and school. Tapping it edits the name.
    private var header: some View {
        let profile = store.profile
        return NavigationLink {
            NameScreen().clearsFloatingBars()
        } label: {
            HStack(spacing: Space.sm) {
                Group {
                    if profile.initial.isEmpty {
                        Icon(.userRound, size: 22).foregroundStyle(.onInk)
                    } else {
                        Text(profile.initial)
                            .font(.manrope(.extraBold, size: 20))
                            .foregroundStyle(.onInk)
                    }
                }
                .frame(width: 48, height: 48)
                .background(Color.ink, in: Circle())
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name.isEmpty ? "Your profile" : profile.name)
                        .font(.cardHeading)
                        .foregroundStyle(.ink)
                    if !profile.school.isEmpty {
                        Text(profile.school).font(.metadata).foregroundStyle(.inkMuted)
                    }
                }
                Spacer(minLength: 0)
                Icon(.chevronRight, size: 16).foregroundStyle(.inkMuted)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Edits your name")
        .accessibilityIdentifier("profile-header")
    }

    private var preferences: some View {
        let profile = store.profile
        return VStack(alignment: .leading, spacing: Space.sm) {
            SectionTitle("Preferences")
            VStack(spacing: 0) {
                preferenceRow(.house, "Home base", profile.homeBase.isEmpty ? "Not set" : profile.homeBase) { HomeBaseScreen() }
                Hairline().padding(.leading, 52)
                preferenceRow(.wallet, "Default budget", "\(profile.defaultBudget.wholeDollarsText) per person") { BudgetScreen() }
                Hairline().padding(.leading, 52)
                preferenceRow(.trainFront, "Preferred transportation", profile.travelModes) { TravelModesScreen() }
                Hairline().padding(.leading, 52)
                preferenceRow(.moon, "Appearance", appearance.mode.title) { AppearanceScreen() }
                Hairline().padding(.leading, 52)
                preferenceRow(.share, "How it works", "Saving places from TikTok and Instagram") { HowToSaveScreen() }
            }
            .planditCard(padding: 0)
            .animation(.snappy(duration: 0.3), value: profile.defaultBudget)
        }
    }

    /// The skyline picture above three numbers.
    private var activity: some View {
        let stats = store.stats
        return VStack(alignment: .leading, spacing: Space.sm) {
            SectionTitle("Activity")
            Color.clear
                .frame(height: 150)
                .overlay {
                    Image("profile-skyline")
                        .resizable()
                        .scaledToFill()
                }
                .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .accessibilityHidden(true)
            ActivityStats(items: [
                (stats.plansCompleted, "Plans completed"),
                (stats.neighborhoodsExplored, "Neighborhoods explored"),
                (stats.placesSaved, "Places saved"),
            ])
        }
    }

    /// Finished days as plain rows. 1.0 didn't keep a plan's stops, so there's nothing to open.
    private var pastPlans: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            SectionTitle("Past plans")
            if store.pastPlans.isEmpty {
                Text("Your finished days show up here.")
                    .font(.bodyText)
                    .foregroundStyle(.inkMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .planditCard()
            } else {
                VStack(spacing: 0) {
                    ForEach(store.pastPlans) { plan in
                        PastPlanRow(plan: plan)
                        if plan.id != store.pastPlans.last?.id { Hairline().padding(.leading, Space.md) }
                    }
                }
                .planditCard(padding: 0)
            }
        }
    }

    /// Signed in as, Sign out and Delete account, as in 1.0's Settings. `AccountModel` does the work.
    private var accountSection: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            SectionTitle("Account")
            VStack(spacing: 0) {
                HStack(spacing: Space.sm) {
                    Icon(.userRound, size: 20).foregroundStyle(.ink).frame(width: 24)
                    Text(signedInText)
                        .font(.manrope(.semiBold, size: 15))
                        .foregroundStyle(.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Space.md)
                .padding(.vertical, Space.sm)
                .frame(minHeight: 56)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("account-signed-in")

                Hairline().padding(.leading, 52)

                AccountActionRow(title: AuthCopy.signOut, isDestructive: false, isBusy: account.isBusy) {
                    Task { await account.signOut() }
                }
                .accessibilityIdentifier("sign-out")

                Hairline().padding(.leading, 52)

                AccountActionRow(title: AuthCopy.deleteAccount, isDestructive: true, isBusy: account.isBusy) {
                    isConfirmingDelete = true
                }
                .accessibilityIdentifier("delete-account")
                .confirmationDialog(AuthCopy.deleteTitle, isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                    Button(AuthCopy.deleteAccount, role: .destructive) {
                        Task { await account.deleteAccount() }
                    }
                    // Since iOS 26 this dialog is a popover, and popovers hide `.cancel` buttons.
                    // A plain button keeps Cancel visible there (W-5); earlier iOS shows the system one.
                    if #available(iOS 26, *) {
                        Button("Cancel") {}
                    } else {
                        Button("Cancel", role: .cancel) {}
                    }
                } message: {
                    Text(AuthCopy.deleteMessage)
                }
            }
            .planditCard(padding: 0)

            if let message = account.errorMessage {
                InlineErrorText(message: message)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: Space.xs) {
            BrandLockup(markSize: 32)
            Text("Version \(Bundle.main.shortVersion)")
                .font(.metadata)
                .foregroundStyle(.inkMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Space.xs)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("profile-footer")
    }

    // MARK: - Helpers

    private var signedInText: String {
        if let email = account.currentUser?.email, !email.isEmpty {
            return AuthCopy.signedInAs(email)
        }
        return AuthCopy.signedInWithApple
    }

    private func preferenceRow<Destination: View>(
        _ icon: Lucide, _ title: String, _ value: String, @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink {
            destination().clearsFloatingBars()
        } label: {
            ListRow(icon: icon, title: title, detail: value)
        }
        .buttonStyle(.plain)
    }
}

/// Activity's numbers: side by side in equal columns, tops lined up, when every label fits its
/// column without breaking a word; otherwise, and always at accessibility sizes, one under another.
private struct ActivityStats: View {
    let items: [(value: Int, label: String)]
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            stacked
        } else {
            ViewThatFits(in: .horizontal) {
                across
                stacked
            }
        }
    }

    private var across: some View {
        EqualColumns {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                StatCell(value: item.value, label: item.label)
                    .overlay(alignment: .leading) {
                        if index > 0 {
                            Rectangle().fill(Color.border).frame(width: 1).padding(.vertical, Space.sm)
                        }
                    }
            }
        }
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 2) {
                    StatNumber(value: item.value)
                    StatLabel(text: item.label)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, Space.xs)
    }
}

/// One number centered over its label. The hidden longest word sets the narrowest the cell can be,
/// so `EqualColumns` knows when a column would have to break a word.
private struct StatCell: View {
    let value: Int
    let label: String

    var body: some View {
        ZStack(alignment: .top) {
            StatLabel(text: longestWord).fixedSize().frame(height: 0).hidden().accessibilityHidden(true)
            VStack(spacing: 2) {
                StatNumber(value: value)
                StatLabel(text: label).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, Space.xxs)
        .padding(.vertical, Space.sm)
        .accessibilityElement(children: .combine)
    }

    private var longestWord: String {
        label.components(separatedBy: " ").max { $0.count < $1.count } ?? label
    }
}

private struct StatNumber: View {
    let value: Int

    var body: some View {
        Text("\(value)")
            .font(.manrope(.extraBold, size: 22))
            .foregroundStyle(.ink)
            .lineLimit(1)
            .contentTransition(.numericText())
    }
}

private struct StatLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.metadata)
            .foregroundStyle(.inkMuted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Equal-width columns, all as tall as the tallest, tops lined up. Its ideal width is the narrowest
/// that keeps every column at least as wide as its narrowest cell, which is what `ViewThatFits`
/// compares with the space it has.
private struct EqualColumns: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let count = CGFloat(subviews.count)
        let narrowest = subviews.map { $0.sizeThatFits(ProposedViewSize(width: 0, height: nil)).width }.max() ?? 0
        let proposed = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 0
        let width = max(proposed, narrowest * count)
        let column = width / count
        let height = subviews.map { $0.sizeThatFits(ProposedViewSize(width: column, height: nil)).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let column = bounds.width / CGFloat(subviews.count)
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(x: bounds.minX + CGFloat(index) * column, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: column, height: bounds.height)
            )
        }
    }
}

/// A full-width tappable row. Destructive uses the error color, always with its text.
private struct AccountActionRow: View {
    let title: String
    let isDestructive: Bool
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        Button(role: isDestructive ? .destructive : nil, action: action) {
            HStack(spacing: Space.sm) {
                Color.clear.frame(width: 24, height: 1)
                Text(title)
                    .font(.manrope(.semiBold, size: 15))
                    .foregroundStyle(isDestructive ? Color.error : Color.ink)
                Spacer(minLength: 0)
                if isBusy { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, Space.md)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
    }
}

/// An icon, a title and its current value, opening the screen that changes it.
/// Titles take two lines and details two lines; at accessibility sizes both wrap as far as they need.
struct ListRow: View {
    var icon: Lucide?
    let title: String
    let detail: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let lines = dynamicTypeSize.isAccessibilitySize ? nil : 2
        HStack(spacing: Space.sm) {
            if let icon {
                Icon(icon, size: 20).foregroundStyle(.ink).frame(width: 24)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.manrope(.semiBold, size: 15))
                    .foregroundStyle(.ink)
                    .lineLimit(lines)
                Text(detail)
                    .font(.metadata)
                    .foregroundStyle(.inkMuted)
                    .lineLimit(lines)
            }
            Spacer(minLength: 0)
            Icon(.chevronRight, size: 16).foregroundStyle(.inkMuted)
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
    }
}

extension Bundle {
    var shortVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "–" }
}
