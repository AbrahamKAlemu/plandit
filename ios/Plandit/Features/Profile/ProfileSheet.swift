import SwiftUI

struct ProfileSheet: View {
    @Environment(PlanditStore.self) private var store

    var body: some View {
        let profile = store.profile
        VStack(spacing: 0) {
            SheetHeader(title: "Profile") {
                NavigationLink {
                    PlaceholderScreen(title: "Settings")
                } label: {
                    CircleIconLabel(icon: .settings)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    HStack(spacing: Space.sm) {
                        Text(profile.initial)
                            .font(.manrope(.extraBold, size: 20))
                            .foregroundStyle(.white)
                            .frame(width: 48, height: 48)
                            .background(Color.ink, in: Circle())
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.name).font(.cardHeading).foregroundStyle(.ink)
                            Text(profile.school).font(.metadata).foregroundStyle(.inkMuted)
                        }
                    }
                    .accessibilityElement(children: .combine)

                    VStack(alignment: .leading, spacing: Space.sm) {
                        SectionTitle("Activity")
                        StatsCard(stats: [
                            ("\(store.stats.plansCompleted)", "Plans completed"),
                            ("\(store.saved.count)", "Places saved"),
                            ("\(store.stats.neighborhoodsVisited)", "Neighborhoods"),
                            (store.stats.milesWalked.milesText, "Walked"),
                            (store.stats.averageSpend.wholeDollarsText, "Average per plan"),
                            ("\(store.stats.plansUnderBudget) of \(store.stats.plansCompleted)", "Under budget"),
                        ])
                        HStack(spacing: Space.sm) {
                            Icon(.flame, size: 20).foregroundStyle(.ink)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(store.stats.streakWeeks)-week streak").font(.label).foregroundStyle(.ink)
                                Text("A plan every weekend for \(store.stats.streakWeeks) weeks")
                                    .font(.metadata)
                                    .foregroundStyle(.inkMuted)
                            }
                            Spacer(minLength: 0)
                        }
                        .planditCard(padding: Space.md)
                    }

                    VStack(alignment: .leading, spacing: Space.sm) {
                        SectionTitle("Recent plans")
                        VStack(spacing: 0) {
                            ForEach(store.pastPlans) { plan in
                                NavigationLink {
                                    PlaceholderScreen(title: plan.title)
                                } label: {
                                    ListRow(title: plan.title, detail: "\(plan.date.shortDay) · \(plan.stopCount) stops · \(plan.cost.wholeDollarsText)")
                                }
                                .buttonStyle(.plain)
                                if plan.id != store.pastPlans.last?.id { Hairline().padding(.leading, Space.md) }
                            }
                        }
                        .planditCard(padding: 0)
                    }

                    VStack(alignment: .leading, spacing: Space.sm) {
                        SectionTitle("Preferences")
                        VStack(spacing: 0) {
                            preferenceRow(.wallet, "Default budget", profile.defaultBudget.wholeDollarsText)
                            Hairline().padding(.leading, 52)
                            preferenceRow(.house, "Home base", profile.homeBase)
                            Hairline().padding(.leading, 52)
                            preferenceRow(.trainFront, "Getting around", profile.travelModes)
                            Hairline().padding(.leading, 52)
                            preferenceRow(.bell, "Notifications", "Plan reminders")
                            Hairline().padding(.leading, 52)
                            preferenceRow(.share, "Saving from TikTok and Instagram", "How it works")
                        }
                        .planditCard(padding: 0)
                    }

                    VStack(spacing: Space.xs) {
                        BrandArt.lockupLight.image
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

    private func preferenceRow(_ icon: Lucide, _ title: String, _ value: String) -> some View {
        NavigationLink {
            PlaceholderScreen(title: title)
        } label: {
            ListRow(icon: icon, title: title, detail: value)
        }
        .buttonStyle(.plain)
    }
}

/// Stats in a single bordered card, two per row, separated by hairlines.
private struct StatsCard: View {
    let stats: [(value: String, label: String)]

    var body: some View {
        let rows = stride(from: 0, to: stats.count, by: 2).map { Array(stats[$0..<min($0 + 2, stats.count)]) }
        VStack(spacing: 0) {
            ForEach(rows.indices, id: \.self) { index in
                if index > 0 { Hairline() }
                HStack(spacing: 0) {
                    ForEach(rows[index].indices, id: \.self) { column in
                        if column > 0 { Rectangle().fill(Color.border).frame(width: 1) }
                        StatCell(value: rows[index][column].value, label: rows[index][column].label)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .planditCard(padding: 0)
    }
}

private struct StatCell: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.manrope(.extraBold, size: 22))
                .foregroundStyle(.ink)
            Text(label)
                .font(.metadata)
                .foregroundStyle(.inkMuted)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.md)
        .accessibilityElement(children: .combine)
    }
}

private struct ListRow: View {
    var icon: Lucide?
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: Space.sm) {
            if let icon {
                Icon(icon, size: 20).foregroundStyle(.ink).frame(width: 24)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.manrope(.semiBold, size: 15)).foregroundStyle(.ink)
                Text(detail).font(.metadata).foregroundStyle(.inkMuted)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            Icon(.chevronRight, size: 16).foregroundStyle(.inkMuted)
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
    }
}

/// Destination for screens that aren't built yet.
struct PlaceholderScreen: View {
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(title).font(.sectionHeading).foregroundStyle(.ink)
            Text("Coming soon.")
                .font(.bodyText)
                .foregroundStyle(.inkMuted)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.lg)
        .background(Color.surface)
        .navigationBarTitleDisplayMode(.inline)
    }
}

extension Bundle {
    var shortVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "–" }
}
