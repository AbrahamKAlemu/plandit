import CoreTransferable
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct PickedVideo: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            // Staged like a shared video: checked, and its 24 hours count from now, not from filming.
            PickedVideo(url: try TemporaryMediaStore().stage(received.file))
        }
    }
}

/// Manual fallback for the share extension: paste a TikTok or Reel link. A group plan invite
/// link pasted here goes to the join sheet instead (JN-1).
struct AddLinkSheet: View {
    /// Called with the saved post's id after the sheet closes.
    var onSaved: (UUID) -> Void = { _ in }
    /// Called with an invite link's token, just before the sheet closes for the join sheet.
    var onInvite: (String) -> Void = { _ in }
    @Environment(PlanditStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var errorMessage: String?
    @State private var isChoosingVideo = false
    @State private var isProcessingVideo = false
    @State private var selectedVideo: PhotosPickerItem?
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.md) {
                    Text("Paste a TikTok or Instagram post or Reel link. We'll add the place to your map with its price and hours.")
                        .font(.bodyText)
                        .foregroundStyle(.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("Link").font(.label).foregroundStyle(.ink)
                        TextField("TikTok or Instagram link", text: $text)
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
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        PasteButton(payloadType: String.self) { strings in
                            text = strings.first ?? ""
                            errorMessage = nil
                            // An invite goes straight to its join sheet; a post waits for Save.
                            if InviteLink.token(in: text) != nil { save() }
                        }
                        .labelStyle(.titleOnly)
                        .tint(Color.ink)
                    }

                    // Right under the field, so the keyboard never covers it (W-11).
                    Button("Save to Plandit", action: save)
                        .buttonStyle(.primary)
                        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("save-social-link")

                    HStack(spacing: Space.sm) {
                        Rectangle().fill(Color.border).frame(height: 1)
                        Text("or").font(.metadata).foregroundStyle(.inkMuted)
                        Rectangle().fill(Color.border).frame(height: 1)
                    }

                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("Use a video").font(.label).foregroundStyle(.ink)
                        Text("If the link doesn't include enough detail, choose a video you are allowed to share. Plandit reads it on this device and deletes the temporary copy.")
                            .font(.bodyText)
                            .foregroundStyle(.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                        VideoSourceButtons(
                            selection: $selectedVideo,
                            isChoosingFile: $isChoosingVideo,
                            isDisabled: isProcessingVideo,
                            photosIdentifier: "choose-video-photos",
                            filesIdentifier: "choose-video-files"
                        )

                        if isProcessingVideo {
                            HStack(spacing: Space.xs) {
                                ProgressView().controlSize(.small)
                                Text("Reading video…")
                            }
                            .font(.metadata)
                            .foregroundStyle(.inkMuted)
                        }
                    }
                }
                .padding(Space.lg)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.surface)
            .navigationTitle("Add a link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("cancel-add-link")
                }
            }
        }
        // Full height, so nothing starts below the sheet's edge mid-sentence (W-11).
        .presentationDetents([.large])
        .presentationBackground(Color.surface)
        .onChange(of: selectedVideo) { _, item in
            guard let item else { return }
            isProcessingVideo = true
            errorMessage = nil
            Task {
                do {
                    guard let video = try await item.loadTransferable(type: PickedVideo.self) else {
                        throw VideoEvidenceError.unsupportedType
                    }
                    defer { try? FileManager.default.removeItem(at: video.url) }
                    let id = try await store.saveVideo(fileURL: video.url)
                    dismiss()
                    onSaved(id)
                } catch {
                    errorMessage = error.localizedDescription
                    selectedVideo = nil
                }
                isProcessingVideo = false
            }
        }
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
            processVideo(at: url)
        }
        .onAppear { isFocused = true }
    }

    private func save() {
        // A group plan invite opens the join sheet, not place finding (JN-1).
        if let token = InviteLink.token(in: text) {
            onInvite(token)
            dismiss()
            return
        }
        guard let url = LinkParser.firstWebURL(in: text) else {
            errorMessage = "Paste a link to a TikTok or an Instagram post or Reel."
            return
        }
        do {
            let id = try store.save(url: url, sharedText: text)
            dismiss()
            onSaved(id)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "We couldn't save that link. Try again."
        }
    }

    private func processVideo(at url: URL) {
        isProcessingVideo = true
        errorMessage = nil
        Task {
            do {
                let id = try await store.saveVideo(fileURL: url)
                dismiss()
                onSaved(id)
            } catch {
                errorMessage = error.localizedDescription
            }
            isProcessingVideo = false
        }
    }
}
