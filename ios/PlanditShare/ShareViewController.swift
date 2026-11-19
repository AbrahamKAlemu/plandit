import SwiftUI
import UIKit

/// Entry point for "Share → Plandit" from TikTok, Instagram, Photos, Files, Safari, etc.
/// Saves straight away to the App Group inbox (`ShareFlow`); the app finds the place next time it opens.
final class ShareViewController: UIViewController {
    private let flow = ShareFlow()
    private var autoClose: Task<Void, Never>?
    private var isFinished = false

    override func viewDidLoad() {
        super.viewDidLoad()
        let root = ShareFlowView(
            flow: flow,
            onDone: { [weak self] in self?.complete() },
            onUndo: { [weak self] in self?.undo() },
            onClose: { [weak self] in self?.cancel() }
        )
        .preferredColorScheme(AppearanceMode.saved.colorScheme)
        let host = UIHostingController(rootView: root)
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)

        // Unread videos older than a day go, even if Plandit itself hasn't opened since.
        try? TemporaryMediaStore.shared?.removeExpiredFiles()

        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        Task {
            await flow.start(items: items)
            if case .saved = flow.state {
                UIAccessibility.post(notification: .announcement, argument: "Saved to Plandit")
                scheduleAutoClose()
            }
        }
    }

    /// About 2 s, unless VoiceOver is on: then it stays until Done or Undo (SHR-5).
    private func scheduleAutoClose() {
        guard let delay = ShareClosePolicy.autoCloseDelay(isVoiceOverRunning: UIAccessibility.isVoiceOverRunning) else { return }
        autoClose = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, !UIAccessibility.isVoiceOverRunning else { return }
            self?.complete()
        }
    }

    private func complete() {
        guard finish() else { return }
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func undo() {
        guard finish() else { return }
        flow.undo()
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }

    private func cancel() {
        guard finish() else { return }
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }

    /// The first of Done, Undo, Close or the timer wins; the rest do nothing.
    private func finish() -> Bool {
        guard !isFinished else { return false }
        isFinished = true
        autoClose?.cancel()
        return true
    }
}

private struct ShareFlowView: View {
    let flow: ShareFlow
    let onDone: () -> Void
    let onUndo: () -> Void
    let onClose: () -> Void

    var body: some View {
        ShareSheetView(state: flow.state, onDone: onDone, onUndo: onUndo, onClose: onClose)
            .animation(.snappy(duration: 0.25), value: flow.state)
    }
}
