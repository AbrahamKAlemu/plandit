import SwiftUI

/// Share → Plandit. It saves without a tap: "Saved to Plandit" with Done and Undo, or a plain
/// problem with Close. In `Shared/` so the app's tests can render it too.
struct ShareSheetView: View {
    let state: ShareFlow.State
    let onDone: () -> Void
    let onUndo: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            BrandArt.markSquare.image
                .resizable()
                .frame(width: 48, height: 48)
                .accessibilityLabel("Plandit")

            switch state {
            case .saving:
                HStack(spacing: Space.sm) {
                    ProgressView()
                    Text("Saving…").font(.bodyText).foregroundStyle(.inkMuted)
                }
                Spacer(minLength: 0)
            case .saved(let summary):
                saved(summary)
            case .problem(let problem):
                Text(problem.title)
                    .font(.sectionHeading)
                    .foregroundStyle(.ink)
                    .accessibilityAddTraits(.isHeader)
                    .fixedSize(horizontal: false, vertical: true)
                Text(problem.message)
                    .font(.bodyText)
                    .foregroundStyle(.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Close", action: onClose)
                    .buttonStyle(.secondary)
                    .accessibilityIdentifier("share-close")
            }
        }
        .padding(Space.lg)
        .frame(maxWidth: ContentWidth.column, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity)
        .background(Color.surface)
        .tint(Color.emeraldDeep)
    }

    @ViewBuilder
    private func saved(_ summary: ShareSummary) -> some View {
        HStack(spacing: Space.xs) {
            Icon(.circleCheck, size: 22)
                .foregroundStyle(.emeraldDeep)
                .accessibilityHidden(true)
            Text("Saved to Plandit")
                .font(.sectionHeading)
                .foregroundStyle(.ink)
                .accessibilityAddTraits(.isHeader)
        }

        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.xs) {
                Icon(summary.platform == .video ? .video : .link, size: 16)
                    .accessibilityHidden(true)
                Text(summary.sourceLine)
                    .font(.label)
                    .lineLimit(1)
            }
            .foregroundStyle(.ink)
            if let caption = summary.caption {
                Text(caption)
                    .font(.bodyText)
                    .foregroundStyle(.ink)
                    .lineLimit(3)
            }
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.canvas, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Color.border))
        .accessibilityElement(children: .combine)

        Text("Plandit finds the place next time you open it.")
            .font(.bodyText)
            .foregroundStyle(.inkMuted)
            .fixedSize(horizontal: false, vertical: true)

        Spacer(minLength: 0)

        VStack(spacing: Space.sm) {
            Button("Done", action: onDone)
                .buttonStyle(.primary)
                .accessibilityIdentifier("share-done")
            Button(action: onUndo) {
                HStack(spacing: Space.xs) {
                    Icon(.undo, size: 18)
                    Text("Undo")
                }
            }
            .buttonStyle(.secondary)
            .accessibilityLabel("Undo")
            .accessibilityHint("Takes this share back")
            .accessibilityIdentifier("share-undo")
        }
    }
}
