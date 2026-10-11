import SwiftUI
import UIKit

/// UIKit chrome that SwiftUI can't style directly: navigation bar titles and buttons in Manrope.
enum Appearance {
    static func configure() {
        let ink = UIColor(Color.ink)
        let button = UIBarButtonItemAppearance()
        button.normal.titleTextAttributes = [.font: UIFont.manrope(.semiBold, size: 17)]

        let navigation = UINavigationBarAppearance()
        navigation.configureWithTransparentBackground()
        navigation.titleTextAttributes = [.font: UIFont.manrope(.bold, size: 17), .foregroundColor: ink]
        navigation.largeTitleTextAttributes = [.font: UIFont.manrope(.extraBold, size: 32), .foregroundColor: ink]
        navigation.buttonAppearance = button
        navigation.backButtonAppearance = button

        UINavigationBar.appearance().standardAppearance = navigation
        UINavigationBar.appearance().scrollEdgeAppearance = navigation
        UINavigationBar.appearance().compactAppearance = navigation
    }
}
