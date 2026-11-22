import SwiftUI

/// "The Met is done · Undo", above the tab bar for a few seconds after a change to today's plan.
struct UndoBar: View {
    @Environment(PlanditStore.self) private var store
    static let seconds = 6

    var body: some View {
        Group {
            if let undo = store.undo {
                HStack(spacing: Space.sm) {
                    Text(undo.message)
                        .font(.label)
                        .foregroundStyle(.ink)
                        .lineLimit(2)
                        .accessibilityIdentifier("undo-message")
                    Spacer(minLength: Space.xs)
                    if !store.canUndo {
                        // "Build our plan" is still going on friends' link: Undo comes back if that fails.
                        ProgressView()
                            .controlSize(.small)
                            .frame(minHeight: 44)
                            .accessibilityLabel("Putting the plan on the link")
                    } else {
                        Button {
                            withAnimation(.snappy) { store.undoLastChange() }
                        } label: {
                            HStack(spacing: Space.xxs) {
                                Icon(.undo, size: 16)
                                Text("Undo")
                            }
                            .font(.label)
                            .foregroundStyle(.emeraldDeep)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .accessibilityIdentifier("undo-button")
                    }
                }
                .padding(.horizontal, Space.md)
                .planditCard(padding: Space.xs)
                .background {
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .fill(Color.surface)
                        .floatingShadow()
                }
                .padding(.horizontal, Space.md)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: "\(undo.id)-\(store.canUndo)") {
                    // Cancelled when the bar steps aside for the keyboard: keep the undo, and give
                    // it its full time again when the bar comes back. Held back while the plan goes
                    // on friends' link, and timed again from when Undo is offered.
                    guard store.canUndo else { return }
                    do { try await Task.sleep(for: .seconds(Self.seconds)) } catch { return }
                    withAnimation(.snappy) { store.dismissUndo(undo.id) }
                }
            }
        }
        .animation(.snappy, value: store.undo?.id)
    }
}
