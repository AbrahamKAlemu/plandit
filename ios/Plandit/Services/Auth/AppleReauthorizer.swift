import AuthenticationServices
import UIKit

/// A fresh Sign in with Apple authorization, so the server can revoke the person's Apple tokens
/// when they delete their account (App Store guideline 5.1.1(v)). Main-actor bound: the live one
/// presents the system sheet; tests use a fake.
protocol AppleReauthorizing {
    /// The authorization code from the system sheet (Face ID or passcode; no name or email).
    /// Throws `AppleReauthorizationError.canceled` when the person dismisses it.
    func authorizationCode() async throws -> String
}

nonisolated enum AppleReauthorizationError: Error, Equatable, Sendable {
    /// The person changed their mind: not an error to show.
    case canceled
    /// The sheet failed, or Apple answered without a code.
    case failed
}

/// `ASAuthorizationController` with a scope-less Apple ID request, presented in the active window.
final class AppleReauthorizer: NSObject, AppleReauthorizing {
    private var continuation: CheckedContinuation<String, any Error>?
    private var controller: ASAuthorizationController?

    func authorizationCode() async throws -> String {
        if continuation != nil { throw AppleReauthorizationError.failed } // one sheet at a time
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = []
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        self.controller = controller
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            controller.performRequests()
        }
    }

    private func finish(_ result: Result<String, any Error>) {
        controller = nil
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}

extension AppleReauthorizer: ASAuthorizationControllerDelegate {
    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        guard
            let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
            let data = credential.authorizationCode,
            let code = String(data: data, encoding: .utf8),
            !code.isEmpty
        else {
            finish(.failure(AppleReauthorizationError.failed))
            return
        }
        finish(.success(code))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: any Error) {
        if let authError = error as? ASAuthorizationError, authError.code == .canceled {
            finish(.failure(AppleReauthorizationError.canceled))
        } else {
            finish(.failure(AppleReauthorizationError.failed))
        }
    }
}

extension AppleReauthorizer: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first ?? ASPresentationAnchor()
    }
}
