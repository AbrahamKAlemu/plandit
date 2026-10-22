import SwiftUI

/// Lucide icons bundled in SharedAssets.xcassets/Icons (stroke 1.75, template-rendered).
/// The style guide allows Lucide only: add new icons to the catalog instead of using SF Symbols.
enum Lucide: String {
    case bell, bookmark, bus, check, clock, coffee, flame, footprints, house, info, landmark, link, map, martini
    case navigation, play, plus, route, settings, ticket, trees, users, utensils, video, wallet, x
    case calendarDays = "calendar-days"
    case chevronLeft = "chevron-left"
    case chevronRight = "chevron-right"
    case circleAlert = "circle-alert"
    case circleCheck = "circle-check"
    case clipboardPaste = "clipboard-paste"
    case externalLink = "external-link"
    case loaderCircle = "loader-circle"
    case mapPin = "map-pin"
    case piggyBank = "piggy-bank"
    case share = "share-2"
    case shoppingBag = "shopping-bag"
    case sliders = "sliders-horizontal"
    case trainFront = "train-front"
    case trash = "trash-2"
    case userRound = "user-round"
}

struct Icon: View {
    let icon: Lucide
    var size: CGFloat

    init(_ icon: Lucide, size: CGFloat = 20) {
        self.icon = icon
        self.size = size
    }

    var body: some View {
        Image("Icons/\(icon.rawValue)")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Official Plandit artwork copied from Design/Logo into SharedAssets.xcassets/Brand.
/// Never recolor, crop or approximate it. Below 24pt, use the favicon export instead of `mark`;
/// don't use a lockup below ~120pt wide.
enum BrandArt: String {
    case mark
    case markSquare = "mark-square"
    case markOnDark = "mark-on-dark"
    case markBlack = "mark-black"
    case markWhite = "mark-white"
    case lockupLight = "lockup-light"
    case lockupDark = "lockup-dark"
    case lockupStackedLight = "lockup-stacked-light"
    case lockupStackedDark = "lockup-stacked-dark"
    case avatar

    var image: Image { Image("Brand/\(rawValue)") }
}
