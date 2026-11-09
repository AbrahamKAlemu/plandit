import SwiftUI

/// One stop's cost: what this place usually costs, the number the plan uses, and the user's own
/// list of what they'll pay for. Nothing here is fixed; every number can be changed.
struct StopCostSheet: View {
    let stopID: UUID
    @Environment(PlanditStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var items: [CostItem] = []
    @State private var didLoad = false

    var body: some View {
        NavigationStack {
            Group {
                if let stop = store.stop(id: stopID) {
                    content(stop)
                } else {
                    ContentUnavailableView("Stop removed", image: "Icons/route", description: Text("This stop is no longer in today's plan."))
                }
            }
            .background(Color.surface)
            .navigationTitle("Cost")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .keyboardDoneButton()
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Color.surface)
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            items = store.stop(id: stopID)?.costItems ?? []
        }
        .onChange(of: items) { _, new in commit(new) }
    }

    private func content(_ stop: PlanStop) -> some View {
        let guide = store.priceGuide(for: stop)
        return ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                PriceGuideCard(name: stop.place.name, guide: guide)

                VStack(alignment: .leading, spacing: Space.xs) {
                    SectionTitle("Your estimate")
                    if stop.costItems.isEmpty {
                        AmountRow(
                            label: "Per person",
                            amount: Binding(get: { stop.estimatedCost }, set: { store.setCost($0, forStop: stopID) })
                        )
                        .planditCard(padding: Space.sm)
                    } else {
                        HStack {
                            Text("Adds up your items").font(.bodyText).foregroundStyle(.inkMuted)
                            Spacer()
                            Text(stop.estimatedCost.dollarsText)
                                .font(.manrope(.bold, size: 17))
                                .foregroundStyle(.ink)
                                .accessibilityIdentifier("stop-cost-total")
                        }
                        .frame(minHeight: 44)
                        .planditCard(padding: Space.sm)
                    }
                }

                VStack(alignment: .leading, spacing: Space.xs) {
                    SectionTitle("What you'll pay for")
                    Text("List what you'll buy here, like a ticket or drinks. Your total replaces the estimate.")
                        .font(.metadata)
                        .foregroundStyle(.inkMuted)
                    CostItemsEditor(items: $items, addTitle: "Add an item", placeholder: "Ticket, drinks…", addID: "add-stop-item")
                }

                if stop.costIsCustom {
                    Button {
                        store.resetCost(forStop: stopID)
                        items = []
                    } label: {
                        Text("Use \(guide.source == .post ? "the post's price" : "the usual price") (\(guide.rangeText))")
                            .font(.label)
                            .foregroundStyle(.ink)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .accessibilityIdentifier("reset-cost")
                }

                BudgetLine(plan: store.today)
            }
            .padding(Space.lg)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }

    /// Only items with an amount count. Empty rows the user just added don't change the cost yet.
    private func commit(_ items: [CostItem]) {
        guard let stop = store.stop(id: stopID) else { return }
        let counted = items.filter { $0.amount > 0 }
        guard counted != stop.costItems else { return }
        store.setCostItems(counted, forStop: stopID)
    }
}

/// A saved place's price before it's in a plan: the user's number is used every time it's planned.
struct PostCostSheet: View {
    let postID: UUID
    @Environment(PlanditStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let post = store.post(id: postID), let guide = post.postedPrice, let place = post.place {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Space.lg) {
                            PriceGuideCard(name: place.name, guide: guide)
                            VStack(alignment: .leading, spacing: Space.xs) {
                                SectionTitle("Your estimate")
                                AmountRow(
                                    label: "Per person",
                                    amount: Binding(get: { post.plannedCost ?? 0 }, set: { store.setUserCost($0, forPost: postID) })
                                )
                                .planditCard(padding: Space.sm)
                                Text("Plandit uses this whenever you plan \(place.name).")
                                    .font(.metadata)
                                    .foregroundStyle(.inkMuted)
                            }
                            if post.userCost != nil {
                                Button {
                                    store.setUserCost(nil, forPost: postID)
                                } label: {
                                    Text("Use \(guide.source == .post ? "the post's price" : "the usual price") (\(guide.rangeText))")
                                        .font(.label)
                                        .foregroundStyle(.ink)
                                        .frame(maxWidth: .infinity, minHeight: 44)
                                }
                            }
                        }
                        .padding(Space.lg)
                    }
                } else {
                    ContentUnavailableView("No place yet", image: "Icons/map-pin", description: Text("Confirm the place first, then set its price."))
                }
            }
            .background(Color.surface)
            .navigationTitle("Cost")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .keyboardDoneButton()
        }
        .presentationDetents([.medium])
        .presentationBackground(Color.surface)
    }
}

