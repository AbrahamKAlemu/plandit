import SwiftUI
import UIKit

/// Share today's plan. First choice: a link to a page friends open in their browser, no app
/// needed, that updates when the plan changes. Second: the plan as a text message.
struct SendPlanSheet: View {
    @Environment(PlanditStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var options = PlanMessageOptions()
    @State private var didLoad = false
    @State private var isWorking = false
    @State private var errorText: String?
    @State private var didCopyLink = false
    @State private var didCopyText = false
    @State private var showsText = false

    var body: some View {
        let plan = store.today
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
                    }
                    .planditCard(padding: Space.sm)

                    linkSection
                    textSection(plan)
                }
                .padding(Space.lg)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .background(Color.surface)
            .navigationTitle("Share plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .presentationBackground(Color.surface)
        .onChange(of: options) {
            didCopyText = false
            errorText = nil
        }
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            if let link = store.todayLink {
                options.showPrices = link.showPrices
                options.note = link.note
            }
            // Halfway through the day, a text only needs what's left.
            options.onlyWhatsLeft = store.today.stops.contains { $0.status == .done } && !store.today.isComplete
        }
    }

    // MARK: - Link

    @ViewBuilder private var linkSection: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            SectionTitle("Link")
            if let link = store.todayLink {
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
                    .accessibilityIdentifier("share-link-url")
                Text("Anyone with the link can see this plan, no app needed. It updates when you change the plan.")
                    .font(.metadata)
                    .foregroundStyle(.inkMuted)

                if link.showPrices != options.showPrices || link.note != options.note {
                    Button {
                        Task { await createOrUpdate() }
                    } label: {
                        workingLabel("Update the page")
                    }
                    .buttonStyle(.secondary)
                    .disabled(isWorking)
                    .accessibilityIdentifier("share-update-link")
                }

                HStack(spacing: Space.sm) {
                    Button {
                        UIPasteboard.general.url = link.url
                        didCopyLink = true
                    } label: {
                        Text(didCopyLink ? "Copied" : "Copy link")
                    }
                    .buttonStyle(.secondary)
                    .accessibilityIdentifier("share-copy-link")
                    ShareLink(item: link.url, message: Text(options.note)) {
                        HStack(spacing: Space.xs) {
                            Icon(.share, size: 18)
                            Text("Send link")
                        }
                    }
                    .buttonStyle(.primary)
                    .accessibilityIdentifier("share-send-link")
                }

                Button(role: .destructive) {
                    Task { await stop() }
                } label: {
                    Text("Stop sharing")
                        .font(.label)
                        .foregroundStyle(.error)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .disabled(isWorking)
                .accessibilityHint("The link stops working")
                .accessibilityIdentifier("share-stop")
            } else if store.canShareLinks {
                Text("Friends open it in their browser, no app needed. It updates when you change the plan.")
                    .font(.metadata)
                    .foregroundStyle(.inkMuted)
                Button {
                    Task { await createOrUpdate() }
                } label: {
                    HStack(spacing: Space.xs) {
                        Icon(.link, size: 18)
                        workingLabel("Create link")
                    }
                }
                .buttonStyle(.primary)
                .disabled(isWorking || store.today.stops.isEmpty)
                .accessibilityIdentifier("share-create-link")
            } else {
                Text("Sign in to share your plan as a link.")
                    .font(.metadata)
                    .foregroundStyle(.inkMuted)
            }

            if let errorText {
                Text(errorText)
                    .font(.metadata)
                    .foregroundStyle(Color.error)
                    .accessibilityIdentifier("share-error")
            }
        }
        .planditCard()
    }

    private func workingLabel(_ title: String) -> some View {
        HStack(spacing: Space.xs) {
            if isWorking { ProgressView().controlSize(.small) }
            Text(isWorking ? "One moment…" : title)
        }
    }

    private func createOrUpdate() async {
        isWorking = true
        errorText = nil
        defer { isWorking = false }
        do {
            try await store.shareToday(showPrices: options.showPrices, note: options.note)
        } catch {
            errorText = "Couldn't make the link. Check your connection and try again."
        }
    }

    private func stop() async {
        isWorking = true
        errorText = nil
        defer { isWorking = false }
        do {
            try await store.stopSharing()
            didCopyLink = false
        } catch {
            errorText = "Couldn't stop sharing. Check your connection and try again."
        }
    }

    // MARK: - Text message

    private func textSection(_ plan: DayPlan) -> some View {
        let text = plan.message(options)
        let hasDoneStops = plan.stops.contains { $0.status == .done } && !plan.isComplete
        return DisclosureGroup(isExpanded: $showsText.animation(.snappy)) {
            VStack(alignment: .leading, spacing: Space.md) {
                VStack(spacing: 0) {
                    toggle("Getting there", "Walk, subway or drive between stops", $options.showTravel, id: "send-travel")
                    if hasDoneStops {
                        Hairline()
                        toggle("Only what's left", "Leave out stops you've done", $options.onlyWhatsLeft, id: "send-only-left")
                    }
                }
                Text(text)
                    .font(.bodyText)
                    .foregroundStyle(.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .planditCard()
                    .accessibilityIdentifier("send-preview")
                HStack(spacing: Space.sm) {
                    Button {
                        UIPasteboard.general.string = text
                        didCopyText = true
                    } label: {
                        Text(didCopyText ? "Copied" : "Copy")
                    }
                    .buttonStyle(.secondary)
                    .accessibilityIdentifier("send-copy")
                    ShareLink(item: text) {
                        HStack(spacing: Space.xs) {
                            Icon(.share, size: 18)
                            Text("Send text")
                        }
                    }
                    .buttonStyle(.secondary)
                    .accessibilityIdentifier("send-share")
                }
            }
            .padding(.top, Space.sm)
        } label: {
            Text("Send as a text instead")
                .font(.label)
                .foregroundStyle(.ink)
        }
        .tint(.ink)
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
