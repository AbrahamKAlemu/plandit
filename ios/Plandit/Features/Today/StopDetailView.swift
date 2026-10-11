import SwiftUI

struct StopDetailView: View {
    let stopID: UUID
    @Environment(PlanditStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let stop = store.stop(id: stopID), let number = store.stopNumber(id: stopID) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        HStack(spacing: Space.xs) {
                            StopBadge(number: number, status: stop.status, size: 32)
                            StopStatusTag(status: stop.status)
                        }
                        Text(stop.place.name).font(.pageHeading).foregroundStyle(.ink)
                        Text("\(stop.place.category.label) · \(stop.place.neighborhood)")
                            .font(.bodyText)
                            .foregroundStyle(.inkMuted)
                    }

                    VStack(alignment: .leading, spacing: Space.md) {
                        FactRow(icon: .clock, title: "When", value: "\(stop.start.shortTime)–\(stop.end.shortTime) · \(stop.durationMinutes.durationText)")
                        FactRow(icon: .wallet, title: "Estimated cost", value: stop.estimatedCost.dollarsText)
                        FactRow(icon: .mapPin, title: "Address", value: stop.place.address)
                        if let hours = stop.place.hours {
                            FactRow(icon: .info, title: "Hours", value: hours)
                        }
                        if let leg = store.today.leg(after: stop) {
                            FactRow(icon: leg.mode.icon, title: "Next", value: leg.summary)
                        }
                    }
                    .planditCard()

                    if let note = stop.note {
                        VStack(alignment: .leading, spacing: Space.xxs) {
                            SectionTitle("Why it's in your plan")
                            Text(note).font(.bodyText).foregroundStyle(.ink)
                        }
                    }

                    if let post = store.post(id: stop.sourcePostID) {
                        SourceCard(post: post)
                    }

                    VStack(spacing: Space.sm) {
                        Button {
                            stop.place.openDirections()
                        } label: {
                            HStack(spacing: Space.xs) {
                                Icon(.navigation, size: 18)
                                Text("Get directions")
                            }
                        }
                        .buttonStyle(.primary)

                        Button(role: .destructive) {
                            store.removeStop(stop.id)
                            dismiss()
                        } label: {
                            Text("Remove from plan")
                                .font(.label)
                                .foregroundStyle(.error)
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                    }
                }
                .padding(Space.lg)
            }
            .background(Color.surface)
            .navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView("Stop removed", image: "Icons/route", description: Text("This stop is no longer in today's plan."))
        }
    }
}
