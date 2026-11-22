import Observation
import SwiftUI

/// Words about group plans waiting to be shown, one at a time: from `GroupPlanStore.onMessage`
/// (an edit someone else's change got in the way of, a group that ended) and from Today's own
/// edits that couldn't be made.
@Observable
final class GroupMessages {
    struct Item: Identifiable, Equatable {
        var id = UUID()
        var text: String
    }

    private(set) var queue: [Item] = []

    var current: Item? { queue.first }

    /// The same words twice in a row show once.
    func post(_ text: String) {
        guard queue.last?.text != text else { return }
        queue.append(Item(text: text))
    }

    func dismiss(_ id: UUID) {
        queue.removeAll { $0.id == id }
    }

    /// Every message the store has for the person comes here.
    func listen(to groups: GroupPlanStore) {
        groups.onMessage = { [weak self] message in
            self?.post(message.text)
        }
    }
}

/// A group plan message above the tab bar, like the Undo bar: it goes after a few seconds, or
/// with the close button. Nothing waits on it.
struct GroupMessageBar: View {
    @Environment(GroupMessages.self) private var messages: GroupMessages?
    static let seconds = 7

    var body: some View {
        Group {
            if let messages, let message = messages.current {
                HStack(spacing: Space.sm) {
                    Icon(.circleAlert, size: 18)
                        .foregroundStyle(.ink)
                        .accessibilityHidden(true)
                    Text(message.text)
                        .font(.label)
                        .foregroundStyle(.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("group-message")
                    Spacer(minLength: Space.xs)
                    Button {
                        withAnimation(.snappy) { messages.dismiss(message.id) }
                    } label: {
                        Icon(.x, size: 16)
                            .foregroundStyle(.inkMuted)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Close")
                    .accessibilityIdentifier("group-message-close")
                }
                .padding(.leading, Space.md)
                .planditCard(padding: Space.xxs)
                .background {
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .fill(Color.surface)
                        .floatingShadow()
                }
                .padding(.horizontal, Space.md)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: message.id) {
                    AccessibilityNotification.Announcement(message.text).post()
                    do { try await Task.sleep(for: .seconds(Self.seconds)) } catch { return }
                    withAnimation(.snappy) { messages.dismiss(message.id) }
                }
            }
        }
        .animation(.snappy, value: messages?.current?.id)
    }
}
