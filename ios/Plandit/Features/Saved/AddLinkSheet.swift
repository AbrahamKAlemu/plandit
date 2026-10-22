import SwiftUI

/// Manual fallback for the share extension: paste a TikTok or Reel link.
struct AddLinkSheet: View {
    /// Called with the saved post's id after the sheet closes.
    var onSaved: (UUID) -> Void = { _ in }
    @Environment(PlanditStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var showError = false
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
                    if showError {
                        Text("Enter a valid link. In TikTok or Instagram, tap Share, then Copy link.")
                            .font(.metadata)
                            .foregroundStyle(.error)
                    }
                    PasteButton(payloadType: String.self) { strings in
                        text = strings.first ?? ""
                        showError = false
                    }
                    .labelStyle(.titleOnly)
                    .tint(Color.ink)
                }

                Spacer(minLength: 0)

                Button("Save to Plandit", action: save)
                    .buttonStyle(.primary)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
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
        .onAppear { isFocused = true }
    }

    private func save() {
        guard let url = LinkParser.firstWebURL(in: text) else {
            showError = true
            return
        }
        let id = withAnimation(.snappy) { store.save(url: url) }
        dismiss()
        onSaved(id)
    }
}
