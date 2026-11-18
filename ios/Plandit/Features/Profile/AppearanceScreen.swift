import SwiftUI

/// System, Light or Dark. Opens from Profile → Preferences.
struct AppearanceScreen: View {
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
