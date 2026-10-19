import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Entry point for "Share → Plandit" from TikTok, Instagram, Safari, etc.
/// Saves the link to the App Group inbox; the app picks it up and maps it next time it's active.
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        let root = ShareView(
                model: model,
                onSave: { [weak self] in self?.save() },
                onCancel: { [weak self] in self?.cancel() }
            )
            .preferredColorScheme(AppearanceMode.saved.colorScheme)
        let host = UIHostingController(rootView: root)
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)

        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        Task { await model.load(from: items) }
    }

    private func save() {
        if let url = model.url {
            ShareInbox.enqueue(IncomingShare(url: url, sharedText: model.sharedText))
        }
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func cancel() {
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }
}

@Observable
@MainActor
final class ShareModel {
    enum State {
        case loading
        case ready(URL)
        case unsupported
        case noLink
    }

    var state: State = .loading
    var sharedText: String?

    var url: URL? {
        if case .ready(let url) = state { return url }
        return nil
    }

    /// Prefers a real URL attachment; falls back to the first link inside shared text (TikTok often sends text).
    func load(from items: [NSExtensionItem]) async {
        let providers = items.flatMap { $0.attachments ?? [] }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url = await provider.loadURL() {
                do {
                    state = .ready(try SupportedSocialURL(url).canonicalURL)
                    return
                } catch {
                    state = .unsupported
                }
            }
        }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let text = await provider.loadText(), let url = LinkParser.firstWebURL(in: text) {
                do {
                    sharedText = text
                    state = .ready(try SupportedSocialURL(url).canonicalURL)
                    return
                } catch {
                    state = .unsupported
                }
            }
        }
        if case .unsupported = state {
            return
        }
        state = .noLink
    }
}

@MainActor
private extension NSItemProvider {
    func loadURL() async -> URL? {
        await withCheckedContinuation { continuation in
            loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                continuation.resume(returning: item as? URL)
            }
        }
    }

    func loadText() async -> String? {
        await withCheckedContinuation { continuation in
            loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                continuation.resume(returning: item as? String)
            }
        }
    }
}
