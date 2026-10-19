import SwiftUI
import UniformTypeIdentifiers

/// Manual fallback for the share extension: paste a TikTok or Reel link.
struct AddLinkSheet: View {
    @Environment(PlanditStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var errorMessage: String?
    @State private var isChoosingVideo = false
    @State private var isProcessingVideo = false
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Space.md) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Add a link").font(.sectionHeading).foregroundStyle(.ink)
                    Text("Paste a TikTok or Instagram Reel link. We'll add the place to your map with its price and hours.")
                        .font(.bodyText)
                        .foregroundStyle(.inkMuted)
                }

                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Link").font(.label).foregroundStyle(.ink)
                    TextField("tiktok.com/@creator/video/…", text: $text)
                        .font(.bodyText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused($isFocused)
                        .onSubmit(save)
                        .padding(.horizontal, Space.sm)
                        .frame(minHeight: 48)
                        .background(Color.surface, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                                .strokeBorder(isFocused ? Color.ink : Color.border, lineWidth: isFocused ? 2 : 1)
                        )
                        .accessibilityIdentifier("social-link-field")
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.metadata)
                            .foregroundStyle(.error)
                    }
                    PasteButton(payloadType: String.self) { strings in
                        text = strings.first ?? ""
                        errorMessage = nil
                    }
                    .labelStyle(.titleOnly)
                    .tint(Color.ink)
                }

                HStack(spacing: Space.sm) {
                    Rectangle().fill(Color.border).frame(height: 1)
                    Text("or").font(.metadata).foregroundStyle(.inkMuted)
                    Rectangle().fill(Color.border).frame(height: 1)
                }

                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Use a video").font(.label).foregroundStyle(.ink)
                    Text("If the link does not include enough detail, choose a video you are allowed to share. Plandit reads it on this device and deletes the temporary copy.")
                        .font(.bodyText)
                        .foregroundStyle(.inkMuted)
                    Button {
                        isChoosingVideo = true
                    } label: {
                        HStack(spacing: Space.xs) {
                            if isProcessingVideo {
                                ProgressView().controlSize(.small)
                            } else {
                                Icon(.video, size: 18)
                            }
                            Text(isProcessingVideo ? "Reading video…" : "Choose a video")
                        }
                    }
                    .buttonStyle(.secondary)
                    .disabled(isProcessingVideo)
                }

                Spacer(minLength: 0)

                Button("Save to Plandit", action: save)
                    .buttonStyle(.primary)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("save-social-link")
            }
            .padding(Space.lg)
            .background(Color.surface)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Color.surface)
        .fileImporter(
            isPresented: $isChoosingVideo,
            allowedContentTypes: [.movie],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else {
                if case .failure(let error) = result {
                    errorMessage = error.localizedDescription
                }
                return
            }
            isProcessingVideo = true
            Task {
                do {
                    try await store.saveVideo(fileURL: url)
                    dismiss()
                } catch {
                    errorMessage = error.localizedDescription
                }
                isProcessingVideo = false
            }
        }
    }

    private func save() {
        guard let url = LinkParser.firstWebURL(in: text) else {
            errorMessage = "Paste a TikTok video or Instagram Reel link."
            return
        }
        do {
            try store.save(url: url, sharedText: text)
            dismiss()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "We couldn't save that link. Try again."
        }
    }
}
