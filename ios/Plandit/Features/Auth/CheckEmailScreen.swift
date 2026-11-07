import SwiftUI

/// After an email sign-up: the account exists, the address still has to be confirmed.
struct CheckEmailScreen: View {
    let email: String
    let onSignIn: () -> Void
    @Environment(AccountModel.self) private var account

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.md) {
                Icon(.circleCheck, size: 26)
                    .foregroundStyle(.ink)
                    .frame(width: 56, height: 56)
                    .background(Color.canvas, in: Circle())
                    .overlay(Circle().strokeBorder(Color.border))

                Text(AuthCopy.checkYourEmail)
                    .font(.sectionHeading)
                    .foregroundStyle(.ink)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("check-email-title")
                Text(AuthCopy.checkEmailBody(email))
                    .font(.bodyText)
                    .foregroundStyle(.ink)
                Text(AuthCopy.checkEmailHint)
                    .font(.metadata)
                    .foregroundStyle(.inkMuted)

                if let message = account.errorMessage {
                    InlineErrorText(message: message)
                } else if account.didResendConfirmation {
                    Text(AuthCopy.resent(email))
                        .font(.label)
                        .foregroundStyle(.emeraldDeep)
                        .accessibilityIdentifier("resend-confirmation")
                }

                VStack(spacing: Space.sm) {
                    Button(AuthCopy.signIn, action: onSignIn)
                        .buttonStyle(.primary)
                        .accessibilityIdentifier("check-email-sign-in")
                    Button {
                        Task { await account.resendConfirmation() }
                    } label: {
                        if account.isBusy {
                            ProgressView().tint(Color.ink)
                        } else {
                            Text(AuthCopy.resendEmail)
                        }
                    }
                    .buttonStyle(.secondary)
                    .disabled(account.isBusy)
                    .accessibilityLabel(AuthCopy.resendEmail)
                    .accessibilityIdentifier("resend-email")
                }
                .padding(.top, Space.xs)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.lg)
        }
        .scrollIndicators(.hidden)
        .background(Color.surface)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("check-email-screen")
    }
}
