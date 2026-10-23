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
            let mediaStore = TemporaryMediaStore()
            try mediaStore.validate(received.file)
            try FileManager.default.createDirectory(
                at: mediaStore.root,
                withIntermediateDirectories: true
            )
            let fileExtension = received.file.pathExtension.isEmpty
                ? "mov"
                : received.file.pathExtension
            let destination = mediaStore.root
                .appending(path: "Picker-\(UUID().uuidString).\(fileExtension)")
            try FileManager.default.copyItem(at: received.file, to: destination)
            return PickedVideo(url: destination)
        }
    }
}

/// Manual fallback for the share extension: paste a TikTok or Reel link.
struct AddLinkSheet: View {
    /// Called with the saved post's id after the sheet closes.
    var onSaved: (UUID) -> Void = { _ in }
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
                        PhotosPicker(
                            selection: $selectedVideo,
                            matching: .videos,
                            photoLibrary: .shared()
                        ) {
                            Label("Choose from Photos", systemImage: "video")
                        }
                        .buttonStyle(.secondary)
                        .disabled(isProcessingVideo)
                        .accessibilityIdentifier("choose-video-photos")

                        if isProcessingVideo {
                            HStack(spacing: Space.xs) {
                                ProgressView().controlSize(.small)
                                Text("Reading video…")
                            }
                            .font(.metadata)
                            .foregroundStyle(.inkMuted)
                        }

                        Button {
                            isChoosingVideo = true
                        } label: {
                            Text("Choose from Files")
                        }
                        .buttonStyle(.plain)
                        .disabled(isProcessingVideo)
                    }
                }
                .padding(Space.lg)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.surface)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: Space.sm) {
                    Button("Save to Plandit", action: save)
                        .buttonStyle(.primary)
                        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("save-social-link")

                    Button("Cancel") { dismiss() }
                        .buttonStyle(.secondary)
                        .accessibilityIdentifier("cancel-add-link")
                }
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.sm)
                .background(Color.surface)
                .overlay(alignment: .top) { Hairline() }
            }
        }
        .presentationDetents([.medium, .large])
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
        guard let url = LinkParser.firstWebURL(in: text) else {
            errorMessage = "Paste a TikTok video or Instagram Reel link."
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
