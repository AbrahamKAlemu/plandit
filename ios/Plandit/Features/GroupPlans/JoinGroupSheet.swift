import Observation
import SwiftUI

/// A group plan invite waiting for the join sheet. Its own id, so the same link pasted again
/// opens a fresh sheet.
struct GroupInvite: Identifiable, Equatable {
    var id = UUID()
    var token: String
}

extension SheetRouter {
    /// Opens the join sheet for an invite link's token (JN-1).
    func join(invite token: String) {
        inviteToJoin = GroupInvite(token: token)
    }

    /// An invite the share sheet left in the App Group: its join sheet, once. Called whenever the
    /// app becomes active; the invite is gone once taken.
    func openPendingInvite() {
        if let token = InviteInbox.take() { join(invite: token) }
    }

    /// After joining: the join sheet closes and Today opens on the group. Today selects it and
    /// clears `groupPlanToOpen`.
    func openGroupPlan(_ id: UUID) {
        inviteToJoin = nil
        groupPlanToOpen = id
        show(.today)
    }
}

/// What the join sheet shows (GE-2, JN-2, JN-3): the invite's preview, then joining.
@Observable @MainActor
final class JoinGroupModel {
    enum State: Equatable {
        case loading
        /// "Join Maya's plan for Saturday?", with Join and Not now.
        case ready(GroupInvitePreview)
        case joining(GroupInvitePreview)
        /// No answer from the server. `retry` tries again whatever didn't get one.
        case offline
        /// The link doesn't work: replaced, the group is full or over, or you were removed. The
        /// server answers all of these the same (N-17).
        case gone
        /// Any other failure, with the words to show.
        case problem(String)
        /// A local-only account has no group plans.
        case needsAccount
        /// In the group (just joined, already in it, or it's your own): open it.
        case joined(UUID)
    }

    let token: String
    private(set) var state: State = .loading
    @ObservationIgnored private let groups: GroupPlanStore?
    /// Set once the preview has loaded, so a join that failed is tried again as a join.
    @ObservationIgnored private var preview: GroupInvitePreview?

    init(token: String, groups: GroupPlanStore?) {
        self.token = token
        self.groups = groups
    }

    func load() async {
        guard let groups else {
            state = .needsAccount
            return
        }
        // The organizer's own link: nothing to join, just open it (JN-3).
        if let own = groups.groups.first(where: { $0.inviteUrl.flatMap(InviteLink.token(in:)) == token }) {
            state = .joined(own.id)
            return
        }
        state = .loading
        switch await groups.preview(token: token) {
        case .success(let preview):
            self.preview = preview
            state = .ready(preview)
        case .failure(let failure):
            state = Self.state(for: failure)
        }
    }

    /// Joining a group you're already in changes nothing on the server or here (JN-3).
    func join() async {
        guard let groups else {
            state = .needsAccount
            return
        }
        guard let preview else { return await load() }
        if case .joining = state { return }
        state = .joining(preview)
        switch await groups.join(token: token) {
        case .success(let id):
            state = .joined(id)
        case .failure(let failure):
            state = Self.state(for: failure)
        }
    }

    /// "Try again": the join, once the preview has shown; otherwise the preview.
    func retry() async {
        if preview == nil {
            await load()
        } else {
            await join()
        }
    }

    private static func state(for failure: GroupPlanFailure) -> State {
        switch failure {
        case .offline: .offline
        case .gone: .gone
        case .refused(let detail?), .tooLarge(let detail?): .problem(detail)
        case .refused(nil), .tooLarge(nil), .unreadable, .failed: .problem(JoinGroupText.problemMessage)
        }
    }
}

/// The join sheet's words, apart so tests can read them.
enum JoinGroupText {
    /// "Join Maya's plan for Saturday?"
    static func question(_ preview: GroupInvitePreview, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        "Join \(preview.organizerName)'s plan for \(day(preview.date, now: now, calendar: calendar, locale: locale))?"
    }

    /// The plan's day (`YYYY-MM-DD`): "today", "tomorrow", the weekday within the week ahead
    /// ("Saturday"), otherwise "Saturday, November 28". As it is when it isn't a date.
    static func day(_ date: String, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let noon = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)),
              let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: noon)).day
        else { return date }
        var style = Date.FormatStyle.dateTime.weekday(.wide)
        switch days {
        case 0: return "today"
        case 1: return "tomorrow"
        case 2...6: break
        default: style = style.month(.wide).day()
        }
        style.locale = locale
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return noon.formatted(style)
    }

    /// "Just Jordan so far." or "3 people in the group so far." The count includes the organizer.
    static func members(_ preview: GroupInvitePreview) -> String {
        preview.memberCount <= 1 ? "Just \(preview.organizerName) so far." : "\(preview.memberCount) people in the group so far."
    }

    static let nameNote = "Your first name will show to the group."
    static let loading = "Opening the invite…"
    static let goneTitle = "This invite doesn't work any more"
    static let goneMessage = "Ask whoever sent it for a new link."
    static let offlineTitle = "Couldn't connect"
    static let offlineMessage = "Check your connection and try again."
    static let problemTitle = "Couldn't join this plan"
    static let problemMessage = "Something went wrong. Try again in a moment."
    static let needsAccountTitle = "Group plans need an account"
    static let needsAccountMessage = "Sign in with email or Apple to join this plan."
}

