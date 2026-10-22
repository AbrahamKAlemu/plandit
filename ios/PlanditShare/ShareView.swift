import SwiftUI

struct ShareView: View {
    let model: ShareModel
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Space.md) {
                BrandArt.markSquare.image
                    .resizable()
                    .frame(width: 48, height: 48)
                    .accessibilityLabel("Plandit")

                switch model.state {
                case .loading:
                    HStack(spacing: Space.sm) {
                        ProgressView()
                        Text("Reading the link…").font(.bodyText).foregroundStyle(.inkMuted)
                    }
                case .ready(let url):
                    let platform = SourcePlatform(url: url)
                    Text("Save to Plandit").font(.sectionHeading).foregroundStyle(.ink)
                    Text("We'll find the place, price, and hours in \(platform.postPhrase) and pin it on your map.")
                        .font(.bodyText)
                        .foregroundStyle(.inkMuted)
                    HStack(spacing: Space.xs) {
                        Icon(.link, size: 16)
                        Text(url.host() ?? url.absoluteString).lineLimit(1)
                    }
                    .font(.label)
                    .foregroundStyle(.ink)
                    .padding(Space.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Color.border))
                    Spacer(minLength: 0)
                    Button("Save to Plandit", action: onSave)
                        .buttonStyle(.primary)
                case .noLink:
                    Text("No link found").font(.sectionHeading).foregroundStyle(.ink)
                    Text("Plandit saves links from TikTok, Instagram Reels, and the web. Copy the link and paste it in Plandit instead.")
                        .font(.bodyText)
                        .foregroundStyle(.inkMuted)
                    Spacer(minLength: 0)
                    Button("Close", action: onCancel)
                        .buttonStyle(.secondary)
                }
            }
            .padding(Space.lg)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.surface)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
        .tint(Color.emeraldDeep)
    }
}
