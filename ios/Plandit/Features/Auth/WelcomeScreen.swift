import AuthenticationServices
import SwiftUI

/// First screen of a signed-out app.
struct WelcomeScreen: View {
    let onEmail: () -> Void
    @Environment(AccountModel.self) private var account
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                (colorScheme == .dark ? BrandArt.lockupDark : BrandArt.lockupLight).image
                    .resizable()
                    .scaledToFit()
                    .frame(width: 132)
                    .accessibilityLabel("Plandit")
                    .padding(.top, Space.xl)

                VStack(alignment: .leading, spacing: Space.sm) {
                    Text(AuthCopy.welcomeHeadline)
                        .font(.sectionHeading)
                        .foregroundStyle(.ink)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("welcome-headline")
                    Text(AuthCopy.welcomeSubhead)
                        .font(.bodyLarge)
                        .foregroundStyle(.inkMuted)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.lg)
        }
        .scrollIndicators(.hidden)
        .background(Color.canvas)
        // Before the inset: an identifier placed after it would override the buttons' own.
        .accessibilityIdentifier("welcome-screen")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: Space.sm) {
                if let message = account.errorMessage {
                    InlineErrorText(message: message)
                }
                AppleSignInButton()
                Button(AuthCopy.continueWithEmail, action: onEmail)
                    .buttonStyle(.secondary)
                    .disabled(account.isBusy)
                    .accessibilityIdentifier("continue-with-email")
                Text(AuthCopy.welcomeFootnote)
                    .font(.metadata)
                    .foregroundStyle(.inkMuted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, Space.xxs)
            }
            .padding(.horizontal, Space.lg)
            .padding(.top, Space.sm)
            .padding(.bottom, Space.md)
            .background(Color.canvas)
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}

/// Apple's system button; the raw nonce stays here, its hash goes to Apple.
struct AppleSignInButton: View {
    @Environment(AccountModel.self) private var account
    @Environment(\.colorScheme) private var colorScheme
    @State private var rawNonce = AppleNonce.random()

    var body: some View {
        SignInWithAppleButton(.signIn) { request in
            rawNonce = AppleNonce.random()
            request.requestedScopes = [.fullName, .email]
            request.nonce = AppleNonce.sha256Hex(rawNonce)
        } onCompletion: { result in
            handle(result)
        }
        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
        .frame(height: 56)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .disabled(account.isBusy)
        .accessibilityIdentifier("sign-in-with-apple")
    }

    private func handle(_ result: Result<ASAuthorization, any Error>) {
        switch result {
        case .success(let authorization):
            guard
                let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let tokenData = credential.identityToken,
                let idToken = String(data: tokenData, encoding: .utf8)
            else {
                account.errorMessage = AuthCopy.generic
                return
            }
            let fullName = credential.fullName
                .map { PersonNameComponentsFormatter.localizedString(from: $0, style: .default) }?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let nonce = rawNonce
            Task {
                await account.signInWithApple(
                    idToken: idToken,
                    rawNonce: nonce,
                    fullName: fullName.flatMap { $0.isEmpty ? nil : $0 }
                )
            }
        case .failure(let error):
            // Cancel is the person changing their mind, not an error.
            if let authError = error as? ASAuthorizationError, authError.code == .canceled { return }
            account.errorMessage = AuthCopy.generic
        }
    }
}
