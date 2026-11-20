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
/// The logo on the launch screen's color while the account opens. The launch screen is the same
/// color, so the logo seems to arrive on it: it fades and settles in. The spinner shows only when
/// opening takes more than a second.
struct SplashScreen: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShown = false
    @State private var isSlow = false

    var body: some View {
        VStack(spacing: Space.lg) {
            BrandLockup(markSize: 48)
                .opacity(isShown ? 1 : 0)
                .scaleEffect(isShown || reduceMotion ? 1 : 0.94)
            ProgressView()
                .tint(Color.inkMuted)
                .opacity(isSlow ? 1 : 0)
                .accessibilityHidden(!isSlow)
                .accessibilityLabel("Loading")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.canvas)
        .accessibilityIdentifier("splash-screen")
        .task {
            withAnimation(.easeOut(duration: 0.45)) { isShown = true }
            try? await Task.sleep(for: .seconds(1))
            withAnimation(.easeIn(duration: 0.3)) { isSlow = true }
        }
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
