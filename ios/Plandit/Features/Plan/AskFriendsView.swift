import SwiftUI

/// "Ask friends what works" (group plans, mode 2), opened from the planner. Without a link: pick
/// saved places, a day, a time range and a deadline, and get the link to send (GI-1). With one:
/// friends' answers (GI-4) and "Build our plan" (GI-5 to GI-7).
struct AskFriendsView: View {
    @Environment(PlanditStore.self) private var store

    var body: some View {
        Group {
            if store.activeRequest() != nil {
                FriendsAnswersView()
            } else {
                AskFriendsForm()
            }
        }
        .background(Color.surface)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The words on the answers screen that depend on the link, apart so tests can read them.
enum AskFriendsText {
    /// "today" when the plan can be built now, otherwise the link's day in its own time zone:
    /// "Tuesday, November 24".
    static func day(_ link: PlanRequestLink, now: Date) -> String {
        if link.isToday(now: now), link.day == DayPlan.isoDay(now, calendar: .current) { return "today" }
        guard let date = link.dayDate else { return link.day }
        var style = Date.FormatStyle.dateTime.weekday(.wide).month(.wide).day()
        style.timeZone = link.calendar.timeZone
        return date.formatted(style)
    }

    static func status(_ link: PlanRequestLink, _ details: PlanRequest?, now: Date) -> String {
        switch details?.status {
        case .built?:
            // Built, then Stop sharing took the plan down: friends' link says it's closed.
            return details?.planSlug == nil
                ? "Your plan isn't shared anymore, so friends' link shows it's closed."
                : "Done. The link now opens your plan."
        case .closed?:
            return "Not taking answers any more. You can still build the plan."
        case .open?, nil:
            let deadline = details?.answersBy ?? link.answersBy
            let when = Calendar.current.isDate(deadline, inSameDayAs: now)
                ? deadline.shortTime : "\(deadline.shortDay), \(deadline.shortTime)"
            return "Friends can answer until \(when)."
        }
    }

    /// Goes with the link in the share sheet.
    static func shareMessage(_ link: PlanRequestLink, now: Date) -> String {
        let day = day(link, now: now)
        return "What works for you \(day == "today" ? "today" : "on \(day)")? Answer here and I'll make the plan."
    }

    /// The lowest budget, never whose it is.
    static func budget(_ plan: GroupInputs.Plan) -> String {
        "Budget: \(plan.budget.wholeDollarsText) each, the lowest anyone gave"
    }

    /// Next to the disabled "Build our plan" while times clash.
    static let clashHint = "Leave out someone's times above to build."

    /// Why "Build our plan" can't build now, or nil when it can: the link's day has gone by (the
    /// screen stayed open past midnight, say), or it's still ahead: "You can build it on Tue, Nov 24".
    static func notBuildable(_ link: PlanRequestLink, now: Date) -> String? {
        if link.isOver(now: now) {
            return "\(day(link, now: now)) is over, so this plan can't be built. Ask about another day to start again."
        }
        guard day(link, now: now) != "today" else { return nil }
        guard let date = link.dayDate else { return "You can build it on \(link.day)" }
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated).month(.abbreviated).day()
        style.timeZone = link.calendar.timeZone
        return "You can build it on \(date.formatted(style))"
    }

    /// The line next to "Build our plan" while it's off: the clash, or the day. None for "Try again".
    static func buildHint(_ link: PlanRequestLink, clash: Bool, needsLink: Bool, now: Date) -> String? {
        guard !needsLink else { return nil }
        return clash ? clashHint : notBuildable(link, now: now)
    }

    /// When the plan "Build our plan" made isn't Today's any more, so nothing went on the link.
    static let planChanged = "Today has a different plan now. Build our plan again."

    /// Above the preview of a plan for a later day.
    static func laterDay(_ link: PlanRequestLink, now: Date) -> String {
        "This is how the plan looks with the answers so far. You can build it on \(day(link, now: now))."
    }
}

// MARK: - Making the link

private struct AskFriendsForm: View {
    @Environment(PlanditStore.self) private var store
    @Environment(SheetRouter.self) private var router
    /// Picked post ids, in the order they were picked: friends see them in this order.
    @State private var picked: [UUID] = []
    @State private var day = Calendar.current.startOfDay(for: AppClock.now)
    @State private var from = ClockTime(12)
    @State private var until = ClockTime(20)
    @State private var answersBy = AppClock.now
    /// Once the organizer sets the deadline, changing the day or times no longer moves it.
    @State private var setsOwnDeadline = false
    @State private var didSetUp = false
    @State private var isWorking = false
    @State private var errorText: String?

