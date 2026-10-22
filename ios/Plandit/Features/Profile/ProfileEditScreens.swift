import SwiftUI

/// Default budget: a big number with a stepper and a few quick picks.
struct BudgetScreen: View {
    @Environment(PlanditStore.self) private var store
    private let quickPicks: [Double] = [20, 40, 60, 100]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.md) {
                Text("New plans start from this budget. You can still change it for any single day.")
                    .font(.bodyText)
                    .foregroundStyle(.inkMuted)

                HStack {
                    Text(store.profile.defaultBudget.wholeDollarsText)
                        .font(.heroDisplay)
                        .foregroundStyle(.ink)
                        .contentTransition(.numericText())
                    Spacer()
                    Stepper("Default budget", value: budget, in: 10...300, step: 10)
                        .labelsHidden()
                }
                .planditCard()

                HStack(spacing: Space.xs) {
                    ForEach(quickPicks, id: \.self) { amount in
                        Chip(title: amount.wholeDollarsText, isSelected: store.profile.defaultBudget == amount) {
                            set(amount)
                        }
                    }
                }
            }
            .padding(Space.lg)
        }
        .scrollIndicators(.hidden)
        .background(Color.canvas)
        .navigationTitle("Default budget")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.selection, trigger: store.profile.defaultBudget)
    }

    private var budget: Binding<Double> {
        Binding(get: { store.profile.defaultBudget }, set: set)
    }

    private func set(_ amount: Double) {
        withAnimation(.snappy(duration: 0.3)) {
            store.updateProfile { $0.defaultBudget = amount }
        }
    }
}

/// Home base: the neighborhood a day usually starts from.
struct HomeBaseScreen: View {
    @Environment(PlanditStore.self) private var store
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.md) {
                Text("Where your day usually starts. Plans begin near here.")
                    .font(.bodyText)
                    .foregroundStyle(.inkMuted)

                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Neighborhood").font(.label).foregroundStyle(.ink)
                    TextField("Morningside Heights", text: $text)
                        .font(.bodyText)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .focused($isFocused)
                        .onSubmit(save)
                        .padding(.horizontal, Space.sm)
                        .frame(minHeight: 48)
                        .background(Color.surface, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                                .strokeBorder(isFocused ? Color.ink : Color.border, lineWidth: isFocused ? 2 : 1)
                        )
                        .animation(.snappy(duration: 0.2), value: isFocused)
                }
            }
            .padding(Space.lg)
        }
        .scrollIndicators(.hidden)
        .background(Color.canvas)
        .navigationTitle("Home base")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { text = store.profile.homeBase }
        .onDisappear(perform: save)
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != store.profile.homeBase else { return }
        store.updateProfile { $0.homeBase = trimmed }
    }
}

/// Getting around: which ways of moving between stops the planner may use.
struct TravelModesScreen: View {
    @Environment(PlanditStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.sm) {
                Text("How you like to get between stops. Walking is always on.")
                    .font(.bodyText)
                    .foregroundStyle(.inkMuted)

                VStack(spacing: 0) {
                    ForEach(UserProfile.travelOptions, id: \.self) { option in
                        let isSelected = option == store.profile.travelModes
                        Button {
                            withAnimation(.snappy(duration: 0.25)) {
                                store.updateProfile { $0.travelModes = option }
                            }
                        } label: {
                            HStack(spacing: Space.sm) {
                                Text(option)
                                    .font(.manrope(.semiBold, size: 16))
                                    .foregroundStyle(.ink)
                                Spacer()
                                if isSelected {
                                    Icon(.check, size: 20)
                                        .foregroundStyle(.emeraldDeep)
                                        .transition(.scale.combined(with: .opacity))
                                }
                            }
                            .padding(.horizontal, Space.md)
                            .frame(minHeight: 56)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])

                        if option != UserProfile.travelOptions.last {
                            Hairline().padding(.leading, Space.md)
                        }
                    }
                }
                .planditCard(padding: 0)
            }
            .padding(Space.lg)
        }
        .scrollIndicators(.hidden)
        .background(Color.canvas)
        .navigationTitle("Getting around")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.selection, trigger: store.profile.travelModes)
    }
}

/// The share-sheet walkthrough, for people who dismissed the tip on Saved.
struct HowToSaveScreen: View {
    @Environment(SheetRouter.self) private var router

    private let steps = [
        "In TikTok or Instagram, open the post and tap Share.",
        "Choose Plandit. The first time, tap More to turn it on.",
        "Tap Save to Plandit. The place shows up in Saved with its price and hours.",
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.md) {
                VStack(alignment: .leading, spacing: Space.md) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: Space.sm) {
                            StopBadge(number: index + 1, status: .upcoming, size: 26)
                            Text(step).font(.bodyText).foregroundStyle(.ink)
                        }
                    }
                }
                .planditCard()

                Text("You can also paste a link from the Saved tab.")
                    .font(.bodyText)
                    .foregroundStyle(.inkMuted)

                Button {
                    router.show(.saved)
                } label: {
                    HStack(spacing: Space.xs) {
                        Icon(.bookmark, size: 18)
                        Text("Go to Saved")
                    }
                }
                .buttonStyle(.secondary)
            }
            .padding(Space.lg)
        }
        .scrollIndicators(.hidden)
        .background(Color.canvas)
        .navigationTitle("Saving from TikTok and Instagram")
        .navigationBarTitleDisplayMode(.inline)
    }
}
