import SwiftUI

struct SettingsScreen: View {
    @Environment(AppearanceSettings.self) private var appearance
    @Environment(AccountModel.self) private var account
    @State private var isConfirmingDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                VStack(alignment: .leading, spacing: Space.sm) {
                    SectionTitle("Display")
                    NavigationLink {
                        AppearanceScreen()
                    } label: {
                        ListRow(
                            icon: .settings,
                            title: "Appearance",
                            detail: appearance.mode.title
                        )
                    }
                    .buttonStyle(.plain)
                    .planditCard(padding: 0)
                }

                VStack(alignment: .leading, spacing: Space.sm) {
                    SectionTitle("Account")
                    VStack(spacing: 0) {
                        HStack(spacing: Space.sm) {
                            Icon(.userRound, size: 20).foregroundStyle(.ink).frame(width: 24)
                            Text(signedInText)
                                .font(.manrope(.semiBold, size: 15))
                                .foregroundStyle(.ink)
                                .lineLimit(2)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, Space.md)
                        .padding(.vertical, Space.sm)
                        .frame(minHeight: 56)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("account-signed-in")

                        Hairline().padding(.leading, 52)
                        AccountActionRow(title: AuthCopy.signOut, isDestructive: false, isBusy: account.isBusy) {
                            Task { await account.signOut() }
                        }
                        .accessibilityIdentifier("sign-out")

                        Hairline().padding(.leading, 52)
                        AccountActionRow(title: AuthCopy.deleteAccount, isDestructive: true, isBusy: account.isBusy) {
                            isConfirmingDelete = true
                        }
                        .accessibilityIdentifier("delete-account")
                    }
                    .planditCard(padding: 0)

                    if let message = account.errorMessage {
                        InlineErrorText(message: message)
                    }
                }
            }
            .padding(Space.lg)
        }
        .scrollIndicators(.hidden)
        .background(Color.canvas)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(AuthCopy.deleteTitle, isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button(AuthCopy.deleteAccount, role: .destructive) {
                Task { await account.deleteAccount() }
            }
        } message: {
            Text(AuthCopy.deleteMessage)
        }
    }

    private var signedInText: String {
        if let email = account.currentUser?.email, !email.isEmpty {
            return AuthCopy.signedInAs(email)
        }
        return AuthCopy.signedInWithApple
    }
}

/// A full-width tappable row. Destructive uses the error color, always with its text.
private struct AccountActionRow: View {
    let title: String
    let isDestructive: Bool
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        Button(role: isDestructive ? .destructive : nil, action: action) {
            HStack(spacing: Space.sm) {
                Color.clear.frame(width: 24, height: 1)
                Text(title)
                    .font(.manrope(.semiBold, size: 15))
                    .foregroundStyle(isDestructive ? Color.error : Color.ink)
                Spacer(minLength: 0)
                if isBusy { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, Space.md)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
    }
}

private struct AppearanceScreen: View {
    @Environment(AppearanceSettings.self) private var appearance
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.sm) {
                Text("Choose how Plandit looks. System follows your iPhone setting.")
                    .font(.bodyText)
                    .foregroundStyle(.inkMuted)

                VStack(spacing: 0) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Button {
                            appearance.mode = mode
                        } label: {
                            HStack(spacing: Space.sm) {
                                Text(mode.title)
                                    .font(.manrope(.semiBold, size: 16))
                                    .foregroundStyle(.ink)
                                Spacer()
                                if mode == selectedMode {
                                    Icon(.check, size: 20)
                                        .foregroundStyle(.emeraldDeep)
                                }
                            }
                            .padding(.horizontal, Space.md)
                            .frame(minHeight: 56)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(mode.title)
                        .accessibilityValue(mode == selectedMode ? "Selected" : "Not selected")
                        .accessibilityAddTraits(mode == selectedMode ? .isSelected : [])

                        if mode != AppearanceMode.allCases.last {
                            Hairline().padding(.leading, Space.md)
                        }
                    }
                }
                .planditCard(padding: 0)
            }
            .padding(Space.lg)
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("appearance-screen")
        .accessibilityValue("Selected \(selectedMode.rawValue), effective \(colorScheme == .dark ? "dark" : "light")")
        .background(Color.canvas)
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var selectedMode: AppearanceMode {
        appearance.mode
    }
}