    var body: some View {
        let problem = self.problem
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    Text("Pick the places and the time. Friends answer with when they're free, what they can spend and their favorite picks. Then Plandit plans a day that works for everyone.")
                        .font(.bodyText)
                        .foregroundStyle(.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    placesSection
                    whenSection
                    if let problem {
                        Text(problem)
                            .font(.metadata)
                            .foregroundStyle(.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("ask-problem")
                    }
                    if let errorText {
                        Text(errorText)
                            .font(.metadata)
                            .foregroundStyle(Color.error)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("ask-error")
                    }
                }
                .padding(Space.lg)
                .animation(.snappy(duration: 0.3), value: picked)
            }
            .scrollIndicators(.hidden)

            VStack(spacing: 0) {
                Hairline()
                Button {
                    Task { await create() }
                } label: {
                    HStack(spacing: Space.xs) {
                        if isWorking { ProgressView().controlSize(.small) } else { Icon(.link, size: 18) }
                        Text(isWorking ? "One moment…" : "Get the link")
                    }
                }
                .buttonStyle(.primary)
                .disabled(problem != nil || isWorking)
                .accessibilityIdentifier("ask-create")
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.sm)
            }
            .background(Color.surface)
        }
        .navigationTitle("Ask friends what works")
        .onAppear(perform: setUp)
        .onChange(of: day) { fitTimes() }
        .onChange(of: from) { moveDeadline() }
        .onChange(of: until) { moveDeadline() }
    }

    private var placesSection: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle("Places")
                Spacer()
                Text("\(picked.count) picked").font(.metadata).foregroundStyle(.inkMuted)
            }
            Text("Pick 2 to 10. Friends see each place's name, area and cost, and star their favorites.")
                .font(.metadata)
                .foregroundStyle(.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            if store.plannablePosts.count < PlanRequestDraft.minPlaces {
                // The planner's own way to saving, as in its empty state.
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text("You need at least 2 saved places to ask friends.")
                        .font(.bodyText)
                        .foregroundStyle(.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("ask-needs-places")
                    Button {
                        router.isPlanning = false
                        router.show(.saved)
                    } label: {
                        HStack(spacing: Space.xs) {
                            Icon(.bookmark, size: 18)
                            Text("Go to Saved")
                        }
                    }
                    .buttonStyle(.secondary)
                }
                .padding(.vertical, Space.xs)
            }
            ForEach(store.plannablePosts) { post in
                PickRow(post: post, isPicked: picked.contains(post.id), isLocked: false, idPrefix: "ask-pick") { toggle(post.id) }
                Hairline()
            }
        }
    }

    private var whenSection: some View {
        let today = Calendar.current.startOfDay(for: AppClock.now)
        let lastDay = Calendar.current.date(byAdding: .day, value: PlanRequestDraft.maxDaysAhead, to: today) ?? today
        let now = AppClock.now
        let end = windowEnd
        return VStack(alignment: .leading, spacing: Space.sm) {
            SectionTitle("When")
            VStack(spacing: 0) {
                row(.calendarDays, "Day") {
                    DatePicker("Day", selection: $day, in: today...lastDay, displayedComponents: .date)
                        .labelsHidden()
                        .accessibilityIdentifier("ask-day")
                }
                Hairline()
                row(.clock, "From") {
                    DatePicker("From", selection: clockBinding($from), displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .accessibilityIdentifier("ask-from")
                }
                Hairline()
                row(.clock, "Until") {
                    DatePicker("Until", selection: clockBinding($until), displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .accessibilityIdentifier("ask-until")
                }
                Hairline()
                row(.users, "Answers by") {
                    DatePicker("Answers by", selection: deadlineBinding, in: now...max(now, end),
                               displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                        .accessibilityIdentifier("ask-deadline")
                }
            }
            .planditCard(padding: Space.sm)
            Text("After the deadline, the link stops taking answers. You can build the plan on the day, with whoever answered.")
                .font(.metadata)
                .foregroundStyle(.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row<Control: View>(_ icon: Lucide, _ title: String, @ViewBuilder control: () -> Control) -> some View {
        HStack {
            Label { Text(title).font(.bodyText) } icon: { Icon(icon, size: 18) }
                .foregroundStyle(.ink)
            Spacer(minLength: Space.xs)
            control()
        }
        .frame(minHeight: 48)
    }

    // MARK: - State

    private var isToday: Bool { Calendar.current.isDate(day, inSameDayAs: AppClock.now) }
    private var windowStart: Date { from.date(on: day) ?? day }
    private var windowEnd: Date { until.date(on: day) ?? day }

    /// Why the link can't be made yet, in the order the organizer fills the form; nil when it can.
    private var problem: String? {
        let now = AppClock.now
        if picked.count < PlanRequestDraft.minPlaces { return "Pick at least 2 places." }
        if picked.count > PlanRequestDraft.maxPlaces { return "Pick up to 10 places." }
        if until.minutes - from.minutes < PlanRequestDraft.minWindowMinutes { return "Leave at least an hour between from and until." }
        if windowEnd <= now { return "That time has passed. Pick a later time or another day." }
        if answersBy <= now { return "Pick an answer deadline that hasn't passed." }
        if answersBy > windowEnd { return "Answers need to be in before the time ends." }
        return nil
    }

    /// The time on the chosen day as a `Date` for the pickers, which only change its time.
    private func clockBinding(_ clock: Binding<ClockTime>) -> Binding<Date> {
        Binding(
            get: { clock.wrappedValue.date(on: day) ?? day },
            set: { clock.wrappedValue = ClockTime(of: $0) }
        )
    }

    private var deadlineBinding: Binding<Date> {
        Binding(get: { answersBy }, set: {
            answersBy = $0
            setsOwnDeadline = true
        })
    }

    private func setUp() {
        guard !didSetUp else { return }
        didSetUp = true
        fitTimes()
        answersBy = defaultDeadline
    }

    /// For today, the range starts no earlier than the next quarter hour.
    private func fitTimes() {
        if isToday {
            let next = ClockTime(of: PlanDefaults.nextQuarterHour(after: AppClock.now))
            if from < next, next.minutes < 23 * 60 {
                from = next
                if until.minutes - from.minutes < 2 * 60 { until = ClockTime(minutes: min(from.minutes + 2 * 60, 23 * 60 + 45)) }
            }
        }
        moveDeadline()
    }

    private func moveDeadline() {
        if setsOwnDeadline {
            answersBy = min(answersBy, windowEnd)
        } else {
            answersBy = defaultDeadline
        }
    }

    private var defaultDeadline: Date {
        PlanRequestDraft.defaultDeadline(now: AppClock.now, isToday: isToday, windowStart: windowStart, windowEnd: windowEnd)
    }

    private func toggle(_ id: UUID) {
        if let index = picked.firstIndex(of: id) {
            picked.remove(at: index)
        } else {
            picked.append(id)
        }
    }

    private func create() async {
        isWorking = true
        errorText = nil
        defer { isWorking = false }
        let posts = picked.compactMap { store.post(id: $0) }
        let draft = PlanRequestDraft(posts: posts, day: day, start: from, end: until, answersBy: answersBy)
        do {
            try await store.createPlanRequest(draft, answersBy: answersBy)
        } catch {
            errorText = "Couldn't make the link. Check your connection and try again."
        }
    }
}

// MARK: - Friends' answers and Build our plan

private struct FriendsAnswersView: View {
    @Environment(PlanditStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(SheetRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    /// The organizer's own budget and times (GI-5); nil until they change them.
    @State private var organizer: GroupInputs.Person?
    /// Friends whose times the organizer left out (GI-6).
    @State private var leftOut: Set<GroupMember> = []
    @State private var removing: GroupAnswer?
    @State private var removingIDs: Set<UUID> = []
    @State private var confirmsClose = false
    @State private var confirmsDiscard = false
    @State private var isWorking = false
    @State private var didCopyLink = false
    @State private var errorText: String?
    @State private var built = 0
    /// Bumped when a tap finds the day changed under the screen, so it shows the day as it is now.
    @State private var clockChecks = 0

    var body: some View {
        Group {
            if let link = store.planRequest {
                content(link)
            }
        }
        .navigationTitle("Friends' answers")
        .task { await store.refreshPlanRequest() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await store.refreshPlanRequest() } }
        }
        .confirmationDialog(
            removing.map { "Remove \($0.name)'s answer?" } ?? "",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible,
            presenting: removing
        ) { answer in
            Button("Remove", role: .destructive) { Task { await remove(answer) } }
                .accessibilityIdentifier("confirm-remove-answer")
        } message: { _ in
            Text("It won't count toward the plan.")
        }
        .confirmationDialog("Stop taking answers?", isPresented: $confirmsClose, titleVisibility: .visible) {
            Button("Stop taking answers", role: .destructive) { Task { await close() } }
                .accessibilityIdentifier("confirm-close-request")
        } message: {
            Text("Friends who haven't answered won't be able to. You can still build the plan.")
        }
        .confirmationDialog("Delete this link?", isPresented: $confirmsDiscard, titleVisibility: .visible) {
            Button("Delete link", role: .destructive) { Task { await discard(.delete) } }
                .accessibilityIdentifier("confirm-delete-request")
        } message: {
            Text("Friends' answers are deleted and the link stops working.")
        }
        .sensoryFeedback(.success, trigger: built)
        // Swiping the planner down mid-build would leave the plan half on the link (review R1).
        .interactiveDismissDisabled(isWorking)
    }

    private func content(_ link: PlanRequestLink) -> some View {
        let details = store.requestDetails
        let isBuilt = details?.status == .built
        let me = organizer ?? store.organizerInputs(for: link)
        let result = store.groupInputs(organizer: me, leftOut: leftOut)
        let plan = result.flatMap(\.plan)
        let outcome = plan.flatMap { store.previewGroupPlan($0) }
        _ = clockChecks
        let canBuild = store.canBuildGroupPlan()
        // Built into Today, but the link didn't get it: "Try again" only puts it on the link.
        let needsLink = store.groupPlanAwaitsLink
        let isClash: Bool = { if case .clash? = result { return true } else { return false } }()
        let buildHint = isBuilt ? nil : AskFriendsText.buildHint(link, clash: isClash, needsLink: needsLink, now: AppClock.now)
        // At the largest sizes the line would take a quarter of the screen over the answers: it
        // goes last in the list instead, right above the button once scrolled to the end.
        let pinsHint = !typeSize.isAccessibilitySize
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    linkCard(link, details)
                    answersSection(details, canRemove: !isBuilt)
                    if !isBuilt {
                        youSection(link, me)
                        planSection(link, result, outcome, canBuild: canBuild)
                    }
                    if let errorText {
                        Text(errorText)
                            .font(.metadata)
                            .foregroundStyle(Color.error)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("request-error")
                    }
                    footer(link, details)
                    if !pinsHint, let buildHint {
                        buildHintText(buildHint, isClash: isClash)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Space.lg)
                .animation(.snappy, value: details?.answers.map(\.id))
            }
            .scrollIndicators(.hidden)
            .refreshable { await store.refreshPlanRequest(force: true) }

            if !isBuilt {
                VStack(spacing: 0) {
                    Hairline()
                    if pinsHint, let buildHint {
                        buildHintText(buildHint, isClash: isClash)
                            .padding(.horizontal, Space.lg)
                            .padding(.top, Space.sm)
                    }
                    Button {
                        Task { await build(plan, onlyShare: needsLink) }
                    } label: {
                        HStack(spacing: Space.xs) {
                            if isWorking { ProgressView().controlSize(.small) }
                            Text(isWorking ? "One moment…" : (needsLink ? "Try again" : "Build our plan"))
                        }
                    }
                    .buttonStyle(.primary)
                    .disabled(isWorking || (!needsLink && (!canBuild || (outcome?.stops.isEmpty ?? true))))
                    .accessibilityHint("Puts the plan in Today and on the link")
                    .accessibilityIdentifier("build-our-plan")
                    .padding(.horizontal, Space.lg)
                    .padding(.vertical, Space.sm)
                }
                .background(Color.surface)
            }
        }
    }

    /// The line next to "Build our plan" while it's off (`AskFriendsText.buildHint`).
    private func buildHintText(_ text: String, isClash: Bool) -> some View {
        Text(text)
            .font(.metadata)
            .foregroundStyle(.inkMuted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(isClash ? "build-clash-hint" : "build-day-hint")
    }

    // MARK: - Link

    private func linkCard(_ link: PlanRequestLink, _ details: PlanRequest?) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            SectionTitle("Link")
            Text(link.url.absoluteString)
                .font(.label)
                .foregroundStyle(.ink)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Space.sm)
                .background(Color.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Color.border))
                .accessibilityLabel("Link: \(link.url.absoluteString)")
                .accessibilityIdentifier("request-link-url")
            Text("For \(AskFriendsText.day(link, now: AppClock.now)), \(rangeText(link)).")
                .font(.metadata)
                .foregroundStyle(.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            Text(AskFriendsText.status(link, details, now: AppClock.now))
                .font(.metadata)
                .foregroundStyle(.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("request-status")
            if details?.status != .built {
                // Side by side, or one above the other at accessibility sizes.
                let buttons = typeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(spacing: Space.sm))
                    : AnyLayout(HStackLayout(spacing: Space.sm))
                buttons {
                    Button {
                        UIPasteboard.general.url = link.url
                        didCopyLink = true
                    } label: {
                        Text(didCopyLink ? "Copied" : "Copy link")
                    }
                    .buttonStyle(.secondary)
                    .accessibilityIdentifier("request-copy-link")
                    ShareLink(item: link.url, message: Text(AskFriendsText.shareMessage(link, now: AppClock.now))) {
                        HStack(spacing: Space.xs) {
                            Icon(.share, size: 18)
                            Text("Send link")
                        }
                    }
                    .buttonStyle(.primary)
                    .accessibilityIdentifier("request-send-link")
                }
            }
        }
        .planditCard()
    }

    private func rangeText(_ link: PlanRequestLink) -> String {
        guard let start = link.start, let end = link.end else { return "" }
        return "\(start.shortTime) to \(end.shortTime)"
    }

    // MARK: - Answers (GI-4)

    @ViewBuilder private func answersSection(_ details: PlanRequest?, canRemove: Bool) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle("Answers")
                Spacer()
                if let count = details?.answers.count, count > 0 {
                    Text(count == 1 ? "1 friend" : "\(count) friends").font(.metadata).foregroundStyle(.inkMuted)
                }
            }
            if let details {
                if details.answers.isEmpty {
                    Text("No answers yet. You can build the plan on the day with whoever has answered.")
                        .font(.bodyText)
                        .foregroundStyle(.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("request-answers-empty")
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(details.answers.enumerated()), id: \.element.id) { index, answer in
                            if index > 0 { Hairline() }
                            answerRow(answer, canRemove: canRemove)
                                .padding(.vertical, Space.xs)
                        }
                    }
                    .planditCard(padding: Space.sm)
                }
            } else if store.requestFetchFailed {
                // Nothing to plan from until the answers are read: Build stays off.
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text("Couldn't get the answers. Check your connection and try again.")
                        .font(.metadata)
                        .foregroundStyle(Color.error)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("request-fetch-error")
                    Button("Try again") {
                        Task { await store.refreshPlanRequest(force: true) }
                    }
                    .buttonStyle(.secondary)
                    .accessibilityIdentifier("request-fetch-retry")
                }
            } else {
                HStack(spacing: Space.xs) {
                    ProgressView().controlSize(.small)
                    Text("Getting answers…").font(.metadata).foregroundStyle(.inkMuted)
                }
            }
        }
    }

    private func answerRow(_ answer: GroupAnswer, canRemove: Bool) -> some View {
        HStack(alignment: .center, spacing: Space.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(answer.name)
                    .font(.bodyText)
                    .foregroundStyle(.ink)
                Text("\(Double(answer.budget).wholeDollarsText) · free \(answer.freeFrom.shortTime) to \(answer.freeUntil.shortTime)")
                    .font(.metadata)
                    .foregroundStyle(.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Text(starsText(answer))
                    .font(.metadata)
                    .foregroundStyle(.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("answer-\(answer.name)")
            Spacer(minLength: 0)
            if canRemove {
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
        }
        .frame(minHeight: 44)
    }

    /// "Starred Levain Bakery and The High Line", in the organizer's order.
    private func starsText(_ answer: GroupAnswer) -> String {
        let starred = Set(answer.stars)
        let names = (store.planRequest?.placeIDs ?? []).filter(starred.contains).compactMap { store.post(id: $0)?.place?.name }
        return names.isEmpty ? "No stars" : "Starred \(names.formatted(.list(type: .and)))"
    }

    // MARK: - The organizer (GI-5)

    private func youSection(_ link: PlanRequestLink, _ me: GroupInputs.Person) -> some View {
        let first = link.start ?? ClockTime(0), last = link.end ?? ClockTime(23, 59)
        return VStack(alignment: .leading, spacing: Space.sm) {
            SectionTitle("You")
            VStack(spacing: 0) {
                HStack {
                    Label { Text("Free from").font(.bodyText) } icon: { Icon(.clock, size: 18) }
                        .foregroundStyle(.ink)
                    Spacer(minLength: Space.xs)
                    DatePicker("Free from", selection: myTime(\.from, me), in: date(first)...date(last), displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .accessibilityIdentifier("my-from")
                }
                .frame(minHeight: 48)
                Hairline()
                HStack {
                    Label { Text("Free until").font(.bodyText) } icon: { Icon(.clock, size: 18) }
                        .foregroundStyle(.ink)
                    Spacer(minLength: Space.xs)
                    DatePicker("Free until", selection: myTime(\.until, me), in: date(first)...date(last), displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .accessibilityIdentifier("my-until")
                }
                .frame(minHeight: 48)
                Hairline()
                HStack {
                    Label { Text("Your budget").font(.bodyText) } icon: { Icon(.wallet, size: 18) }
                        .foregroundStyle(.ink)
                    Spacer()
                    Text(me.budget.wholeDollarsText)
                        .font(.manrope(.bold, size: 17))
                        .foregroundStyle(.ink)
                        .contentTransition(.numericText())
                        .accessibilityIdentifier("my-budget")
                    Stepper("Your budget", value: myBudget(me), in: 0...300, step: 5)
                        .labelsHidden()
                }
                .frame(minHeight: 48)
            }
            .planditCard(padding: Space.sm)
        }
    }

    private func date(_ clock: ClockTime) -> Date { clock.date(on: AppClock.now) ?? AppClock.now }

    private func myTime(_ keyPath: WritableKeyPath<GroupInputs.Person, ClockTime>, _ me: GroupInputs.Person) -> Binding<Date> {
        Binding(
            get: { date(me[keyPath: keyPath]) },
            set: { value in
                var changed = organizer ?? me
                changed[keyPath: keyPath] = ClockTime(of: value)
                organizer = changed
            }
        )
    }

    private func myBudget(_ me: GroupInputs.Person) -> Binding<Double> {
        Binding(
            get: { me.budget },
            set: { value in
                var changed = organizer ?? me
                changed.budget = value
                withAnimation(.snappy) { organizer = changed }
            }
        )
    }

    // MARK: - The plan (GI-5, GI-6)

    @ViewBuilder private func planSection(_ link: PlanRequestLink, _ result: GroupInputs.Result?, _ outcome: DayPlanner.Outcome?,
                                          canBuild: Bool) -> some View {
        switch result {
        case .clash(let members)?:
            clashCard(members)
        case .ready(let plan)?:
            VStack(alignment: .leading, spacing: Space.lg) {
                VStack(alignment: .leading, spacing: Space.sm) {
                    SectionTitle("Our plan")
                    VStack(alignment: .leading, spacing: Space.sm) {
                        VStack(alignment: .leading, spacing: Space.xs) {
                            Text("Everyone's free \(plan.start.shortTime) to \(plan.end.shortTime).")
                                .font(.bodyText)
                                .foregroundStyle(.ink)
                            Text(AskFriendsText.budget(plan))
                                .font(.bodyText)
                                .foregroundStyle(.ink)
                            if plan.candidates.contains(where: { $0.stars > 0 }) {
                                Text("The most-starred places go in first.")
                                    .font(.metadata)
                                    .foregroundStyle(.inkMuted)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("group-inputs")
                        leftOutToggles(Set(leftOut.compactMap(\.friendID)))
                    }
                    .planditCard()
                }
                if let outcome {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        if !canBuild {
                            // A later day: the plan as it looks so far, on that day's hours (D1).
                            Text(AskFriendsText.laterDay(link, now: AppClock.now))
                                .font(.metadata)
                                .foregroundStyle(.inkMuted)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("request-later-day")
                        }
                        PlanPreview(outcome: outcome, lockedCount: 0, spent: outcome.cost + (canBuild ? store.today.extras.total : 0),
                                    budget: plan.budget, end: link.dayDate.flatMap { plan.end.date(on: $0, calendar: link.calendar) })
                    }
                }
            }
        case nil:
            EmptyView()
        }
    }

    private func clashCard(_ members: [GroupMember]) -> some View {
        let names = members.map(name(of:))
        let friends = Set(members.compactMap(\.friendID)).union(leftOut.compactMap(\.friendID))
        return VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .top, spacing: Space.xs) {
                Icon(.circleAlert, size: 18).padding(.top, 2)
                Text("These times don't overlap by an hour: \(names.formatted(.list(type: .and))).")
                    .font(.bodyText)
            }
            .foregroundStyle(.ink)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("group-clash")
            Text("Leave someone's times out and Plandit plans around everyone else. Their budget and stars still count.")
                .font(.metadata)
                .foregroundStyle(.inkMuted)
            leftOutToggles(friends)
            if members.contains(.organizer) {
                Text("Your own times clash too. Change them above.")
                    .font(.metadata)
                    .foregroundStyle(.inkMuted)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .planditCard()
    }

    /// A "Leave out Maya's times" switch for each of these friends, in answer order.
    @ViewBuilder private func leftOutToggles(_ friends: Set<UUID>) -> some View {
        ForEach((store.requestDetails?.answers ?? []).filter { friends.contains($0.id) }) { answer in
            Toggle(isOn: Binding(
                get: { leftOut.contains(.friend(answer.id)) },
                set: { isOn in
                    withAnimation(.snappy) {
                        if isOn { leftOut.insert(.friend(answer.id)) } else { leftOut.remove(.friend(answer.id)) }
                    }
                }
            )) {
                Text("Leave out \(answer.name)'s times").font(.bodyText).foregroundStyle(.ink)
            }
            .tint(.emerald)
            .accessibilityIdentifier("leave-out-\(answer.name)")
        }
    }

    private func name(of member: GroupMember) -> String {
        switch member {
        case .organizer: return "you"
        case .friend(let id): return store.requestDetails?.answers.first { $0.id == id }?.name ?? "a friend"
        }
    }

    // MARK: - Footer

    private func footer(_ link: PlanRequestLink, _ details: PlanRequest?) -> some View {
        VStack(spacing: Space.sm) {
            if details?.status == .open {
                Button(role: .destructive) {
                    errorText = nil
                    confirmsClose = true
                } label: {
                    Text("Stop taking answers")
                        .font(.label)
                        .foregroundStyle(.error)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .disabled(isWorking)
                .accessibilityHint("Friends can't answer after this")
                .accessibilityIdentifier("request-close")
            }
            Button {
                errorText = nil
                Task { await askAboutAnotherDay() }
            } label: {
                Text("Ask about another day")
                    .font(.label)
                    .foregroundStyle(.ink)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .disabled(isWorking)
            // What happens is decided by the server's answer after the tap, so this holds either way.
            .accessibilityHint("Deletes this link and its answers, unless it opens your plan")
            .accessibilityIdentifier("request-new")
        }
    }

    // MARK: - Actions

    private func build(_ plan: GroupInputs.Plan?, onlyShare: Bool) async {
        // The screen may have stayed open past midnight: Build looked on, but the day has changed.
        // Show the day as it is now (the line next to Build says why) instead of doing nothing.
        if !onlyShare, !store.canBuildGroupPlan() {
            clockChecks += 1
            if let link = store.planRequest, let why = AskFriendsText.notBuildable(link, now: AppClock.now) {
                AccessibilityNotification.Announcement(why).post()
            }
            return
        }
        isWorking = true
        errorText = nil
        defer { isWorking = false }
        if !onlyShare {
            guard let plan else { return }
            _ = withAnimation(.snappy(duration: 0.35)) { store.buildGroupPlan(plan) }
            guard store.groupPlanAwaitsLink else { return }
        }
        do {
            try await store.shareGroupPlan()
            built += 1
            router.finishPlanning()
        } catch PlanditStore.GroupShareError.planChanged {
            // Not a connection problem: Today has another plan, and Build is offered again (N1).
            errorText = AskFriendsText.planChanged
        } catch {
            errorText = "Your plan is in Today, but it isn't on the link yet. Check your connection and try again."
        }
    }

    private func remove(_ answer: GroupAnswer) async {
        removingIDs.insert(answer.id)
        defer { removingIDs.remove(answer.id) }
        do {
            try await store.removeRequestAnswer(answer.id)
            leftOut.remove(.friend(answer.id))
        } catch {
            errorText = "Couldn't remove the answer. Check your connection and try again."
        }
    }

    private func close() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await store.closePlanRequest()
        } catch {
            errorText = "Couldn't stop answers. Check your connection and try again."
        }
    }

    /// Asks the server first: a link that opens a plan is let go of, one that doesn't is deleted
    /// once the organizer confirms. If the server can't be reached, the link stays and they're told.
    private func askAboutAnotherDay() async {
        isWorking = true
        defer { isWorking = false }
        do {
            switch try await store.discardKind() {
            case .delete: confirmsDiscard = true
            case .forget: try await store.discardPlanRequest(.forget)
            }
        } catch {
            errorText = "Couldn't check the link. Check your connection and try again."
        }
    }

    private func discard(_ kind: PlanditStore.RequestDiscard) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await store.discardPlanRequest(kind)
        } catch {
            errorText = "Couldn't delete the link. Check your connection and try again."
        }
    }
}

private extension GroupInputs.Result {
    var plan: GroupInputs.Plan? {
        if case .ready(let plan) = self { return plan }
        return nil
    }
}

private extension GroupMember {
    var friendID: UUID? {
        if case .friend(let id) = self { return id }
        return nil
    }
}

private extension ClockTime {
    /// "1:30 PM", in the phone's time format.
    var shortTime: String { date(on: AppClock.now)?.shortTime ?? text }
}