/// "Join Maya's plan for Saturday?" over the app, from "Add a link" or a link shared into
/// Plandit (GE-2). Join adds you and opens the group in Today; Not now leaves the link unused.
struct JoinGroupSheet: View {
    @Environment(SheetRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var model: JoinGroupModel

    init(token: String, groups: GroupPlanStore?) {
        _model = State(initialValue: JoinGroupModel(token: token, groups: groups))
    }

    private var isJoining: Bool {
        if case .joining = model.state { return true }
        return false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.md) {
                Icon(.users, size: 26)
                    .foregroundStyle(.ink)
                    .frame(width: 56, height: 56)
                    .background(Color.canvas, in: Circle())
                    .overlay(Circle().strokeBorder(Color.border))
                    .accessibilityHidden(true)
                content
            }
            .padding(Space.lg)
            .frame(maxWidth: ContentWidth.column, alignment: .topLeading)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .background(Color.surface)
        .presentationDetents([.large])
        .presentationBackground(Color.surface)
        .interactiveDismissDisabled(isJoining)
        .animation(.snappy(duration: 0.25), value: model.state)
        .task { await model.load() }
        .onChange(of: model.state) { _, state in
            if case .joined(let id) = state { router.openGroupPlan(id) }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .loading:
            HStack(spacing: Space.sm) {
                ProgressView()
                Text(JoinGroupText.loading).font(.bodyText).foregroundStyle(.inkMuted)
            }
            notNowButton
        case .ready(let preview), .joining(let preview):
            heading(JoinGroupText.question(preview, now: .now))
            message(JoinGroupText.members(preview))
            message(JoinGroupText.nameNote)
            Button {
                Task { await model.join() }
            } label: {
                HStack(spacing: Space.xs) {
                    if isJoining { ProgressView().controlSize(.small) }
                    Text(isJoining ? "Joining…" : "Join")
                }
            }
            .buttonStyle(.primary)
            .disabled(isJoining)
            .accessibilityIdentifier("join-group")
            notNowButton
                .disabled(isJoining)
        case .offline:
            heading(JoinGroupText.offlineTitle)
            message(JoinGroupText.offlineMessage)
            tryAgainButton
            notNowButton
        case .gone:
            heading(JoinGroupText.goneTitle)
            message(JoinGroupText.goneMessage)
            closeButton
        case .problem(let words):
            heading(JoinGroupText.problemTitle)
            message(words)
            tryAgainButton
            notNowButton
        case .needsAccount:
            heading(JoinGroupText.needsAccountTitle)
            message(JoinGroupText.needsAccountMessage)
            closeButton
        case .joined:
            // A moment, while the sheet closes onto Today.
            ProgressView()
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.sectionHeading)
            .foregroundStyle(.ink)
            .accessibilityAddTraits(.isHeader)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.bodyText)
            .foregroundStyle(.inkMuted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var notNowButton: some View {
        Button("Not now") { dismiss() }
            .buttonStyle(.secondary)
            .accessibilityIdentifier("join-not-now")
    }

    private var closeButton: some View {
        Button("Close") { dismiss() }
            .buttonStyle(.secondary)
            .accessibilityIdentifier("join-close")
    }

    private var tryAgainButton: some View {
        Button("Try again") {
            Task { await model.retry() }
        }
        .buttonStyle(.primary)
        .accessibilityIdentifier("join-try-again")
    }
}

/// Presents the join sheet for `router.inviteToJoin` from the always-on sheet, so it opens over
/// any tab: after "Add a link" closes, or when Plandit opens with an invite from the share sheet.
private struct JoinGroupPresenter: ViewModifier {
    @Environment(SheetRouter.self) private var router
    @Environment(GroupPlanStore.self) private var groups: GroupPlanStore?

    func body(content: Content) -> some View {
        @Bindable var router = router
        content
            .sheet(item: $router.inviteToJoin) { invite in
                JoinGroupSheet(token: invite.token, groups: groups)
            }
#if DEBUG
            .overlay(alignment: .topLeading) { GroupPlansProbe(groups: groups) }
#endif
    }
}

extension View {
    /// The join sheet for group plan invites (JN-1).
    func joinGroupSheet() -> some View {
        modifier(JoinGroupPresenter())
    }
}

#if DEBUG
/// UI tests with `-fakeGroupPlans`: the ids of the group plans this phone holds, for
/// `GroupJoinFlowTests` to read until Today shows group plans. Invisible, and nothing else sees it.
private struct GroupPlansProbe: View {
    let groups: GroupPlanStore?

    var body: some View {
        if let groups, CommandLine.arguments.contains(FakeGroupPlanServer.launchArgument) {
            Text(" ")
                .font(.system(size: 1))
                .foregroundStyle(.clear)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityLabel("groups:" + groups.groups.map(\.id.uuidString).joined(separator: ","))
                .accessibilityIdentifier("debug-group-plans")
        }
    }
}
#endif
