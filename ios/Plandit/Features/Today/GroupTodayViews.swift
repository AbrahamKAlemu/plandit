import SwiftUI

/// "Mine | Maya's plan" under Today's header, when there's a group plan to show.
struct TodaySwitcher: View {
    let options: [GroupToday.Option]
    let selection: TodayChoice
    let select: (TodayChoice) -> Void

    var body: some View {
        Picker("Plan", selection: Binding(get: { selection }, set: { select($0) })) {
            ForEach(options) { option in
                Text(option.label).tag(option.choice)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("today-switcher")
    }
}

/// Above a group plan: why it can't be changed, or that changes are still on their way.
struct GroupStatusLine: View {
    let group: GroupPlanState
    /// Shown only when saving takes a moment, so quick edits don't flash it.
    @State private var showsSaving = false

    var body: some View {
        Group {
            if let locked = GroupToday.lockedLine(group) {
                HStack(alignment: .top, spacing: Space.xs) {
                    Icon(.info, size: 16)
                        .foregroundStyle(.inkMuted)
                        .accessibilityHidden(true)
                    Text(locked)
                        .font(.metadata)
                        .foregroundStyle(.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("group-locked")
            } else if showsSaving {
                HStack(spacing: Space.xs) {
                    ProgressView().controlSize(.small)
                    Text("Saving…")
                        .font(.metadata)
                        .foregroundStyle(.inkMuted)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Saving your changes")
                .accessibilityIdentifier("group-saving")
                .transition(.opacity)
            }
        }
        .animation(.snappy, value: showsSaving)
        .task(id: group.pendingEdits > 0) {
            guard group.pendingEdits > 0 else {
                showsSaving = false
                return
            }
            do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
            showsSaving = true
        }
    }
}

/// A group plan with nothing in it yet, or not fetched yet.
struct GroupEmptyToday: View {
    let group: GroupPlanState

    var body: some View {
        Group {
            if group.plan == nil {
                VStack(spacing: Space.xs) {
                    ProgressView()
                    Text("Getting the plan…")
                        .font(.metadata)
                        .foregroundStyle(.inkMuted)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Space.lg)
            } else {
                EmptyState(
                    icon: .route,
                    title: "No stops yet",
                    message: GroupToday.controls(for: group, groupsAvailable: true).editing
                        ? "Add a place from Saved to put it in this plan."
                        : "This plan has no stops.",
                    isCompact: true
                ) {
                    EmptyView()
                }
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.top, Space.xs)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("group-empty")
    }
}

/// "Edit with friends" while it works. A second tap while the first is going does nothing, so one
/// tap makes one group plan.
@Observable
final class GroupStarter {
    private(set) var isStarting = false
    private(set) var error: String?

    /// The new group plan's link; nil when it failed (`error` says why) or a start was already going.
    func start(with today: TodayPlanContext) async -> URL? {
        guard !isStarting else { return nil }
        isStarting = true
        error = nil
        defer { isStarting = false }
        switch await today.startGroup() {
        case .success(let link):
            return link
        case .failure(let failure):
            error = GroupToday.failureText(failure, for: .start)
            return nil
        }
    }
}

/// "Edit with friends" on your own plan: makes a group plan from it, shows it, and opens the
/// share sheet with its link. A second tap while it's working does nothing.
struct StartGroupButton: View {
    @TodayContext private var today
    @State private var starter = GroupStarter()

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Button(action: start) {
                HStack(spacing: Space.xs) {
                    if starter.isStarting {
                        ProgressView().controlSize(.small)
                    } else {
                        Icon(.users, size: 18)
                    }
                    Text("Edit with friends")
                }
            }
            .buttonStyle(.secondary)
            .disabled(starter.isStarting)
            // The line below says who can change it and what they see; VoiceOver reads it next.
            .accessibilityHint("Makes a copy of this plan, then lets you send your friends the link")
            .accessibilityIdentifier("start-group")
            Text(GroupMembersText.startGroupNote)
                .font(.metadata)
                .foregroundStyle(.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("start-group-note")
            if let error = starter.error {
                Text(error)
                    .font(.metadata)
                    .foregroundStyle(Color.error)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("start-group-error")
            }
        }
    }

    private func start() {
        let today = today
        Task {
            if let link = await starter.start(with: today) {
                InviteShareSheet.present(link)
            } else if let error = starter.error {
                AccessibilityNotification.Announcement(error).post()
            }
        }
    }
}
