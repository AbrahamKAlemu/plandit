import SwiftUI

/// Profile in the 1.0.1 draft's order (D-6): who you are, Preferences, Activity, Past plans,
/// Account, then the logo and version. Appearance and Account moved here from 1.0's Settings tab.
struct ProfileSheet: View {
    @Environment(PlanditStore.self) private var store
    @Environment(AppearanceSettings.self) private var appearance
    @Environment(AccountModel.self) private var account
    @Environment(\.colorScheme) private var colorScheme
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
            NameScreen()
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
            HStack(spacing: 0) {
                StatCell(value: stats.plansCompleted, label: "Plans completed")
                StatDivider()
                StatCell(value: stats.neighborhoodsExplored, label: "Neighborhoods explored")
                StatDivider()
                StatCell(value: stats.placesSaved, label: "Places saved")
            }
            .fixedSize(horizontal: false, vertical: true)
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
                        .lineLimit(2)
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
            (colorScheme == .dark ? BrandArt.lockupDark : BrandArt.lockupLight).image
                .resizable()
                .scaledToFit()
                .frame(width: 132)
                .accessibilityLabel("Plandit")
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
        NavigationLink(destination: destination) {
            ListRow(icon: icon, title: title, detail: value)
        }
        .buttonStyle(.plain)
    }
}

/// One of Activity's three numbers, centered over its label.
private struct StatCell: View {
    let value: Int
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.manrope(.extraBold, size: 22))
                .foregroundStyle(.ink)
                .lineLimit(1)
                .contentTransition(.numericText())
            Text(label)
                .font(.metadata)
                .foregroundStyle(.inkMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .padding(.horizontal, Space.xs)
        .padding(.vertical, Space.sm)
        .accessibilityElement(children: .combine)
    }
}

private struct StatDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.border)
            .frame(width: 1)
            .padding(.vertical, Space.sm)
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
struct ListRow: View {
    var icon: Lucide?
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: Space.sm) {
            if let icon {
                Icon(icon, size: 20).foregroundStyle(.ink).frame(width: 24)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.manrope(.semiBold, size: 15))
                    .foregroundStyle(.ink)
                    .lineLimit(1)
                Text(detail)
                    .font(.metadata)
                    .foregroundStyle(.inkMuted)
                    .lineLimit(2)
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
