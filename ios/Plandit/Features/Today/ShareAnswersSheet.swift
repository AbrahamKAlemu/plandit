import SwiftUI

/// Who answered the shared plan's page: who's in, who can't make it, and the stops each would
/// swap. The organizer can remove any answer; it comes off the page too (GV-7).
struct ShareAnswersSheet: View {
    @Environment(PlanditStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var removing: ShareAnswer?
    @State private var removingIDs: Set<UUID> = []
    @State private var errorText: String?

    var body: some View {
        let answers = store.shareAnswers
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    if answers.isEmpty {
                        Text("No answers yet")
                            .font(.bodyText)
                            .foregroundStyle(.inkMuted)
                            .accessibilityIdentifier("answers-empty")
                    }
                    group("In", answers.filter { $0.status == .in })
                    group("Can't make it", answers.filter { $0.status == .out })
                    if answers.contains(where: { $0.status == .out }) {
                        Text("Only you can see who can't make it.")
                            .font(.metadata)
                            .foregroundStyle(.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let errorText {
                        Text(errorText)
                            .font(.metadata)
                            .foregroundStyle(Color.error)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("answers-error")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Space.lg)
                .animation(.snappy, value: answers.map(\.id))
            }
            .scrollIndicators(.hidden)
            .background(Color.surface)
            .navigationTitle("Friends' answers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .confirmationDialog(
                removing.map { "Remove \($0.name)'s answer?" } ?? "",
                isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                titleVisibility: .visible,
                presenting: removing
            ) { answer in
                Button("Remove", role: .destructive) {
                    Task { await remove(answer) }
                }
                .accessibilityIdentifier("confirm-remove-answer")
            } message: { _ in
                Text("It comes off the plan page too.")
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Color.surface)
        .task { await store.refreshShareAnswers() }
    }

    @ViewBuilder private func group(_ title: String, _ answers: [ShareAnswer]) -> some View {
        if !answers.isEmpty {
            VStack(alignment: .leading, spacing: Space.sm) {
                SectionTitle(title)
                VStack(spacing: 0) {
                    ForEach(Array(answers.enumerated()), id: \.element.id) { index, answer in
                        if index > 0 { Hairline() }
                        row(answer)
                    }
                }
                .planditCard(padding: Space.sm)
            }
        }
    }

    private func row(_ answer: ShareAnswer) -> some View {
        HStack(alignment: .center, spacing: Space.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(answer.name)
                    .font(.bodyText)
                    .foregroundStyle(.ink)
                ForEach(swapLines(answer), id: \.self) { line in
                    Text(line)
                        .font(.metadata)
                        .foregroundStyle(.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            if removingIDs.contains(answer.id) {
                ProgressView().frame(width: 44, height: 44)
            } else {
                Button {
                    errorText = nil
                    removing = answer
                } label: {
                    Icon(.trash, size: 18)
                        .foregroundStyle(Color.error)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(answer.name)'s answer")
                .accessibilityIdentifier("remove-answer-\(answer.name)")
            }
        }
        .frame(minHeight: 44)
    }

    /// "Would swap The High Line for Little Island", in plan order, for stops still in the plan.
    private func swapLines(_ answer: ShareAnswer) -> [String] {
        store.today.stops.compactMap { stop in
            guard let pick = answer.swaps[stop.id] else { return nil }
            if let name = pick.flatMap({ store.post(id: $0)?.place?.name }) {
                return "Would swap \(stop.place.name) for \(name)"
            }
            return "Would swap \(stop.place.name)"
        }
    }

    private func remove(_ answer: ShareAnswer) async {
        removingIDs.insert(answer.id)
        defer { removingIDs.remove(answer.id) }
        do {
            try await store.removeShareAnswer(answer.id)
        } catch {
            errorText = "Couldn't remove the answer. Check your connection and try again."
        }
    }
}

/// What friends picked instead of one stop: "Swap it" puts their pick in its place and plans the
/// times again (GV-6); "Keep <stop>" keeps the stop and hides these picks.
struct StopSwapSheet: View {
    let stopID: UUID
    @Environment(PlanditStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// One card per place picked, in the order friends first picked it; then those with no pick.
    private struct Group: Identifiable {
        var alternateID: UUID?
        var names: [String]
        var id: String { alternateID?.uuidString ?? "none" }
    }

    var body: some View {
        let picks = store.swapMarks[stopID] ?? []
        let groups = Self.groups(picks)
        let picked = groups.filter { $0.alternateID != nil }
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.md) {
                    if let stop = store.stop(id: stopID) {
                        SectionTitle(ShareAnswersText.wouldSwap(picks.count))
                        ForEach(groups) { group in
                            if let alternateID = group.alternateID {
                                pickCard(alternateID, names: group.names, stop: stop, isOnlyPick: picked.count == 1)
                            } else {
                                noPickCard(group.names)
                            }
                        }
                        Button("Keep \(stop.place.name)") {
                            withAnimation(.snappy) { store.keepStop(stopID) }
                            dismiss()
                        }
                        .buttonStyle(.secondary)
                        .accessibilityHint("Keeps \(stop.place.name) and hides these picks")
                        .accessibilityIdentifier("keep-it")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Space.lg)
            }
            .scrollIndicators(.hidden)
            .background(Color.surface)
            .navigationTitle(store.stop(id: stopID)?.place.name ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Color.surface)
        // The stop left the plan, or the picks were removed, while this was open.
        .onChange(of: picks.isEmpty) { _, isEmpty in
            if isEmpty { dismiss() }
        }
    }

    private static func groups(_ picks: [SwapPick]) -> [Group] {
        var groups: [Group] = []
        for pick in picks where pick.alternateID != nil {
            if let index = groups.firstIndex(where: { $0.alternateID == pick.alternateID }) {
                groups[index].names.append(pick.name)
            } else {
                groups.append(Group(alternateID: pick.alternateID, names: [pick.name]))
            }
        }
        let noPick = picks.filter { $0.alternateID == nil }.map(\.name)
        if !noPick.isEmpty { groups.append(Group(alternateID: nil, names: noPick)) }
        return groups
    }

    private func pickCard(_ alternateID: UUID, names: [String], stop: PlanStop, isOnlyPick: Bool) -> some View {
        let post = store.post(id: alternateID)
        let availability = store.swapAvailability(of: alternateID)
        return VStack(alignment: .leading, spacing: Space.sm) {
            VStack(alignment: .leading, spacing: 2) {
                if let place = post?.place {
                    Text("\(place.name) instead")
                        .font(.cardHeading)
                        .foregroundStyle(.ink)
                    Text([place.category.label, place.neighborhood, post?.plannedCost?.dollarsText]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.metadata)
                        .foregroundStyle(.inkMuted)
                }
                Text("\(names.formatted(.list(type: .and))) picked this")
                    .font(.metadata)
                    .foregroundStyle(.inkMuted)
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)

            switch availability {
            case .available:
                if let name = post?.place?.name {
                    swapButton(alternateID, name: name, isPrimary: isOnlyPick)
                }
            case .alreadyInPlan:
                Text("Already in your plan")
                    .font(.metadata)
                    .foregroundStyle(.inkMuted)
            case .notSaved:
                Text("No longer in your saved places")
                    .font(.metadata)
                    .foregroundStyle(.inkMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .planditCard()
    }

    @ViewBuilder private func swapButton(_ alternateID: UUID, name: String, isPrimary: Bool) -> some View {
        let button = Button("Swap it") {
            withAnimation(.snappy) { _ = store.swap(stopID: stopID, toPost: alternateID) }
            dismiss()
        }
        .accessibilityLabel("Swap it for \(name)")
        .accessibilityIdentifier("swap-it-\(name)")
        if isPrimary {
            button.buttonStyle(.primary)
        } else {
            button.buttonStyle(.secondary)
        }
    }

    private func noPickCard(_ names: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(names.formatted(.list(type: .and)))
                .font(.bodyText)
                .foregroundStyle(.ink)
            Text("Didn't pick a place")
                .font(.metadata)
                .foregroundStyle(.inkMuted)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .planditCard()
        .accessibilityElement(children: .combine)
    }
}
