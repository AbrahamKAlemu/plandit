import SwiftUI
import UIKit

/// Who's in a group plan, as letters in Today's header. Opens the members sheet.
struct GroupMembersButton: View {
    let group: GroupPlanState
    let action: () -> Void

    var body: some View {
        let shown = Array(group.members.prefix(3))
        let more = group.members.count - shown.count
        Button(action: action) {
            HStack(spacing: -10) {
                ForEach(shown) { member in
                    MemberInitial(name: member.name, size: 34)
                }
                if more > 0 {
                    Text("+\(more)")
                        .font(.metadata)
                        .foregroundStyle(.ink)
                        .frame(width: 34, height: 34)
                        .background(Color.canvas, in: Circle())
                        .overlay(Circle().strokeBorder(Color.border))
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(GroupMembersText.spokenList(group.members))
        .accessibilityHint("Shows who's in this plan")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("group-members")
    }
}

/// One member's first letter in a circle.
struct MemberInitial: View {
    let name: String
    var size: CGFloat = 34

    var body: some View {
        Text(GroupToday.initials(name))
            .font(.label)
            .foregroundStyle(.ink)
            .frame(width: size, height: size)
            .background(Color.canvas, in: Circle())
            .overlay(Circle().strokeBorder(Color.border))
            .background(Color.surface, in: Circle().inset(by: -2))
    }
}

enum GroupMembersText {
    /// "Who's in: Maya, Sofia and Jordan".
    static func spokenList(_ members: [GroupPlanMember]) -> String {
        "Who's in: " + members.map { GroupToday.firstName($0.name) }.formatted(.list(type: .and))
    }

    static let shareMessage = "Let's plan today together on Plandit. Open the link to see the plan and change it with me."
    static let organizerCantLeave = "You're the organizer, so you can end the plan but not leave it."
}

/// The members of a group plan. The organizer can remove someone, get a new link and end the
/// plan; anyone else can leave. Each of those asks first.
struct GroupMembersSheet: View {
    let groupID: UUID
    @Environment(GroupPlanStore.self) private var groups: GroupPlanStore?
    @Environment(GroupMessages.self) private var messages: GroupMessages?
    @TodayContext private var today
    @Environment(\.dismiss) private var dismiss
    @State private var confirming: Confirmation?
    @State private var isWorking = false
    @State private var error: String?

    private enum Confirmation: Identifiable, Equatable {
        case remove(GroupPlanMember)
        case newLink
        case end
        case leave

        var id: String {
            switch self {
            case .remove(let member): "remove-\(member.id)"
            case .newLink: "new-link"
            case .end: "end"
            case .leave: "leave"
            }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let group = groups?.group(groupID) {
                    content(group)
                } else {
                    ContentUnavailableView("Plan ended", image: "Icons/users",
                                           description: Text(GroupPlanStore.text(for: .groupGone)))
                }
            }
            .background(Color.surface)
            .navigationTitle("Who's in")
            .navigationBarTitleDisplayMode(.inline)
            .solidSheetHeader()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("group-members-done")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Color.surface)
        .confirmationDialog(confirmTitle, isPresented: isConfirming, titleVisibility: .visible, presenting: confirming) { confirmation in
            confirmButtons(confirmation)
        } message: { confirmation in
            Text(confirmMessage(confirmation))
        }
    }

    private func content(_ group: GroupPlanState) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                VStack(spacing: 0) {
                    ForEach(group.members) { member in
                        memberRow(member, in: group)
                        if member.id != group.members.last?.id { Hairline() }
                    }
                }
                .planditCard(padding: Space.sm)

                if let error {
                    Text(error)
                        .font(.metadata)
                        .foregroundStyle(Color.error)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("group-error")
                }

                if group.isOrganizer {
                    inviteSection(group)
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text(GroupMembersText.organizerCantLeave)
                            .font(.metadata)
                            .foregroundStyle(.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("organizer-cant-leave")
                        destructiveButton("End the plan", id: "group-end") { confirming = .end }
                    }
                } else {
                    destructiveButton("Leave the plan", id: "group-leave") { confirming = .leave }
                }
            }
            .padding(Space.lg)
        }
        .scrollIndicators(.hidden)
        .disabled(isWorking)
        .overlay {
            if isWorking { ProgressView().accessibilityLabel("Working") }
        }
    }

    private func memberRow(_ member: GroupPlanMember, in group: GroupPlanState) -> some View {
        let isYou = member.id == group.memberId
        return HStack(spacing: Space.sm) {
            MemberInitial(name: member.name, size: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(isYou ? "\(GroupToday.firstName(member.name)) (you)" : GroupToday.firstName(member.name))
                    .font(.bodyText)
                    .foregroundStyle(.ink)
                if member.isOrganizer {
                    Text("Organizer")
                        .font(.metadata)
                        .foregroundStyle(.inkMuted)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("member-\(GroupToday.firstName(member.name))")
            Spacer(minLength: Space.xs)
            if group.isOrganizer && !isYou && !member.isOrganizer {
                Button {
                    confirming = .remove(member)
                } label: {
                    Text("Remove")
                        .font(.label)
                        .foregroundStyle(Color.error)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(GroupToday.firstName(member.name))")
                .accessibilityIdentifier("remove-member-\(GroupToday.firstName(member.name))")
            }
        }
        .frame(minHeight: 44)
    }

    @ViewBuilder private func inviteSection(_ group: GroupPlanState) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            SectionTitle("Invite link")
            if let link = group.inviteUrl {
                Text(link.absoluteString)
                    .font(.metadata)
                    .foregroundStyle(.inkMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("group-invite-url")
                ShareLink(item: link, message: Text(GroupMembersText.shareMessage)) {
                    HStack(spacing: Space.xs) {
                        Icon(.share, size: 18)
                        Text("Send the link")
                    }
                }
                .buttonStyle(.secondary)
                .accessibilityIdentifier("group-send-link")
            }
            Button {
                confirming = .newLink
            } label: {
                Text("Get a new link")
                    .font(.label)
                    .foregroundStyle(.ink)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .accessibilityHint("The old link stops working")
            .accessibilityIdentifier("group-new-link")
        }
    }

    private func destructiveButton(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(role: .destructive, action: action) {
            Text(title)
                .font(.label)
                .foregroundStyle(.error)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .accessibilityIdentifier(id)
    }

    // MARK: - Confirming

    private var isConfirming: Binding<Bool> {
        Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })
    }

    private var confirmTitle: String {
        switch confirming {
        case .remove(let member)?: "Remove \(GroupToday.firstName(member.name))?"
        case .newLink?: "Get a new link?"
        case .end?: "End the plan?"
        case .leave?: "Leave \(today.label ?? "this plan")?"
        case nil: ""
        }
    }

    private func confirmMessage(_ confirmation: Confirmation) -> String {
        switch confirmation {
        case .remove(let member):
            "\(GroupToday.firstName(member.name)) won't see this plan anymore and can't join it again."
        case .newLink:
            "The old link stops working. Everyone already in the plan stays in."
        case .end:
            "Ending the plan removes it for everyone."
        case .leave:
            "It goes away from your Today. You can join again with the link."
        }
    }

    @ViewBuilder private func confirmButtons(_ confirmation: Confirmation) -> some View {
        switch confirmation {
        case .remove(let member):
            Button("Remove \(GroupToday.firstName(member.name))", role: .destructive) { run(.remove(member)) }
                .accessibilityIdentifier("confirm-remove")
        case .newLink:
            Button("Get a new link") { run(.newLink) }
                .accessibilityIdentifier("confirm-new-link")
        case .end:
            Button("End the plan", role: .destructive) { run(.end) }
                .accessibilityIdentifier("confirm-end")
        case .leave:
            Button("Leave the plan", role: .destructive) { run(.leave) }
                .accessibilityIdentifier("confirm-leave")
        }
        Button("Cancel", role: .cancel) {}
    }

    private func run(_ confirmation: Confirmation) {
        guard let groups, !isWorking else { return }
        let label = today.label
        isWorking = true
        error = nil
        Task {
            defer { isWorking = false }
            switch confirmation {
            case .remove(let member):
                if case .failure(let failure) = await groups.remove(member: member.id, from: groupID) {
                    error = GroupToday.failureText(failure, for: .remove(member.name))
                }
            case .newLink:
                if case .failure(let failure) = await groups.newInviteLink(groupID) {
                    error = GroupToday.failureText(failure, for: .newLink)
                }
            case .end:
                switch await groups.end(groupID) {
                case .success:
                    messages?.post("You ended the plan.")
                    dismiss()
                case .failure(let failure):
                    error = GroupToday.failureText(failure, for: .end)
                }
            case .leave:
                switch await groups.leave(groupID) {
                case .success:
                    messages?.post(label.map { "You left \($0)." } ?? "You left the plan.")
                    dismiss()
                case .failure(let failure):
                    error = GroupToday.failureText(failure, for: .leave)
                }
            }
        }
    }
}

/// The system share sheet with a group plan's link, opened right after the plan is made.
enum InviteShareSheet {
    static func present(_ link: URL) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              var top = scene.keyWindow?.rootViewController else { return }
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        let controller = UIActivityViewController(activityItems: [GroupMembersText.shareMessage, link], applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        top.present(controller, animated: true)
    }
}
