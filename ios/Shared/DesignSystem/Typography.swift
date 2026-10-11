import SwiftUI
import UIKit

/// Bundled Manrope weights (Shared/Fonts, registered through UIAppFonts).
enum Manrope: String, CaseIterable {
    case regular = "Manrope-Regular"
    case medium = "Manrope-Medium"
    case semiBold = "Manrope-SemiBold"
    case bold = "Manrope-Bold"
    case extraBold = "Manrope-ExtraBold"
}

extension Font {
    static func manrope(_ weight: Manrope, size: CGFloat, relativeTo style: TextStyle = .body) -> Font {
        .custom(weight.rawValue, size: size, relativeTo: style)
    }

    // Mobile type scale from the style guide. Sentence case only; never all caps.
    static var heroDisplay: Font { manrope(.extraBold, size: 40, relativeTo: .largeTitle) }
    static var pageHeading: Font { manrope(.extraBold, size: 32, relativeTo: .largeTitle) }
    static var sectionHeading: Font { manrope(.bold, size: 26, relativeTo: .title) }
    static var cardHeading: Font { manrope(.bold, size: 18, relativeTo: .headline) }
    static var bodyLarge: Font { manrope(.medium, size: 17, relativeTo: .body) }
    static var bodyText: Font { manrope(.regular, size: 16, relativeTo: .body) }
    static var label: Font { manrope(.semiBold, size: 14, relativeTo: .subheadline) }
    static var metadata: Font { manrope(.medium, size: 13, relativeTo: .footnote) }
}

extension UIFont {
    static func manrope(_ weight: Manrope, size: CGFloat) -> UIFont {
        UIFont(name: weight.rawValue, size: size) ?? .systemFont(ofSize: size)
    }
}