/// "Usually $15–30 per person · Typical for food in NYC", like the price line on a maps listing.
struct PriceGuideCard: View {
    let name: String
    let guide: PriceGuide

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(name).font(.cardHeading).foregroundStyle(.ink)
            HStack(spacing: Space.xs) {
                Icon(.wallet, size: 18).foregroundStyle(.ink)
                Text(guide.perPersonText).font(.bodyText).foregroundStyle(.ink)
            }
            .accessibilityIdentifier("price-guide")
            Text(guide.sourceText).font(.metadata).foregroundStyle(.inkMuted)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A dollar amount you can type or nudge by $1.
struct AmountRow: View {
    let label: String
    @Binding var amount: Double

    var body: some View {
        HStack(spacing: Space.sm) {
            Text(label).font(.bodyText).foregroundStyle(.ink)
            Spacer(minLength: Space.xs)
            DollarField(amount: $amount, placeholder: "$0")
                .font(.manrope(.bold, size: 17))
                .frame(maxWidth: 110)
                .accessibilityIdentifier("amount-field")
            Stepper(label, value: $amount, in: 0...1000, step: 1)
                .labelsHidden()
        }
        .frame(minHeight: 44)
    }
}

extension View {
    /// The number pad has no return key, so give it a Done button.
    func keyboardDoneButton() -> some View {
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
                .accessibilityIdentifier("keyboard-done")
            }
        }
    }
}

/// A dollar amount that updates as you type ("12", "$4.50"), so totals change right away.
/// Changes from outside (the stepper) show up in the field when it isn't being edited.
struct DollarField: View {
    @Binding var amount: Double
    let placeholder: String
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.trailing)
            .foregroundStyle(.ink)
            .focused($isFocused)
            .onAppear { text = Self.format(amount) }
            .onChange(of: text) { _, new in
                guard isFocused else { return }
                let value = Self.parse(new)
                if value != amount { amount = value }
            }
            .onChange(of: amount) { _, new in
                if !isFocused { text = Self.format(new) }
            }
            .onChange(of: isFocused) { _, focused in
                if !focused { text = Self.format(amount) }
            }
    }

    static func parse(_ text: String) -> Double {
        let digits = text.filter { $0.isNumber || $0 == "." }
        return max(0, Double(digits) ?? 0)
    }

    static func format(_ amount: Double) -> String {
        amount == 0 ? "" : amount.formatted(.currency(code: "USD").precision(.fractionLength(amount.rounded() == amount ? 0 : 2)))
    }
}

/// The user's own costs, one per row: name, amount, remove.
struct CostItemsEditor: View {
    @Binding var items: [CostItem]
    let addTitle: String
    let placeholder: String
    var addID = "add-cost-item"

    var body: some View {
        VStack(spacing: 0) {
            ForEach($items) { $item in
                HStack(spacing: Space.sm) {
                    TextField(placeholder, text: $item.name)
                        .font(.bodyText)
                        .foregroundStyle(.ink)
                        .accessibilityIdentifier("item-name")
                    DollarField(amount: $item.amount, placeholder: "$0")
                        .font(.manrope(.bold, size: 16))
                        .frame(maxWidth: 90)
                        .accessibilityIdentifier("item-amount")
                    Button {
                        withAnimation(.snappy) { items.removeAll { $0.id == item.id } }
                    } label: {
                        Icon(.trash, size: 18)
                            .foregroundStyle(.inkMuted)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(item.name.isEmpty ? "item" : item.name)")
                }
                .frame(minHeight: 48)
                Hairline()
            }
            Button {
                withAnimation(.snappy) { items.append(CostItem(name: "", amount: 0)) }
            } label: {
                HStack(spacing: Space.xs) {
                    Icon(.plus, size: 18)
                    Text(addTitle).font(.label)
                    Spacer()
                }
                .foregroundStyle(.ink)
                .frame(minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(addID)
        }
        .planditCard(padding: Space.sm)
    }
}

/// "Today: $57 of $60 · $3 left".
struct BudgetLine: View {
    let plan: DayPlan

    var body: some View {
        HStack(spacing: Space.xs) {
            Icon(.wallet, size: 16)
            Text("Today: \(plan.totalCost.wholeDollarsText) of \(plan.budget.wholeDollarsText) · \(plan.remainingText)")
        }
        .font(.metadata)
        .foregroundStyle(plan.remaining < 0 ? Color.error : Color.inkMuted)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("budget-line")
    }
}

extension DayPlan {
    /// "$3 left", "Right on budget" or "$12 over".
    var remainingText: String {
        let left = remaining.rounded()
        if left == 0 { return "Right on budget" }
        return left > 0 ? "\(left.wholeDollarsText) left" : "\((-left).wholeDollarsText) over"
    }
}
