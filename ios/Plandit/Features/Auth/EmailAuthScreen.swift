import SwiftUI

enum EmailAuthMode: String, CaseIterable, Identifiable, Hashable {
    case signUp, signIn

    var id: String { rawValue }

    var title: String {
        switch self {
        case .signUp: AuthCopy.signUp
        case .signIn: AuthCopy.signIn
        }
    }
}

/// Email + password, one form for both sign up and sign in.
struct EmailAuthScreen: View {
    private enum Field: Hashable { case name, email, password }

    @Environment(AccountModel.self) private var account
    @State private var mode: EmailAuthMode
    @State private var name = ""
    @State private var email: String
    @State private var password = ""
    @State private var localError: String?
    @FocusState private var focus: Field?

    init(mode: EmailAuthMode, email: String = "") {
        _mode = State(initialValue: mode)
        _email = State(initialValue: email)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.md) {
                Picker("Sign up or sign in", selection: $mode) {
                    ForEach(EmailAuthMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("auth-mode")

                Text(title)
                    .font(.sectionHeading)
                    .foregroundStyle(.ink)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("auth-title")

                if mode == .signUp {
                    AuthTextField(
                        label: AuthCopy.name,
                        text: $name,
                        contentType: .name,
                        capitalization: .words,
                        disablesAutocorrect: false,
                        onSubmit: { focus = .email },
                        field: Field.name,
                        focus: $focus
                    )
                    .accessibilityIdentifier("auth-name")
                }

                AuthTextField(
                    label: AuthCopy.email,
                    text: $email,
                    contentType: mode == .signUp ? .emailAddress : .username,
                    keyboard: .emailAddress,
                    onSubmit: { focus = .password },
                    field: Field.email,
                    focus: $focus
                )
                .accessibilityIdentifier("auth-email")

                AuthTextField(
                    label: AuthCopy.password,
                    hint: AuthCopy.passwordHint,
                    text: $password,
                    isSecure: true,
                    contentType: mode == .signUp ? .newPassword : .password,
                    submitLabel: .go,
                    onSubmit: submit,
                    field: Field.password,
                    focus: $focus
                )
                .accessibilityIdentifier("auth-password")

                if let message = localError ?? account.errorMessage {
                    InlineErrorText(message: message)
                }

                Button(action: submit) {
                    if account.isBusy {
                        ProgressView().tint(Color.onEmerald)
                    } else {
                        Text(primaryTitle)
                    }
                }
                .buttonStyle(.primary)
                .disabled(account.isBusy)
                .accessibilityLabel(primaryTitle)
                .accessibilityIdentifier("auth-submit")
            }
            .padding(Space.lg)
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollIndicators(.hidden)
        .background(Color.canvas)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: mode) {
            localError = nil
            account.errorMessage = nil
        }
        .onAppear {
            if focus == nil { focus = mode == .signUp ? .name : .email }
        }
    }

    private var title: String {
        mode == .signUp ? AuthCopy.createYourAccount : AuthCopy.welcomeBack
    }

    private var primaryTitle: String {
        mode == .signUp ? AuthCopy.createAccount : AuthCopy.signIn
    }

    private func submit() {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.looksLikeEmail(trimmedEmail) else {
            localError = AuthCopy.invalidEmail
            focus = .email
            return
        }
        if mode == .signUp, password.count < 8 {
            localError = AuthCopy.weakPassword
            focus = .password
            return
        }
        localError = nil
        focus = nil
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = password
        Task {
            switch mode {
            case .signUp: await account.signUp(email: trimmedEmail, password: password, name: trimmedName)
            case .signIn: await account.signIn(email: trimmedEmail, password: password)
            }
        }
    }

    static func looksLikeEmail(_ value: String) -> Bool {
        guard !value.contains(where: \.isWhitespace), let at = value.firstIndex(of: "@"), at != value.startIndex else { return false }
        let domain = value[value.index(after: at)...]
        return domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".")
    }
}
