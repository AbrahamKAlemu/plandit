import SwiftUI
import UIKit

/// Send today's plan as a message: add a note, choose what to include, see the exact text, then pick
/// Messages, WhatsApp or anything else from the share sheet, or copy it.
struct SendPlanSheet: View {
    @Environment(PlanditStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var options = PlanMessageOptions()
    @State private var didLoad = false
    @State private var didCopy = false

    var body: some View {
        let plan = store.today
        let text = plan.message(options)
        let hasDoneStops = plan.stops.contains { $0.status == .done } && !plan.isComplete
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    TextField("Add a note, like \u{201C}Who\u{2019}s in?\u{201D}", text: $options.note, axis: .vertical)
                        .font(.bodyText)
                        .lineLimit(1...3)
                        .padding(Space.sm)
                        .background(Color.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Color.border))
                        .accessibilityIdentifier("send-note")

                    VStack(spacing: 0) {
                        toggle("Prices", "Each stop and the total per person", $options.showPrices, id: "send-prices")
                        Hairline()
                        toggle("Getting there", "Walk, subway or drive between stops", $options.showTravel, id: "send-travel")
                        if hasDoneStops {
                            Hairline()
                            toggle("Only what's left", "Leave out stops you've done", $options.onlyWhatsLeft, id: "send-only-left")
                        }
                    }
                    .planditCard(padding: Space.sm)

                    VStack(alignment: .leading, spacing: Space.xs) {
                        SectionTitle("Message")
                        Text(text)
                            .font(.bodyText)
                            .foregroundStyle(.ink)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .planditCard()
                            .accessibilityIdentifier("send-preview")
                    }
                }
                .padding(Space.lg)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: Space.sm) {
                    Button {
                        UIPasteboard.general.string = text
                        didCopy = true
                    } label: {
                        Text(didCopy ? "Copied" : "Copy")
                    }
                    .buttonStyle(.secondary)
                    .accessibilityIdentifier("send-copy")
                    ShareLink(item: text) {
                        HStack(spacing: Space.xs) {
                            Icon(.share, size: 18)
                            Text("Send")
                        }
                    }
                    .buttonStyle(.primary)
                    .accessibilityIdentifier("send-share")
                }
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.sm)
                .background(Color.surface)
            }
            .background(Color.surface)
            .navigationTitle("Send plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .presentationBackground(Color.surface)
        .onChange(of: options) { didCopy = false }
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            // Halfway through the day, friends joining later only need what's left.
            options.onlyWhatsLeft = store.today.stops.contains { $0.status == .done } && !store.today.isComplete
        }
    }

    private func toggle(_ title: String, _ detail: String, _ isOn: Binding<Bool>, id: String) -> some View {
        Toggle(isOn: isOn.animation(.snappy)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.bodyText).foregroundStyle(.ink)
                Text(detail).font(.metadata).foregroundStyle(.inkMuted)
            }
        }
        .tint(.emerald)
        .frame(minHeight: 48)
        .accessibilityIdentifier(id)
    }
}
