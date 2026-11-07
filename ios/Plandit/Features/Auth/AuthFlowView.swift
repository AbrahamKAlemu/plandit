import SwiftUI

/// The signed-out gate: welcome → email form, or the check-your-email page after a sign-up.
struct AuthFlowView: View {
    enum Route: Hashable {
        case email(mode: EmailAuthMode, email: String)
        case checkEmail(String)
    }

    @Environment(AccountModel.self) private var account
    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            WelcomeScreen { path = [.email(mode: .signUp, email: "")] }
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .email(let mode, let email):
                        EmailAuthScreen(mode: mode, email: email)
                    case .checkEmail(let email):
                        CheckEmailScreen(email: email) {
                            account.showSignIn()
                            path = [.email(mode: .signIn, email: email)]
                        }
                    }
                }
        }
        .onChange(of: account.state, initial: true) { _, state in
            if case .awaitingConfirmation(let email) = state {
                path = [.checkEmail(email)]
            }
        }
    }
}

/// While the stored session is read, or the account's data is fetched after sign-in.
struct SplashScreen: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: Space.lg) {
            (colorScheme == .dark ? BrandArt.lockupDark : BrandArt.lockupLight).image
                .resizable()
                .scaledToFit()
                .frame(width: 150)
                .accessibilityLabel("Plandit")
            ProgressView()
                .tint(Color.inkMuted)
                .accessibilityLabel("Loading")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.canvas)
        .accessibilityIdentifier("splash-screen")
    }
}

/// Red text with an icon: errors never rely on color alone.
struct InlineErrorText: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: Space.xs) {
            Icon(.circleAlert, size: 16)
                .padding(.top, 1)
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.label)
        .foregroundStyle(.error)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("inline-error")
    }
}

/// Labeled input in the card style the profile editors use. `field` identifies it in the form's focus state.
struct AuthTextField<Field: Hashable>: View {
    let label: String
    var hint: String?
    @Binding var text: String
    var isSecure = false
    var contentType: UITextContentType?
    var keyboard: UIKeyboardType = .default
    var capitalization: TextInputAutocapitalization = .never
    var disablesAutocorrect = true
    var submitLabel: SubmitLabel = .next
    var onSubmit: () -> Void = {}
    let field: Field
    @FocusState.Binding var focus: Field?

    private var isFocused: Bool { focus == field }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(label).font(.label).foregroundStyle(.ink)
            Group {
                if isSecure {
                    SecureField("", text: $text)
                } else {
                    TextField("", text: $text)
                }
            }
            .font(.bodyText)
            .foregroundStyle(.ink)
            .textContentType(contentType)
            .keyboardType(keyboard)
            .textInputAutocapitalization(capitalization)
            .autocorrectionDisabled(disablesAutocorrect)
            .submitLabel(submitLabel)
            .focused($focus, equals: field)
            .onSubmit(onSubmit)
            .padding(.horizontal, Space.sm)
            .frame(minHeight: 48)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .strokeBorder(isFocused ? Color.ink : Color.border, lineWidth: isFocused ? 2 : 1)
            )
            .animation(.snappy(duration: 0.2), value: isFocused)
            .accessibilityLabel(label)
            if let hint {
                Text(hint).font(.metadata).foregroundStyle(.inkMuted)
            }
        }
    }
}
